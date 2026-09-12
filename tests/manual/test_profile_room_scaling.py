import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import profile_room_scaling as prs


def _combined_with_authoritative_stride(
    counts: dict[str, int],
) -> prs.CombinedLogParser:
    parser = prs.CombinedLogParser()
    body = ",".join(f"{key}:{value}" for key, value in counts.items())
    parser.feed(f"[BENCHMARK] scenario=E npc_authoritative_stride_counts={{{body}}}")
    return parser


class ProfileRoomScalingTests(unittest.TestCase):
    def test_parse_ps_time_formats(self):
        self.assertEqual(prs.parse_ps_time("00:01"), 1)
        self.assertEqual(prs.parse_ps_time("01:02:03"), 3723)
        self.assertEqual(prs.parse_ps_time("2-03:04:05"), 183845)
        self.assertEqual(prs.parse_ps_time("00.32"), 0.32)
        self.assertEqual(prs.parse_ps_time("00:10.99"), 10.99)
        self.assertEqual(prs.parse_ps_time("01:02:03.45"), 3723.45)
        self.assertEqual(prs.parse_ps_time("2-03:04:05.67"), 183845.67)

    def test_parse_ps_time_rejects_invalid_and_nonfinite_values(self):
        for value in ("nan", "inf", "00:nan", "00:inf", "bad", "1:2:3:4"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                prs.parse_ps_time(value)

    def test_cpu_delta_discards_negative_and_computes_percent(self):
        self.assertAlmostEqual(prs.cpu_percent_delta(10, 12.5, 5), 50.0)
        self.assertEqual(prs.cpu_percent_delta(12.5, 10, 5), 0.0)
        self.assertAlmostEqual(prs.cpu_percent_delta(10.25, 12.75, 4), 62.5)

    def test_ps_sample_preserves_fractional_ps_time(self):
        completed = subprocess.CompletedProcess(
            ["ps"], 0, stdout="00:10.99 123456\n", stderr=""
        )
        with mock.patch.object(prs.subprocess, "run", return_value=completed):
            self.assertEqual(prs.ps_sample(123), (10.99, 123456))

    def test_unique_short_accounts(self):
        accounts = prs.generate_accounts(3)
        names = [a.username for a in accounts]
        self.assertEqual(len(set(names)), 3)
        self.assertTrue(all(len(name) <= 32 for name in names))
        self.assertTrue(all(len(a.password) >= 16 for a in accounts))

    def test_postgres_command_and_env_exact(self):
        spec = prs.postgres_spec("abc", "vol")
        self.assertEqual(spec.image, "postgres:16-alpine")
        self.assertIn("POSTGRES_USER=postgres", spec.command)
        self.assertIn("POSTGRES_DB=postgres", spec.command)
        self.assertIn("POSTGRES_HOST_AUTH_METHOD=trust", spec.command)
        self.assertTrue(any("15432:5432" in part for part in spec.command))
        self.assertIn("vol:/var/lib/postgresql/data", spec.command)

    def test_loopback_validation(self):
        self.assertEqual(prs.require_loopback_host("localhost", "x"), "localhost")
        self.assertEqual(prs.require_loopback_host("127.0.0.1", "x"), "127.0.0.1")
        with self.assertRaises(ValueError):
            prs.require_loopback_host("192.168.1.5", "x")
        with self.assertRaises(ValueError):
            prs.require_loopback_url("http://example.com:1", "x")

    def test_server_process_filtering(self):
        rows = [
            prs.ProcessRow(100, 50, "/Godot --server /repo/project.godot", 0),
            prs.ProcessRow(101, 77, "/Godot --server /repo/project.godot", 0),
            prs.ProcessRow(102, 50, "/Godot /repo/project.godot", 0),
            prs.ProcessRow(103, 50, "/Godot --server /other/project.godot", 0),
        ]
        self.assertEqual(prs.filter_owned_server_pids(rows, {50}, Path("/repo")), [100])

    def test_log_phase_and_pass_parsing(self):
        parser = prs.ServerLogParser()
        parser.feed("x players=1 entities=21\n")
        self.assertTrue(parser.ready)
        cp = prs.ClientLogParser()
        cp.feed(
            "[LIVE-PROBE] movement=1.20m mob_displacement=0.50m max_projectiles=1 attacks=0->2 dead=false\n"
        )
        cp.feed("[LIVE-PROBE] PASS oid=abc\n")
        self.assertTrue(cp.passed)
        self.assertEqual(cp.metrics["max_projectiles"], 1)

    def test_client_spawn_marker_controls_readiness(self):
        cp = prs.ClientLogParser()
        cp.feed("[LIVE-PROBE] spawned player=123 mobs=19\n")
        self.assertFalse(cp.ready)
        cp.feed("[LIVE-PROBE] spawned player=123 mobs=20\n")
        self.assertTrue(cp.ready)

    def test_combined_perf_is_not_duplicated_into_rooms(self):
        combined = prs.CombinedLogParser()
        combined.feed("[PerfProbe] loop avg=1.0 props=2\n")
        result = prs.build_result(
            1,
            [],
            {42: [(0.0, 1.0, 100), (2.0, 2.0, 200)]},
            {42: prs.ServerLogParser()},
            combined,
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
        )
        self.assertEqual(
            result["combined_server_perf_probe"], ["[PerfProbe] loop avg=1.0 props=2"]
        )
        rooms = cast(list[dict[str, object]], result["rooms"])
        self.assertEqual(rooms[0]["perf_probe"], [])

    def test_stable_gate_requires_exact_pids_clients_and_sampling(self):
        clients = [mock.Mock(parser=mock.Mock(ready=True), end_monotonic=20.0)]
        ready = prs.evaluate_stable_gate(
            rooms=1,
            active_pids=[42],
            clients=clients,
            stable_started=10.0,
            now=18.1,
            samples={42: [(10.0, 1.0, 100), (11.0, 2.0, 200)]},
        )
        self.assertTrue(ready.ok)
        not_ready = prs.evaluate_stable_gate(
            rooms=1,
            active_pids=[42, 43],
            clients=clients,
            stable_started=10.0,
            now=18.1,
            samples={
                42: [(10.0, 1.0, 100), (11.0, 2.0, 200)],
                43: [(10.0, 1.0, 100), (11.0, 2.0, 200)],
            },
        )
        self.assertFalse(not_ready.ok)

    def test_noray_env_uses_server_max_fps(self):
        env = prs.noray_env(Path("/repo"), Path("/godot"), "cred")
        self.assertEqual(env["NOIKAR_SERVER_MAX_FPS"], "60")
        self.assertNotIn("NOIKAR_SERVER_FPS", env)

    def test_client_tuple_process_regression(self):
        accounts = prs.generate_accounts(2)
        procs = [
            prs.ClientProcess(
                index=i,
                account=acct,
                process=mock.Mock(pid=100 + i),
                log_path=Path(f"c{i}.log"),
            )
            for i, acct in enumerate(accounts)
        ]
        self.assertEqual([p.process.pid for p in procs], [100, 101])
        self.assertEqual(
            [p.account.username for p in procs], [a.username for a in accounts]
        )

    def test_long_args_validate_before_infra_and_keep_legacy_defaults(self):
        args = prs.parse_args([])
        self.assertEqual(args.npc_rate_hz, 30)
        self.assertEqual(args.warmup_seconds, 0.0)
        self.assertEqual(args.sample_seconds, 0.0)
        self.assertIsNone(args.mob_count)
        with self.assertRaises(SystemExit):
            prs.parse_args(["--npc-rate-hz", "12"])
        with self.assertRaises(SystemExit):
            prs.parse_args(["--warmup-seconds", "nan"])
        with self.assertRaises(SystemExit):
            prs.parse_args(["--sample-seconds", "-1"])
        with self.assertRaises(SystemExit):
            prs.parse_args(
                [
                    "--deadline-seconds",
                    "10",
                    "--warmup-seconds",
                    "8",
                    "--sample-seconds",
                    "8",
                ]
            )

    def test_mob_count_requires_single_nonhuman_positive_long_sample(self):
        args = prs.parse_args(
            ["--mob-count", "20", "--warmup-seconds", "1", "--sample-seconds", "2"]
        )
        self.assertEqual(args.mob_count, 20)
        self.assertEqual(
            prs.parse_args(
                ["--mob-count", "0", "--warmup-seconds", "1", "--sample-seconds", "2"]
            ).mob_count,
            0,
        )
        self.assertEqual(
            prs.parse_args(
                ["--mob-count", "1", "--warmup-seconds", "1", "--sample-seconds", "2"]
            ).mob_count,
            1,
        )
        with self.assertRaises(SystemExit):
            prs.parse_args(
                ["--mob-count", "2", "--warmup-seconds", "1", "--sample-seconds", "2"]
            )
        with self.assertRaises(SystemExit):
            prs.parse_args(["--mob-count", "1", "--sample-seconds", "2"])
        with self.assertRaises(SystemExit):
            prs.parse_args(["--mob-count", "1", "--warmup-seconds", "1"])
        with self.assertRaises(SystemExit):
            prs.parse_args(
                [
                    "--mob-count",
                    "1",
                    "--rooms",
                    "2",
                    "--warmup-seconds",
                    "1",
                    "--sample-seconds",
                    "2",
                ]
            )
        with self.assertRaises(SystemExit):
            prs.parse_args(
                [
                    "--human",
                    "--mob-count",
                    "1",
                    "--warmup-seconds",
                    "1",
                    "--sample-seconds",
                    "2",
                ]
            )

    def test_rate_and_cost_env_only_go_to_server_side_noray(self):
        env = prs.noray_env(Path("/repo"), Path("/godot"), "cred", npc_rate_hz=15)
        self.assertEqual(env["NOIKAR_NPC_SNAPSHOT_HZ"], "15")
        self.assertEqual(env["NOIKAR_PERF_PROBE_NPC_COST"], "1")
        self.assertNotIn("NOIKAR_PROFILE_EXPECTED_MOB_COUNT", env)
        fixed_env = prs.noray_env(Path("/repo"), Path("/godot"), "cred", mob_count=20)
        self.assertEqual(fixed_env["NOIKAR_PROFILE_FIXED_POPULATION"], "1")
        self.assertEqual(fixed_env["NOIKAR_PROFILE_MOB_COUNT"], "20")
        client_env = prs.client_probe_env(
            account=prs.Account("u", "p"),
            lobby_hold_seconds=0.0,
            warmup_seconds=3.0,
            sample_seconds=5.0,
            mob_count=20,
        )
        self.assertEqual(client_env["NOIKAR_PROFILE_WARMUP_SEC"], "3.0")
        self.assertEqual(client_env["NOIKAR_PROFILE_SAMPLE_SEC"], "5.0")
        self.assertEqual(client_env["NOIKAR_PROFILE_EXPECTED_MOB_COUNT"], "20")
        self.assertEqual(client_env["NOIKAR_PROFILE_FIXED_ROUTE"], "1")
        self.assertNotIn("NOIKAR_PROFILE_MOB_COUNT", client_env)
        self.assertNotIn("NOIKAR_PROFILE_FIXED_POPULATION", client_env)
        self.assertNotIn("NOIKAR_NPC_SNAPSHOT_HZ", client_env)
        self.assertNotIn("NOIKAR_PERF_PROBE_NPC_COST", client_env)

    def test_run_passes_benchmark_scenario_only_to_selected_noray_start(self):
        def capture_noray_env(argv: list[str]) -> dict[str, str]:
            with tempfile.TemporaryDirectory() as temp_s:
                temp = Path(temp_s)
                repo = temp / "repo"
                noray_root = temp / "noikar-noray"
                (repo / "backend").mkdir(parents=True)
                (repo / "project.godot").write_text("", encoding="utf-8")
                (noray_root / "bin").mkdir(parents=True)
                (noray_root / "bin" / "noray.mjs").write_text("", encoding="utf-8")
                godot = temp / "Godot"
                godot.write_text("", encoding="utf-8")
                captured: dict[str, str] = {}

                class StopAfterNorayStart(RuntimeError):
                    pass

                def fake_start_process(args, *, cwd, env, log_path, cleanup):
                    if args[:2] == ["node", "bin/noray.mjs"]:
                        captured.update(env)
                        raise StopAfterNorayStart()
                    return mock.Mock(pid=1000, poll=mock.Mock(return_value=0))

                with (
                    mock.patch.object(prs, "repo_root_from_script", return_value=repo),
                    mock.patch.object(prs, "preflight_ports"),
                    mock.patch.object(prs.subprocess, "run"),
                    mock.patch.object(prs, "wait_pg"),
                    mock.patch.object(prs, "wait_http"),
                    mock.patch.object(prs, "register_account"),
                    mock.patch.object(
                        prs, "start_process", side_effect=fake_start_process
                    ),
                    mock.patch.object(prs.CleanupPlan, "run"),
                    mock.patch.object(prs, "assert_ports_clear", return_value={}),
                ):
                    rc = prs.run(["--godot", str(godot), *argv])

                self.assertEqual(rc, 1)
                self.assertTrue(captured)
                return captured

        selected = capture_noray_env(
            [
                "--benchmark",
                "D",
                "--warmup-seconds",
                "1",
                "--sample-seconds",
                "1",
            ]
        )
        self.assertEqual(selected["NOIKAR_BENCHMARK_SCENARIO"], "D")

        normal = capture_noray_env([])
        self.assertNotIn("NOIKAR_BENCHMARK_SCENARIO", normal)

    def test_sample_window_excludes_warmup_and_weights_cpu_by_actual_sample_wall(self):
        samples = {42: [(10.0, 1.0, 100), (13.0, 2.0, 150), (15.0, 4.0, 200)]}
        result = prs.build_result(
            1,
            [],
            samples,
            {42: prs.ServerLogParser()},
            prs.CombinedLogParser(),
            prs.StableGate(True, True, True, 0.0, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(
                requested_warmup_seconds=3.0,
                requested_sample_seconds=2.0,
                stable_started=10.0,
            ),
            npc_rate_hz=10,
        )
        room = cast(list[dict[str, object]], result["rooms"])[0]
        self.assertEqual(room["cpu_percent"], 100.0)
        self.assertEqual(result["requested_npc_rate_hz"], 10)
        self.assertEqual(result["requested_warmup_seconds"], 3.0)
        self.assertEqual(result["requested_sample_seconds"], 2.0)
        self.assertEqual(result["actual_sample_duration_seconds"], 2.0)
        gate = cast(dict[str, object], result["gate"])
        self.assertTrue(gate["sample_window"])

    def test_sample_window_invalid_when_mob_count_changes_or_player_dies(self):
        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                passed=True,
                metrics={"dead": True, "mobs_start": 20, "mobs_end": 19},
                errors=[],
                telemetry={},
            ),
        )
        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 100)]},
            {},
            prs.CombinedLogParser(),
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(
                requested_warmup_seconds=0.0,
                requested_sample_seconds=1.0,
                stable_started=0.0,
            ),
        )
        gate = cast(dict[str, object], result["gate"])
        self.assertFalse(gate["alive"])
        self.assertFalse(gate["mob_population_stable"])

    def test_perf_npc_cost_lines_get_structured_interval_summary(self):
        parser = prs.CombinedLogParser()
        parser.feed(
            "[BENCHMARK] scenario=E fps=60.0 "
            "npc_ai_inclusive_total_usec=300 npc_ai_inclusive_calls=3 npc_ai_inclusive_max_usec=200 "
            "npc_movement_inclusive_total_usec=50 npc_movement_prepare_child_total_usec=10 "
            "npc_movement_slide_child_calls=2 npc_movement_flush_child_max_usec=7 "
            "npc_combat_total_usec=9 npc_target_scan_visits=7 npc_avoidance_visits=8"
        )
        self.assertEqual(parser.perf_lines[0].split()[0], "[BENCHMARK]")
        ai_cost = cast(dict[str, int], parser.npc_cost_intervals[0]["npc_ai_inclusive"])
        self.assertEqual(ai_cost["total_usec"], 300)
        self.assertEqual(ai_cost["calls"], 3)
        self.assertEqual(ai_cost["max_usec"], 200)
        movement = cast(
            dict[str, int], parser.npc_cost_intervals[0]["npc_movement_inclusive"]
        )
        self.assertEqual(movement["total_usec"], 50)
        prepare = cast(
            dict[str, int], parser.npc_cost_intervals[0]["npc_movement_prepare_child"]
        )
        self.assertEqual(prepare["total_usec"], 10)
        slide = cast(
            dict[str, int], parser.npc_cost_intervals[0]["npc_movement_slide_child"]
        )
        self.assertEqual(slide["calls"], 2)
        flush = cast(
            dict[str, int], parser.npc_cost_intervals[0]["npc_movement_flush_child"]
        )
        self.assertEqual(flush["max_usec"], 7)
        combat = cast(dict[str, int], parser.npc_cost_intervals[0]["npc_combat"])
        self.assertEqual(combat["total_usec"], 9)
        self.assertEqual(parser.npc_cost_intervals[0]["npc_target_scan_visits"], 7)
        self.assertEqual(parser.npc_cost_intervals[0]["npc_avoidance_visits"], 8)

    def test_healthy_sync_telemetry_is_not_classified_as_error(self):
        server = prs.ServerLogParser()
        server.feed(
            "[BENCHMARK] npc_snapshot_sync_observable=20 synchronized_entities_observable=21\n"
        )
        self.assertEqual(server.errors, [])
        self.assertEqual(len(server.perf_lines), 1)
        combined = prs.CombinedLogParser()
        combined.feed(
            "[BENCHMARK] npc_snapshot_sync_observable=20 synchronized_entities_observable=21\n"
        )
        self.assertEqual(combined.errors, [])
        self.assertEqual(len(combined.perf_lines), 1)
        server.feed(
            "[PROFILE_POPULATION_FAILED] mode=fixed_population expectedcount=20 actualcount=0 seed=120120\n"
        )
        self.assertEqual(len(server.errors), 1)

    def test_authoritative_stride_counts_parse_and_drive_fixed_population_gate(self):
        parser = prs.CombinedLogParser()
        parser.feed(
            "[BENCHMARK] scenario=E fps=60.0 "
            "npc_authoritative_stride_counts={2:20} "
            "npc_ai_inclusive_total_usec=300 npc_ai_inclusive_calls=3 npc_ai_inclusive_max_usec=200"
        )

        self.assertEqual(parser.authoritative_stride_intervals, [{"2": 20}])

        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                passed=True,
                fixed_workload_ended=True,
                metrics={
                    "dead": False,
                    "mobs_start": 20,
                    "mobs_end": 20,
                    "max_projectiles": 1,
                    "movement": 10.0,
                    "mob_displacement": 1.0,
                    "observed_npcs_within_90m": {"max": 10},
                    "workload_invalid": False,
                },
                errors=[],
                telemetry={"npc_stride_counts": {"1": 10, "2": 10}},
            ),
        )
        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (2.0, 2.0, 120)]},
            {},
            parser,
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 1.0, 0.0),
            npc_rate_hz=15,
            mob_count=20,
        )

        self.assertTrue(cast(dict[str, object], result["gate"])["npc_stride_counts"])
        stride = cast(dict[str, object], result["npc_stride_observed"])
        self.assertEqual(stride["source"], "server_authoritative_perf_probe")
        self.assertEqual(stride["authoritative_observed"], {"2": 20})
        clients = cast(list[dict[str, object]], stride["clients"])
        self.assertEqual(clients[0]["observed"], {"1": 10, "2": 10})
        self.assertTrue(clients[0]["diagnostic_only"])

    def test_authoritative_stride_gate_rejects_missing_wrong_and_unknown_evidence(self):
        def result_for(lines: list[str]):
            parser = prs.CombinedLogParser()
            parser.feed("\n".join(lines))
            return prs.build_result(
                1,
                [],
                {42: [(0.0, 1.0, 100), (2.0, 2.0, 120)]},
                {},
                parser,
                prs.StableGate(True, True, True, 8.1, {42}),
                Path("artifacts"),
                profile=prs.ProfileWindow(1.0, 1.0, 0.0),
                npc_rate_hz=15,
                mob_count=20,
            )

        missing = cast(dict[str, object], result_for([])["npc_stride_observed"])
        self.assertFalse(missing["ok"])
        self.assertEqual(missing["reason"], "missing_authoritative_perf_probe_evidence")

        wrong = cast(
            dict[str, object],
            result_for(
                ["[BENCHMARK] scenario=E npc_authoritative_stride_counts={1:10,2:10}"]
            )["npc_stride_observed"],
        )
        self.assertFalse(wrong["ok"])
        self.assertEqual(wrong["authoritative_observed"], {"1": 10, "2": 10})

        unknown = cast(
            dict[str, object],
            result_for(
                [
                    "[BENCHMARK] scenario=E npc_authoritative_stride_counts={2:19,unknown:1}"
                ]
            )["npc_stride_observed"],
        )
        self.assertFalse(unknown["ok"])
        self.assertEqual(unknown["authoritative_unknown"], 1)

    def test_fixed_population_stride_gate_requires_expected_stride_for_all_mobs(self):
        def make_client(strides: dict[str, int]):
            return mock.Mock(
                process=mock.Mock(returncode=0),
                index=0,
                account=prs.Account("u", "p"),
                parser=mock.Mock(
                    ready=True,
                    passed=True,
                    fixed_workload_ended=True,
                    metrics={
                        "dead": False,
                        "mobs_start": 20,
                        "mobs_end": 20,
                        "max_projectiles": 1,
                        "movement": 10.0,
                        "mob_displacement": 1.0,
                        "observed_npcs_within_90m": {"max": 20},
                        "workload_invalid": False,
                    },
                    errors=[],
                    telemetry={"npc_stride_counts": strides},
                ),
            )

        matching = prs.build_result(
            1,
            [make_client({"2": 20})],
            {42: [(0.0, 1.0, 100), (2.0, 2.0, 120), (3.0, 2.5, 130)]},
            {},
            _combined_with_authoritative_stride({"2": 20}),
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 2.0, 0.0),
            npc_rate_hz=15,
            mob_count=20,
        )
        self.assertTrue(cast(dict[str, object], matching["gate"])["npc_stride_counts"])
        self.assertEqual(
            cast(dict[str, object], matching["npc_stride_observed"])["expected_stride"],
            2,
        )
        room = cast(list[dict[str, object]], matching["rooms"])[0]
        self.assertEqual(room["cpu_interval_peak_percent"], 50.0)
        self.assertEqual(room["cpu_interval_sample_resolution_seconds"], 1.0)
        aggregate = cast(dict[str, object], matching["aggregate"])
        self.assertEqual(aggregate["cpu_interval_peak_percent"], 50.0)

        mismatching = prs.build_result(
            1,
            [make_client({"1": 20})],
            {42: [(0.0, 1.0, 100), (2.0, 2.0, 120)]},
            {},
            prs.CombinedLogParser(),
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 1.0, 0.0),
            npc_rate_hz=15,
            mob_count=20,
        )
        self.assertFalse(
            cast(dict[str, object], mismatching["gate"])["npc_stride_counts"]
        )
        mismatch_stride = cast(dict[str, object], mismatching["npc_stride_observed"])
        mismatch_clients = cast(list[dict[str, object]], mismatch_stride["clients"])
        self.assertEqual(mismatch_clients[0]["observed"], {"1": 20})

    def test_zero_mob_fixed_population_is_exempt_from_stride_gate(self):
        result = prs.build_result(
            1,
            [],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 120)]},
            {},
            prs.CombinedLogParser(),
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 1.0, 0.0),
            npc_rate_hz=10,
            mob_count=0,
        )
        self.assertTrue(cast(dict[str, object], result["gate"])["npc_stride_counts"])
        self.assertTrue(
            cast(dict[str, object], result["npc_stride_observed"])["exempt"]
        )

    def test_client_parser_captures_telemetry_without_pass_decision(self):
        parser = prs.ClientLogParser()
        parser.feed(
            "[LIVE-PROBE] telemetry npc_stride_counts={1:18, 2:2} interpolator_buffer_counts={0:20}\n"
        )
        self.assertEqual(parser.telemetry["npc_stride_counts"], {"1": 18, "2": 2})
        self.assertEqual(parser.telemetry["interpolator_buffer_counts"], {"0": 20})
        self.assertFalse(parser.passed)

    def test_client_parser_captures_sustained_workload_distance_metrics(self):
        parser = prs.ClientLogParser()
        parser.feed(
            "[LIVE-PROBE] movement=18.00m mob_displacement=0.50m max_projectiles=1 "
            "attacks=0->1 dead=false mobs=20->20 workload=sustained_orbit sample=5.00s "
            "nearest_npc_m=20.10/22.50/24.90 observed_npcs_90m=3/8 "
            "alive_npcs=20 player_sample_travel=42.00m endpoint=2.00m invalid=false\n"
        )
        self.assertEqual(parser.metrics["workload"], "sustained_orbit")
        self.assertEqual(
            parser.metrics["nearest_npc_distance"],
            {"min": 20.1, "mean": 22.5, "max": 24.9},
        )
        self.assertEqual(
            parser.metrics["observed_npcs_within_90m"], {"min": 3, "max": 8}
        )
        self.assertEqual(parser.metrics["alive_npcs"], 20)
        self.assertEqual(parser.metrics["player_sample_travel"], 42.0)
        self.assertEqual(parser.metrics["player_sample_endpoint"], 2.0)
        self.assertFalse(parser.metrics["workload_invalid"])

    def test_fixed_population_readiness_requires_matching_server_marker_and_client_count(
        self,
    ):
        parser = prs.ServerLogParser(expected_mob_count=0)
        parser.feed(
            "[PROFILE_POPULATION_READY] mode=fixed_population expectedcount=0 actualcount=20 seed=120120\n"
        )
        self.assertFalse(parser.population_ready)
        parser.feed(
            "[PROFILE_POPULATION_FAILED] mode=fixed_population expectedcount=0 actualcount=0 seed=120120\n"
        )
        self.assertTrue(parser.population_failed)
        parser = prs.ServerLogParser(expected_mob_count=0)
        parser.feed(
            "[PROFILE_POPULATION_READY] mode=fixed_population expectedcount=0 actualcount=0 seed=120120\n"
        )
        self.assertTrue(parser.population_ready)
        client = prs.ClientLogParser(expected_mob_count=0)
        client.feed("[LIVE-PROBE] spawned player=123 mobs=20\n")
        self.assertFalse(client.ready)
        client.feed("[LIVE-PROBE] spawned player=123 mobs=0 fixed_population=true\n")
        self.assertTrue(client.ready)
        gate = prs.evaluate_stable_gate(
            rooms=1,
            active_pids=[42],
            clients=[mock.Mock(parser=client, end_monotonic=20.0)],
            stable_started=10.0,
            now=18.1,
            samples={42: [(10.0, 1.0, 100), (11.0, 2.0, 200)]},
            server_parsers={42: parser},
            mob_count=0,
        )
        self.assertTrue(gate.ok)

    def test_fixed_population_result_gates_zero_projectile_without_npc_specific_requirements(
        self,
    ):
        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                passed=True,
                metrics={
                    "dead": False,
                    "mobs_start": 0,
                    "mobs_end": 0,
                    "max_projectiles": 0,
                    "movement": 10.0,
                    "mob_displacement": 0.0,
                    "workload_invalid": False,
                },
                errors=[],
                telemetry={},
            ),
        )
        server = prs.ServerLogParser(expected_mob_count=0)
        server.feed(
            "[PROFILE_POPULATION_READY] mode=fixed_population expectedcount=0 actualcount=0 seed=120120\n"
        )
        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 100)]},
            {42: server},
            prs.CombinedLogParser(),
            prs.StableGate(
                True, True, True, 8.1, {42}, population_marker_verified=True
            ),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 1.0, 0.0),
            mob_count=0,
        )
        gate = cast(dict[str, object], result["gate"])
        self.assertFalse(gate["projectile"])
        self.assertTrue(gate["mob_population_stable"])
        self.assertTrue(gate["mob_movement"])
        self.assertTrue(gate["observed_near_npc"])
        self.assertEqual(result["requested_mob_count"], 0)
        self.assertTrue(result["fixed_population_mode"])
        self.assertTrue(result["marker_verified"])

    def test_run_wires_fixed_count_into_constructed_client_parser_and_final_gate(self):
        with tempfile.TemporaryDirectory() as temp_s:
            temp = Path(temp_s)
            repo = temp / "repo"
            noray_root = temp / "noikar-noray"
            (repo / "backend").mkdir(parents=True)
            (repo / "project.godot").write_text("", encoding="utf-8")
            (noray_root / "bin").mkdir(parents=True)
            (noray_root / "bin" / "noray.mjs").write_text("", encoding="utf-8")
            godot = temp / "Godot"
            godot.write_text("", encoding="utf-8")

            class FakeProc:
                def __init__(self, pid: int, returncode=0, active_polls: int = 0):
                    self.pid = pid
                    self.returncode = returncode
                    self.active_polls = active_polls
                    self.log_path = None
                    self.end_emitted = False

                def poll(self):
                    if self.active_polls > 0:
                        self.active_polls -= 1
                        return None
                    if self.log_path is not None and not self.end_emitted:
                        self.log_path.write_text(
                            self.log_path.read_text(encoding="utf-8")
                            + "[LIVE-PROBE] FIXED_WORKLOAD_END\n[LIVE-PROBE] PASS oid=abc\n",
                            encoding="utf-8",
                        )
                        self.end_emitted = True
                    self.returncode = 0
                    return self.returncode

            procs: list[FakeProc] = []
            built_clients = []
            gate_calls = []

            def fake_start_process(args, *, cwd, env, log_path, cleanup):
                pid = 1000 + len(procs)
                active_polls = (
                    28 if "res://tests/manual/live_gameplay_probe.gd" in args else 0
                )
                proc = FakeProc(pid, active_polls=active_polls)
                procs.append(proc)

                if args[:2] == ["node", "bin/noray.mjs"]:
                    log_path.write_text(
                        "[PROFILE_POPULATION_READY] mode=fixed_population expectedcount=0 actualcount=0 seed=120120\n",
                        encoding="utf-8",
                    )
                elif "res://tests/manual/live_gameplay_probe.gd" in args:
                    proc.log_path = log_path
                    log_path.write_text(
                        "[LIVE-PROBE] spawned player=123 mobs=0 fixed_population=true\n"
                        "[LIVE-PROBE] movement=248.94m mob_displacement=0.00m max_projectiles=4 attacks=0->1 dead=false "
                        "mobs=0->0 workload=fixed_route sample=20.00s nearest_npc_m=null/null/null "
                        "observed_npcs_90m=0/0 alive_npcs=0 player_sample_travel=248.94m endpoint=0.00m invalid=false\n",
                        encoding="utf-8",
                    )
                return proc

            original_gate = prs.evaluate_stable_gate
            original_build_result = prs.build_result
            clock = {"now": 100.0}

            def fake_monotonic():
                clock["now"] += 1.0
                return clock["now"]

            def capturing_gate(**kwargs):
                gate_calls.append(kwargs)
                return original_gate(**kwargs)

            def capturing_build_result(*args, **kwargs):
                built_clients.extend(args[1])
                return original_build_result(*args, **kwargs)

            def fake_rows():
                noray_pid = procs[1].pid if len(procs) > 1 else 1001
                return [
                    prs.ProcessRow(
                        4242,
                        noray_pid,
                        f"/Applications/Godot --server {repo}/project.godot",
                        0,
                    )
                ]

            with (
                mock.patch.object(prs, "repo_root_from_script", return_value=repo),
                mock.patch.object(prs, "preflight_ports"),
                mock.patch.object(prs.subprocess, "run"),
                mock.patch.object(prs, "wait_pg"),
                mock.patch.object(prs, "wait_http"),
                mock.patch.object(prs, "register_account"),
                mock.patch.object(prs, "wait_listener"),
                mock.patch.object(prs, "start_process", side_effect=fake_start_process),
                mock.patch.object(prs, "read_process_rows", side_effect=fake_rows),
                mock.patch.object(prs, "ps_sample", return_value=(1.0, 100)),
                mock.patch.object(prs.time, "monotonic", side_effect=fake_monotonic),
                mock.patch.object(prs.time, "sleep"),
                mock.patch.object(prs.CleanupPlan, "run"),
                mock.patch.object(prs, "assert_ports_clear", return_value={}),
                mock.patch.object(
                    prs, "evaluate_stable_gate", side_effect=capturing_gate
                ),
                mock.patch.object(
                    prs, "build_result", side_effect=capturing_build_result
                ),
            ):
                rc = prs.run(
                    [
                        "--godot",
                        str(godot),
                        "--mob-count",
                        "0",
                        "--warmup-seconds",
                        "1",
                        "--sample-seconds",
                        "20",
                    ]
                )

            self.assertEqual(rc, 0)
            self.assertEqual(built_clients[0].parser.expected_mob_count, 0)
            self.assertTrue(gate_calls)
            self.assertEqual(gate_calls[-1]["mob_count"], 0)
            self.assertIn(4242, gate_calls[-1]["server_parsers"])
            final_result = original_build_result(
                1,
                built_clients[:1],
                {4242: [(110.0, 1.0, 100), (131.0, 2.0, 120)]},
                gate_calls[-1]["server_parsers"],
                prs.CombinedLogParser(),
                gate_calls[-1].get(
                    "_result_gate",
                    prs.StableGate(
                        True, True, True, 21.0, {4242}, population_marker_verified=True
                    ),
                ),
                Path("artifacts"),
                profile=prs.ProfileWindow(1.0, 20.0, 109.0),
                mob_count=0,
            )
            self.assertTrue(
                cast(dict[str, object], final_result["gate"])["sample_window"]
            )
            self.assertTrue(
                cast(dict[str, object], final_result["active_sample_proof"])[
                    "fixed_workload_end_observed"
                ]
            )
            self.assertGreaterEqual(
                cast(float, final_result["actual_sample_duration_seconds"]), 20.0
            )

    def _run_fixed_population_with_capture_race(self, *, emit_marker: bool):
        with tempfile.TemporaryDirectory() as temp_s:
            temp = Path(temp_s)
            repo = temp / "repo"
            noray_root = temp / "noikar-noray"
            (repo / "backend").mkdir(parents=True)
            (repo / "project.godot").write_text("", encoding="utf-8")
            (noray_root / "bin").mkdir(parents=True)
            (noray_root / "bin" / "noray.mjs").write_text("", encoding="utf-8")
            godot = temp / "Godot"
            godot.write_text("", encoding="utf-8")

            class FakeProc:
                def __init__(self, pid: int, role: str):
                    self.pid = pid
                    self.role = role
                    self.returncode = None
                    self.log_path = None
                    self.exited_during_sample = False
                    self.marker_injected = False
                    self.polls_after_sample = 0

                def poll(self):
                    if self.role != "client":
                        self.returncode = 0
                        return self.returncode
                    if self.exited_during_sample or self.marker_injected:
                        self.polls_after_sample += 1
                        if self.polls_after_sample == 1:
                            return None
                        self.returncode = 0
                        return self.returncode
                    return None

            procs: list[FakeProc] = []
            result_holder: dict[str, object] = {}
            sample_calls = {"count": 0}
            clock = {"now": 100.0}

            def fake_monotonic():
                clock["now"] += 1.0
                return clock["now"]

            def fake_start_process(args, *, cwd, env, log_path, cleanup):
                if args[:2] == ["node", "bin/noray.mjs"]:
                    role = "noray"
                elif "res://tests/manual/live_gameplay_probe.gd" in args:
                    role = "client"
                else:
                    role = "backend"
                proc = FakeProc(1000 + len(procs), role)
                procs.append(proc)
                if role == "noray":
                    log_path.write_text(
                        "[PROFILE_POPULATION_READY] mode=fixed_population expectedcount=0 actualcount=0 seed=120120\n",
                        encoding="utf-8",
                    )
                elif role == "client":
                    proc.log_path = log_path
                    log_path.write_text(
                        "[LIVE-PROBE] spawned player=123 mobs=0 fixed_population=true\n"
                        "[LIVE-PROBE] movement=248.94m mob_displacement=0.00m max_projectiles=4 attacks=0->1 dead=false "
                        "mobs=0->0 workload=fixed_route sample=20.00s nearest_npc_m=null/null/null "
                        "observed_npcs_90m=0/0 alive_npcs=0 player_sample_travel=248.94m endpoint=0.00m invalid=false\n"
                        "[LIVE-PROBE] PASS oid=abc\n",
                        encoding="utf-8",
                    )
                return proc

            def fake_rows():
                noray_pid = procs[1].pid if len(procs) > 1 else 1001
                return [
                    prs.ProcessRow(
                        4242,
                        noray_pid,
                        f"/Applications/Godot --server {repo}/project.godot",
                        0,
                    )
                ]

            def fake_ps_sample(_pid):
                sample_calls["count"] += 1
                if sample_calls["count"] == 1:
                    return 1.0, 100
                if sample_calls["count"] == 2:
                    return 2.0, 120
                client = next(proc for proc in procs if proc.role == "client")
                client_log_path = cast(Path, client.log_path)
                if emit_marker:
                    client_log_path.write_text(
                        client_log_path.read_text(encoding="utf-8")
                        + "[LIVE-PROBE] FIXED_WORKLOAD_END\n",
                        encoding="utf-8",
                    )
                    client.marker_injected = True
                else:
                    client.exited_during_sample = True
                return 102.0, 999

            original_build_result = prs.build_result

            def capturing_build_result(*args, **kwargs):
                result = original_build_result(*args, **kwargs)
                result_holder["result"] = result
                return result

            with (
                mock.patch.object(prs, "repo_root_from_script", return_value=repo),
                mock.patch.object(prs, "preflight_ports"),
                mock.patch.object(prs.subprocess, "run"),
                mock.patch.object(prs, "wait_pg"),
                mock.patch.object(prs, "wait_http"),
                mock.patch.object(prs, "register_account"),
                mock.patch.object(prs, "wait_listener"),
                mock.patch.object(prs, "start_process", side_effect=fake_start_process),
                mock.patch.object(prs, "read_process_rows", side_effect=fake_rows),
                mock.patch.object(prs, "ps_sample", side_effect=fake_ps_sample),
                mock.patch.object(prs.time, "monotonic", side_effect=fake_monotonic),
                mock.patch.object(prs.time, "sleep"),
                mock.patch.object(prs.CleanupPlan, "run"),
                mock.patch.object(prs, "assert_ports_clear", return_value={}),
                mock.patch.object(
                    prs, "build_result", side_effect=capturing_build_result
                ),
            ):
                rc = prs.run(
                    [
                        "--godot",
                        str(godot),
                        "--mob-count",
                        "0",
                        "--warmup-seconds",
                        "0.1",
                        "--sample-seconds",
                        "1",
                        "--deadline-seconds",
                        "25",
                    ]
                )

            return rc, cast(dict[str, object], result_holder["result"])

    def test_fixed_population_rejects_ps_row_when_end_marker_arrives_during_capture(
        self,
    ):
        rc, result = self._run_fixed_population_with_capture_race(emit_marker=True)

        self.assertEqual(rc, 0)
        active_proof = cast(dict[str, object], result["active_sample_proof"])
        self.assertGreaterEqual(cast(int, active_proof["discarded_end_rows"]), 1)
        rooms = cast(list[dict[str, object]], result["rooms"])
        self.assertEqual(rooms[0]["sample_count"], 2)
        aggregate = cast(dict[str, object], result["aggregate"])
        self.assertLess(cast(float, aggregate["cpu_percent_total"]), 5_000)

    def test_fixed_population_rejects_ps_row_when_process_exits_during_capture(
        self,
    ):
        rc, result = self._run_fixed_population_with_capture_race(emit_marker=False)

        self.assertEqual(rc, 2)
        active_proof = cast(dict[str, object], result["active_sample_proof"])
        self.assertGreaterEqual(cast(int, active_proof["discarded_end_rows"]), 1)
        self.assertFalse(active_proof["fixed_workload_end_observed"])
        rooms = cast(list[dict[str, object]], result["rooms"])
        self.assertEqual(rooms[0]["sample_count"], 2)

    def test_fixed_population_sample_window_remains_strict_on_short_cpu_window(self):
        result = prs.build_result(
            1,
            [],
            {42: [(11.2, 1.0, 100), (31.0, 2.0, 120)]},
            {42: prs.ServerLogParser(expected_mob_count=0)},
            prs.CombinedLogParser(),
            prs.StableGate(
                True, True, True, 20.0, {42}, population_marker_verified=True
            ),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 20.0, 10.0),
            mob_count=0,
        )
        self.assertFalse(cast(dict[str, object], result["gate"])["sample_window"])
        self.assertEqual(result["actual_sample_duration_seconds"], 19.8)

    def test_fixed_population_sample_window_rejects_19_96s_actual_active_window(self):
        result = prs.build_result(
            1,
            [],
            {42: [(11.0, 1.0, 100), (30.96, 2.0, 120)]},
            {42: prs.ServerLogParser(expected_mob_count=0)},
            prs.CombinedLogParser(),
            prs.StableGate(
                True, True, True, 20.0, {42}, population_marker_verified=True
            ),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 20.0, 10.0),
            mob_count=0,
        )
        self.assertFalse(cast(dict[str, object], result["gate"])["sample_window"])
        self.assertEqual(result["actual_sample_duration_seconds"], 19.96)

    def test_fixed_population_cpu_window_stops_at_first_requested_active_coverage(self):
        result = prs.build_result(
            1,
            [],
            {
                42: [
                    (9.5, 0.5, 80),
                    (11.0, 1.0, 100),
                    (31.4, 3.0, 120),
                    (36.0, 503.0, 999),
                ]
            },
            {42: prs.ServerLogParser(expected_mob_count=0)},
            prs.CombinedLogParser(),
            prs.StableGate(
                True, True, True, 25.0, {42}, population_marker_verified=True
            ),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 20.0, 10.0),
            mob_count=0,
        )
        gate = cast(dict[str, object], result["gate"])
        self.assertTrue(gate["sample_window"])
        self.assertEqual(result["actual_sample_duration_seconds"], 20.4)
        room = cast(list[dict[str, object]], result["rooms"])[0]
        self.assertEqual(room["sample_count"], 2)
        self.assertAlmostEqual(cast(float, room["cpu_percent"]), 9.8, places=2)
        aggregate = cast(dict[str, object], result["aggregate"])
        self.assertLess(cast(float, aggregate["cpu_percent_total"]), 10.0)

    def test_fixed_route_active_cushion_is_six_seconds(self):
        probe = (
            Path(__file__)
            .with_name("live_gameplay_probe.gd")
            .read_text(encoding="utf-8")
        )
        self.assertIn("const FIXED_ROUTE_POLL_MARGIN_SEC := 6.0", probe)

    def test_fixed_population_missing_workload_end_marker_fails_closed(self):
        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                passed=True,
                fixed_workload_ended=False,
                metrics={
                    "dead": False,
                    "mobs_start": 0,
                    "mobs_end": 0,
                    "max_projectiles": 1,
                    "movement": 10.0,
                    "mob_displacement": 0.0,
                    "workload_invalid": False,
                },
                errors=[],
                telemetry={},
            ),
        )
        result = prs.build_result(
            1,
            [client],
            {42: [(11.0, 1.0, 100), (31.0, 2.0, 120)]},
            {42: prs.ServerLogParser(expected_mob_count=0)},
            prs.CombinedLogParser(),
            prs.StableGate(
                True, True, True, 21.0, {42}, population_marker_verified=True
            ),
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 20.0, 10.0, active_end_rows_discarded=1),
            mob_count=0,
        )
        gate = cast(dict[str, object], result["gate"])
        self.assertFalse(gate["fixed_workload_end_observed"])
        self.assertEqual(
            cast(dict[str, object], result["active_sample_proof"])[
                "discarded_end_rows"
            ],
            1,
        )

    def test_final_fixed_population_gate_fails_closed_and_reports_marker_receipt(self):
        client = mock.Mock(parser=mock.Mock(ready=True), end_monotonic=20.0)
        missing_gate = prs.evaluate_stable_gate(
            rooms=1,
            active_pids=[42],
            clients=[client],
            stable_started=10.0,
            now=18.1,
            samples={42: [(10.0, 1.0, 100), (11.0, 2.0, 200)]},
            pinned_pids={42},
            server_parsers={},
            mob_count=0,
        )
        self.assertFalse(missing_gate.population_marker_verified)
        self.assertFalse(missing_gate.ok)
        failed = prs.ServerLogParser(expected_mob_count=0)
        failed.feed(
            "[PROFILE_POPULATION_FAILED] mode=fixed_population expectedcount=0 actualcount=1 seed=120120\n"
        )
        failed_gate = prs.evaluate_stable_gate(
            rooms=1,
            active_pids=[42],
            clients=[client],
            stable_started=10.0,
            now=18.1,
            samples={42: [(10.0, 1.0, 100), (11.0, 2.0, 200)]},
            pinned_pids={42},
            server_parsers={42: failed},
            mob_count=0,
        )
        self.assertFalse(failed_gate.population_marker_verified)
        result = prs.build_result(
            1,
            [],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 100)]},
            {42: failed},
            prs.CombinedLogParser(),
            failed_gate,
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 1.0, 0.0),
            mob_count=0,
        )
        receipts = cast(list[dict[str, object]], result["population_markers"])
        self.assertEqual(receipts[0]["expected"], 0)
        self.assertEqual(receipts[0]["actual"], 1)
        self.assertEqual(receipts[0]["seed"], 120120)
        self.assertTrue(receipts[0]["failed"])
        self.assertFalse(result["marker_verified"])

    def test_human_args_force_one_room_deadline_and_reject_benchmark_knobs(self):
        args = prs.parse_args(["--human"])
        self.assertTrue(args.human)
        self.assertEqual(args.rooms, 1)
        self.assertEqual(args.deadline_seconds, 1800)
        self.assertEqual(args.warmup_seconds, 0.0)
        self.assertEqual(args.sample_seconds, 0.0)
        self.assertEqual(prs.parse_args([]).deadline_seconds, 180)
        with self.assertRaises(SystemExit):
            prs.parse_args(["--human", "--rooms", "2"])
        with self.assertRaises(SystemExit):
            prs.parse_args(["--human", "--warmup-seconds", "1"])
        with self.assertRaises(SystemExit):
            prs.parse_args(["--human", "--sample-seconds", "1"])

    def test_human_env_only_goes_to_client_probe_env(self):
        human_env = prs.client_probe_env(
            account=prs.Account("u", "p"),
            lobby_hold_seconds=0.0,
            warmup_seconds=0.0,
            sample_seconds=0.0,
            human=True,
        )
        auto_env = prs.client_probe_env(
            account=prs.Account("u", "p"),
            lobby_hold_seconds=0.0,
            warmup_seconds=0.0,
            sample_seconds=0.0,
        )
        self.assertEqual(human_env["NOIKAR_PROFILE_HUMAN"], "1")
        self.assertNotIn("NOIKAR_PROFILE_HUMAN", auto_env)
        self.assertNotIn(
            "NOIKAR_PROFILE_HUMAN", prs.noray_env(Path("/repo"), Path("/godot"), "cred")
        )

    def test_client_parser_recognizes_human_ready_marker_without_pass(self):
        parser = prs.ClientLogParser()
        parser.feed(
            "[LIVE-PROBE] HUMAN_READY oid=abc npc_stride_counts={1:20} interpolator_buffer_counts={2:20}\n"
        )
        self.assertTrue(parser.ready)
        self.assertTrue(parser.human_ready)
        self.assertFalse(parser.passed)
        self.assertEqual(parser.telemetry["npc_stride_counts"], {"1": 20})

    def test_human_result_is_manual_session_not_benchmark(self):
        client = mock.Mock(
            process=mock.Mock(returncode=None, pid=501),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                human_ready=True,
                passed=False,
                metrics={},
                errors=[],
                telemetry={},
            ),
        )
        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 100)]},
            {},
            prs.CombinedLogParser(),
            prs.StableGate(True, True, True, 0.0, {42}),
            Path("artifacts"),
            human=True,
            supervisor_pid=999,
            requested_deadline_seconds=1800,
        )
        self.assertEqual(result["outcome"], "manual_session_not_benchmark")
        self.assertEqual(result["supervisor_pid"], 999)
        self.assertEqual(result["client_pids"], [501])
        self.assertFalse(cast(dict[str, object], result["gate"])["functional"])

    def test_player_count_args_force_one_no_mob_room_with_sample_window(self):
        args = prs.parse_args(
            ["--player-count", "4", "--warmup-seconds", "1", "--sample-seconds", "2"]
        )
        self.assertEqual(args.player_count, 4)
        self.assertEqual(args.rooms, 1)
        self.assertEqual(args.mob_count, 0)
        self.assertEqual(
            prs.parse_args(
                [
                    "--player-count",
                    "8",
                    "--mob-count",
                    "0",
                    "--warmup-seconds",
                    "1",
                    "--sample-seconds",
                    "2",
                ]
            ).player_count,
            8,
        )
        with self.assertRaises(SystemExit):
            prs.parse_args(
                [
                    "--player-count",
                    "3",
                    "--warmup-seconds",
                    "1",
                    "--sample-seconds",
                    "2",
                ]
            )
        with self.assertRaises(SystemExit):
            prs.parse_args(["--player-count", "2", "--warmup-seconds", "1"])
        with self.assertRaises(SystemExit):
            prs.parse_args(
                [
                    "--player-count",
                    "2",
                    "--rooms",
                    "2",
                    "--warmup-seconds",
                    "1",
                    "--sample-seconds",
                    "2",
                ]
            )
        with self.assertRaises(SystemExit):
            prs.parse_args(
                [
                    "--player-count",
                    "2",
                    "--benchmark",
                    "D",
                    "--warmup-seconds",
                    "1",
                    "--sample-seconds",
                    "2",
                ]
            )

    def test_player_count_env_wires_host_and_joiner_roles(self):
        host_env = prs.client_probe_env(
            account=prs.Account("u0", "p"),
            lobby_hold_seconds=0.0,
            warmup_seconds=1.0,
            sample_seconds=2.0,
            mob_count=0,
            player_count=4,
            player_index=0,
        )
        join_env = prs.client_probe_env(
            account=prs.Account("u1", "p"),
            lobby_hold_seconds=0.0,
            warmup_seconds=1.0,
            sample_seconds=2.0,
            mob_count=0,
            player_count=4,
            player_index=1,
            room_oid="room-oid",
        )
        self.assertEqual(host_env["NOIKAR_PROFILE_PLAYER_COUNT"], "4")
        self.assertEqual(host_env["NOIKAR_PROFILE_PLAYER_INDEX"], "0")
        self.assertNotIn("NOIKAR_PROFILE_JOIN_OID", host_env)
        self.assertEqual(join_env["NOIKAR_PROFILE_JOIN_OID"], "room-oid")
        self.assertEqual(join_env["NOIKAR_PROFILE_EXPECTED_MOB_COUNT"], "0")
        self.assertEqual(join_env["NOIKAR_PROFILE_FIXED_ROUTE"], "1")

    def test_client_probe_env_wires_supervisor_release_file(self):
        env = prs.client_probe_env(
            account=prs.Account("u", "p"),
            lobby_hold_seconds=0.0,
            warmup_seconds=1.0,
            sample_seconds=2.0,
            release_file=Path("noikar-release"),
        )

        self.assertEqual(env["NOIKAR_PROFILE_RELEASE_FILE"], "noikar-release")

    def test_incremental_log_reader_only_returns_appended_complete_lines(self):
        with tempfile.TemporaryDirectory() as temp_s:
            log = Path(temp_s) / "noray.log"
            log.write_text("active error\n", encoding="utf-8")
            chunk, offset = prs.read_incremental_text(log, 0)
            self.assertEqual(chunk, "active error\n")
            partial_offset = offset
            log.write_text(
                log.read_text(encoding="utf-8") + "teardown er",
                encoding="utf-8",
            )
            chunk, offset = prs.read_incremental_text(log, offset)
            self.assertEqual(chunk, "")
            self.assertEqual(offset, partial_offset)
            log.write_text(
                log.read_text(encoding="utf-8") + "ror\nnext line\nfragment",
                encoding="utf-8",
            )
            chunk, offset = prs.read_incremental_text(log, offset)
            self.assertEqual(chunk, "teardown error\nnext line\n")
            chunk, offset = prs.read_incremental_text(log, offset)
            self.assertEqual(chunk, "")

    def test_server_parser_routes_teardown_errors_without_hiding_active_errors(self):
        server = prs.ServerLogParser(expected_mob_count=0)
        combined = prs.CombinedLogParser()

        server.feed("RPC ERROR active\n", teardown_only=False)
        combined.feed("RPC ERROR active\n", teardown_only=False)
        server.feed("RPC ERROR teardown\n", teardown_only=True)
        combined.feed("RPC ERROR teardown\n", teardown_only=True)

        self.assertEqual(server.errors, ["RPC ERROR active"])
        self.assertEqual(server.active_errors, ["RPC ERROR active"])
        self.assertEqual(server.teardown_errors, ["RPC ERROR teardown"])
        self.assertEqual(combined.errors, ["RPC ERROR active"])
        self.assertEqual(combined.teardown_errors, ["RPC ERROR teardown"])

    def test_same_poll_workload_completion_routes_new_noray_errors_to_teardown(self):
        with tempfile.TemporaryDirectory() as temp_s:
            log = Path(temp_s) / "noray.log"
            log.write_text("[BENCHMARK] active perf row\n", encoding="utf-8")
            combined = prs.CombinedLogParser()
            server = prs.ServerLogParser(expected_mob_count=0)
            offset = prs.route_incremental_noray_log(
                log,
                0,
                combined,
                {42: server},
                teardown_only=False,
            )
            client_parser = prs.ClientLogParser(expected_mob_count=0)
            client_parser.feed("[LIVE-PROBE] FIXED_WORKLOAD_END\n")
            client = mock.Mock(parser=client_parser, end_monotonic=None)
            closed = prs.update_fixed_workload_closed(False, [client], mob_count=0)
            log.write_text(
                log.read_text(encoding="utf-8") + "RPC ERROR after release\n",
                encoding="utf-8",
            )
            offset = prs.route_incremental_noray_log(
                log,
                offset,
                combined,
                {42: server},
                teardown_only=closed,
            )

            self.assertTrue(closed)
            self.assertEqual(server.errors, [])
            self.assertEqual(server.teardown_errors, ["RPC ERROR after release"])
            self.assertEqual(combined.errors, [])
            self.assertEqual(combined.teardown_errors, ["RPC ERROR after release"])
            self.assertGreater(offset, 0)

    def test_server_teardown_errors_are_reported_without_failing_active_error_gate(
        self,
    ):
        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                passed=True,
                fixed_workload_ended=True,
                metrics={
                    "dead": False,
                    "mobs_start": 0,
                    "mobs_end": 0,
                    "max_projectiles": 1,
                    "movement": 10.0,
                    "mob_displacement": 0.0,
                    "workload_invalid": False,
                },
                errors=[],
                telemetry={},
            ),
        )
        server = prs.ServerLogParser(expected_mob_count=0)
        combined = prs.CombinedLogParser()
        server.feed("RPC ERROR after release\n", teardown_only=True)
        combined.feed("RPC ERROR after release\n", teardown_only=True)

        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 120)]},
            {42: server},
            combined,
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(0.0, 1.0, 0.0),
            mob_count=0,
        )

        gate = cast(dict[str, object], result["gate"])
        proof = cast(dict[str, object], result["active_sample_proof"])
        rooms = cast(list[dict[str, object]], result["rooms"])
        self.assertTrue(gate["active_sample_errors"])
        self.assertEqual(proof["active_server_error_count"], 0)
        self.assertEqual(proof["teardown_server_error_count"], 1)
        self.assertEqual(rooms[0]["sync_rpc_errors"], [])
        self.assertEqual(rooms[0]["teardown_rpc_errors"], ["RPC ERROR after release"])
        self.assertEqual(
            result["combined_server_teardown_errors"], ["RPC ERROR after release"]
        )

    def test_active_server_errors_remain_blocking_even_with_teardown_errors(self):
        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=mock.Mock(
                ready=True,
                passed=True,
                fixed_workload_ended=True,
                metrics={
                    "dead": False,
                    "mobs_start": 0,
                    "mobs_end": 0,
                    "max_projectiles": 1,
                    "movement": 10.0,
                    "mob_displacement": 0.0,
                    "workload_invalid": False,
                },
                errors=[],
                telemetry={},
            ),
        )
        server = prs.ServerLogParser(expected_mob_count=0)
        combined = prs.CombinedLogParser()
        server.feed("RPC ERROR active\n", teardown_only=False)
        combined.feed("RPC ERROR active\n", teardown_only=False)
        server.feed("RPC ERROR teardown\n", teardown_only=True)
        combined.feed("RPC ERROR teardown\n", teardown_only=True)

        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 120)]},
            {42: server},
            combined,
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(0.0, 1.0, 0.0),
            mob_count=0,
        )

        gate = cast(dict[str, object], result["gate"])
        proof = cast(dict[str, object], result["active_sample_proof"])
        self.assertFalse(gate["active_sample_errors"])
        self.assertEqual(proof["active_server_error_count"], 1)
        self.assertEqual(proof["teardown_server_error_count"], 1)

    def test_client_parser_classifies_post_pass_errors_as_teardown_only(self):
        parser = prs.ClientLogParser(expected_mob_count=0)
        parser.feed("RPC ERROR during active sample\n")
        parser.feed("[LIVE-PROBE] FIXED_WORKLOAD_END\n")
        parser.feed("RPC ERROR after workload finished\n")
        parser.feed("[LIVE-PROBE] PASS oid=abc\n")
        parser.feed("ERROR after pass\n")

        self.assertEqual(parser.active_errors, ["RPC ERROR during active sample"])
        self.assertEqual(
            parser.teardown_errors,
            ["RPC ERROR after workload finished", "ERROR after pass"],
        )

    def test_active_sample_errors_fail_result_gate_but_teardown_errors_are_reported(
        self,
    ):
        parser = prs.ClientLogParser(expected_mob_count=0)
        parser.feed(
            "[LIVE-PROBE] spawned player=123 mobs=0 fixed_population=true\n"
            "[LIVE-PROBE] movement=10.0m mob_displacement=0.0m max_projectiles=1 "
            "attacks=0->1 dead=false mobs=0->0 workload=fixed_route sample=1.00s "
            "nearest_npc_m=null/null/null observed_npcs_90m=0/0 alive_npcs=0 "
            "player_sample_travel=10.0m endpoint=0.0m invalid=false\n"
            "RPC ERROR active\n"
            "[LIVE-PROBE] FIXED_WORKLOAD_END\n"
            "[LIVE-PROBE] PASS oid=abc\n"
            "RPC ERROR teardown\n"
        )
        client = mock.Mock(
            process=mock.Mock(returncode=0),
            index=0,
            account=prs.Account("u", "p"),
            parser=parser,
        )

        result = prs.build_result(
            1,
            [client],
            {42: [(0.0, 1.0, 100), (1.0, 2.0, 120)]},
            {},
            prs.CombinedLogParser(),
            prs.StableGate(True, True, True, 8.1, {42}),
            Path("artifacts"),
            profile=prs.ProfileWindow(0.0, 1.0, 0.0),
            mob_count=0,
        )

        gate = cast(dict[str, object], result["gate"])
        proof = cast(dict[str, object], result["active_sample_proof"])
        clients = cast(list[dict[str, object]], result["clients"])
        self.assertFalse(gate["active_sample_errors"])
        self.assertEqual(proof["active_error_count"], 1)
        self.assertEqual(proof["teardown_error_count"], 1)
        self.assertEqual(clients[0]["teardown_errors"], ["RPC ERROR teardown"])

    def test_client_parser_captures_admitted_oid_for_joiners(self):
        parser = prs.ClientLogParser(expected_mob_count=0)
        parser.feed("[LIVE-PROBE] admitted oid=abc123\n")
        self.assertEqual(parser.admitted_oid, "abc123")

    def test_player_count_result_reports_clients_separately_from_one_server_room(self):
        clients = []
        for index in range(4):
            clients.append(
                mock.Mock(
                    process=mock.Mock(returncode=0),
                    index=index,
                    account=prs.Account(f"u{index}", "p"),
                    end_monotonic=None,
                    parser=mock.Mock(
                        ready=True,
                        passed=True,
                        fixed_workload_ended=True,
                        metrics={
                            "dead": False,
                            "mobs_start": 0,
                            "mobs_end": 0,
                            "max_projectiles": 0,
                            "movement": 10.0,
                            "mob_displacement": 0.0,
                            "workload_invalid": False,
                        },
                        errors=[],
                        telemetry={},
                    ),
                )
            )
        gate = prs.evaluate_stable_gate(
            rooms=1,
            active_pids=[42],
            clients=clients,
            stable_started=10.0,
            now=18.1,
            samples={42: [(10.0, 1.0, 100), (12.0, 2.0, 200)]},
            pinned_pids={42},
            server_parsers={42: prs.ServerLogParser(expected_mob_count=0)},
            mob_count=0,
            expected_clients=4,
        )
        result = prs.build_result(
            1,
            clients,
            {42: [(11.0, 1.0, 100), (13.0, 2.0, 200)]},
            {},
            prs.CombinedLogParser(),
            gate,
            Path("artifacts"),
            profile=prs.ProfileWindow(1.0, 2.0, 10.0),
            mob_count=0,
            player_count=4,
        )
        self.assertEqual(result["rooms_requested"], 1)
        self.assertEqual(result["player_count"], 4)
        self.assertEqual(len(cast(list[dict[str, object]], result["clients"])), 4)
        self.assertEqual(len(cast(list[dict[str, object]], result["rooms"])), 1)
        gate_result = cast(dict[str, object], result["gate"])
        self.assertTrue(gate_result["clients_ready"])
        self.assertFalse(gate_result["projectile"])
        self.assertTrue(gate_result["mob_movement"])

    def test_signal_handler_context_requests_stop_and_restores_handlers(self):
        original_int = signal.getsignal(signal.SIGINT)
        original_term = signal.getsignal(signal.SIGTERM)
        stop = prs.StopRequest()
        with prs.install_stop_handlers(stop):
            signal.raise_signal(signal.SIGTERM)
            self.assertTrue(stop.requested)
        self.assertIs(signal.getsignal(signal.SIGINT), original_int)
        self.assertIs(signal.getsignal(signal.SIGTERM), original_term)

    def test_godot_orbit_probe_uses_input_intentions_and_sample_only_metrics(self):
        godot = Path("/Applications/Godot.app/Contents/MacOS/Godot")
        if not godot.exists():
            self.skipTest(f"Godot executable not found: {godot}")
        repo = Path(__file__).resolve().parents[2]
        with tempfile.NamedTemporaryFile(
            "w", suffix=".gd", prefix="live_probe_orbit_unit_", delete=False
        ) as script:
            script_path = Path(script.name)
            script.write(
                """extends "res://tests/manual/live_gameplay_probe.gd"

class FakeLogic:
\textends Node
\tvar look_yaw := 0.0

func _initialize() -> void:
\tcall_deferred("_run")

func _make_mob(pos: Vector3) -> Node3D:
\tvar mob := Node3D.new()
\tmob.position = pos
\treturn mob

func _pressed() -> Dictionary:
\treturn {
\t\t"forward": Input.is_action_pressed("move_forward"),
\t\t"backward": Input.is_action_pressed("move_backward"),
\t\t"left": Input.is_action_pressed("move_left"),
\t\t"right": Input.is_action_pressed("move_right"),
\t}

func _assert_input(label: String, expected: Dictionary, failures: Array) -> void:
\tvar actual := _pressed()
\tfor key in expected:
\t\tif actual[key] != expected[key]:
\t\t\tfailures.append("%s expected %s=%s got %s" % [label, key, expected[key], actual[key]])

func _run() -> void:
\tvar failures := []
\tvar player := Node3D.new()
\tvar mobs := Node.new()
\tvar logic := FakeLogic.new()
\troot.add_child(player)
\troot.add_child(mobs)
\tplayer.global_position = Vector3.ZERO

\tvar mob := _make_mob(Vector3(0, 0, -85))
\tmobs.add_child(mob)
\t_drive_orbit_intention(player, mobs, logic)
\t_assert_input("far", {"forward": true, "backward": false, "left": false, "right": false}, failures)

\tmob.global_position = Vector3(0, 0, -10)
\t_drive_orbit_intention(player, mobs, logic)
\t_assert_input("near", {"forward": false, "backward": true, "left": false, "right": false}, failures)

\tmob.global_position = Vector3(0, 0, -22)
\t_drive_orbit_intention(player, mobs, logic)
\t_assert_input("annulus", {"forward": false, "backward": false, "left": false, "right": true}, failures)
\tif abs(logic.look_yaw) > 0.001:
\t\tfailures.append("logic look_yaw should face the mob without touching pose")
\tif player.global_position != Vector3.ZERO or player.rotation != Vector3.ZERO:
\t\tfailures.append("orbit driver must not mutate player pose")

\tvar stats := _new_workload_sample(player)
\t_record_workload_sample(stats, player, mobs)
\tplayer.global_position = Vector3(3, 0, 4)
\tmob.global_position = Vector3(0, 0, -200)
\t_record_workload_sample(stats, player, mobs)
\tvar summary := _finish_workload_sample(stats, player)
\tif summary.nearest_npc_min_m < 21.9 or summary.nearest_npc_max_m > 205.1:
\t\tfailures.append("nearest NPC min/max were not sampled from observed state")
\tif summary.observed_npcs_90m_min != 0 or summary.observed_npcs_90m_max != 1:
\t\tfailures.append("within-90m min/max should include sample-only windows")
\tif summary.player_sample_travel_m < 4.9 or summary.player_sample_endpoint_m < 4.9:
\t\tfailures.append("player travel summary did not use sample positions")
\tif summary.workload_invalid:
\t\tfailures.append("mixed near/far sample should remain valid")

\t_close_peer()
\tif failures.is_empty():
\t\tprint("LIVE_PROBE_ORBIT_UNIT_PASS")
\t\tquit(0)
\tfor failure in failures:
\t\tpush_error(failure)
\tquit(1)
"""
            )
        try:
            env = dict(**os.environ, NOIKAR_BACKEND_URL="http://127.0.0.1:18090")
            result = subprocess.run(
                [
                    str(godot),
                    "--headless",
                    "--path",
                    str(repo),
                    "--script",
                    str(script_path),
                ],
                text=True,
                capture_output=True,
                env=env,
                timeout=30,
            )
        finally:
            script_path.unlink(missing_ok=True)
        output = result.stdout + result.stderr
        self.assertIn("LIVE_PROBE_ORBIT_UNIT_PASS", output)
        self.assertNotIn("SCRIPT ERROR", output)

    def test_godot_fixed_route_uses_same_input_intentions_for_all_counts_without_pose_writes(
        self,
    ):
        godot = Path("/Applications/Godot.app/Contents/MacOS/Godot")
        if not godot.exists():
            self.skipTest(f"Godot executable not found: {godot}")
        repo = Path(__file__).resolve().parents[2]
        with tempfile.NamedTemporaryFile(
            "w", suffix=".gd", prefix="live_probe_fixed_route_unit_", delete=False
        ) as script:
            script_path = Path(script.name)
            script.write(
                """extends "res://tests/manual/live_gameplay_probe.gd"

class FakeLogic:
\textends Node
\tvar look_yaw := 0.0

func _initialize() -> void:
\tcall_deferred("_run")

func _pressed() -> Dictionary:
\treturn {
\t\t"forward": Input.is_action_pressed("move_forward"),
\t\t"backward": Input.is_action_pressed("move_backward"),
\t\t"left": Input.is_action_pressed("move_left"),
\t\t"right": Input.is_action_pressed("move_right"),
\t\t"shoot": Input.is_action_pressed("shoot"),
\t}

func _signature() -> Array:
\tvar player := Node3D.new()
\tvar logic := FakeLogic.new()
\troot.add_child(player)
\troot.add_child(logic)
\tplayer.global_position = Vector3(0, 0, -240)
\tvar before_pos := player.global_position
\tvar before_rot := player.rotation
\tvar frames := []
\tfor i in range(8):
\t\t_drive_fixed_route_intention(player, logic, i)
\t\tframes.append(_pressed().duplicate())
\tif player.global_position != before_pos or player.rotation != before_rot:
\t\tframes.append({"pose_write": true})
\tplayer.queue_free()
\tlogic.queue_free()
\t_close_peer()
\treturn frames

func _run() -> void:
\tvar failures := []
\tvar zero := _signature()
\tvar one := _signature()
\tvar twenty := _signature()
\tif zero != one or zero != twenty:
\t\tfailures.append("fixed route input intentions changed by population count")
\tif zero.size() != 8:
\t\tfailures.append("expected eight fixed route intention samples")
\tfor frame in zero:
\t\tif frame.get("pose_write", false):
\t\t\tfailures.append("fixed route driver must not mutate player pose")
\t\tif not (frame.forward or frame.backward or frame.left or frame.right):
\t\t\tfailures.append("fixed route should produce movement input")
\tif failures.is_empty():
\t\tprint("LIVE_PROBE_FIXED_ROUTE_UNIT_PASS")
\t\tquit(0)
\tfor failure in failures:
\t\tpush_error(failure)
\tquit(1)
"""
            )
        try:
            env = dict(**os.environ, NOIKAR_BACKEND_URL="http://127.0.0.1:18090")
            result = subprocess.run(
                [
                    str(godot),
                    "--headless",
                    "--path",
                    str(repo),
                    "--script",
                    str(script_path),
                ],
                text=True,
                capture_output=True,
                env=env,
                timeout=30,
            )
        finally:
            script_path.unlink(missing_ok=True)
        output = result.stdout + result.stderr
        self.assertIn("LIVE_PROBE_FIXED_ROUTE_UNIT_PASS", output)
        self.assertNotIn("SCRIPT ERROR", output)

    def test_cleanup_ownership_helpers(self):
        cleanup = prs.CleanupPlan()
        proc = mock.Mock()
        proc.pid = 123
        proc.poll.side_effect = [None, 0, 0]
        cleanup.processes.append(proc)
        with (
            mock.patch.object(os, "killpg") as killpg,
            mock.patch.object(os, "getpgid", return_value=999),
        ):
            cleanup.terminate_process_groups()
        killpg.assert_called_with(999, signal.SIGTERM)

    def test_cleanup_port_failure_exits_nonzero(self):
        with self.assertRaises(SystemExit) as raised:
            prs.enforce_ports_clear({15432: True, 18090: False})
        self.assertEqual(raised.exception.code, 3)


if __name__ == "__main__":
    unittest.main()
