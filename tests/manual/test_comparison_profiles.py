import json
import unittest
import os
import subprocess
import tempfile
from types import SimpleNamespace
from pathlib import Path
import profile_room_scaling as prs

class ComparisonProfileTests(unittest.TestCase):
    def test_default_remains_thirty_snapshot_hz(self):
        args = prs.parse_args([])
        self.assertIsNone(args.netfox_profile)
        self.assertEqual(args.npc_rate_hz, 30)

    def test_profile_propagates_to_server_and_clients(self):
        for profile, hz in [("compare30", 30), ("compare60", 60)]:
            args = prs.parse_args(["--netfox-profile", profile, "--benchmark", "E",
                                   "--warmup-seconds", "5", "--sample-seconds", "10"])
            self.assertEqual(args.npc_rate_hz, hz)
            server = prs.noray_env(Path("/repo"), Path("/godot"), "test", hz, netfox_profile=profile)
            client = prs.client_probe_env(account=prs.Account("test", "test"),
                lobby_hold_seconds=0, warmup_seconds=5, sample_seconds=10, netfox_profile=profile)
            self.assertEqual(server["NOIKAR_NETFOX_PROFILE"], profile)
            self.assertEqual(client["NOIKAR_NETFOX_PROFILE"], profile)
            self.assertEqual(server["NOIKAR_SERVER_MAX_FPS"], "75")

    def test_conflicts_and_unsupported_population_fail_before_launch(self):
        base = ["--netfox-profile", "compare60", "--warmup-seconds", "5", "--sample-seconds", "10"]
        for extra in [["--npc-rate-hz", "30"], ["--player-count", "8"], ["--player-count", "20"], ["--human"]]:
            with self.subTest(extra=extra), self.assertRaises(SystemExit):
                prs.parse_args(base + extra)
        with self.assertRaises(SystemExit):
            prs.parse_args(["--npc-rate-hz", "60"])

    def test_stride_derivation_preserves_legacy_and_requires_verified_comparison_clock(self):
        for hz, stride in [(30, 1), (15, 2), (10, 3)]:
            self.assertEqual(prs.expected_npc_stride(hz), stride)
        for profile, hz in [("compare30", 30), ("compare60", 60)]:
            proof = prs.npc_stride_proof([], hz, 20, [{"1": 20}],
                netfox_profile=profile, verified_native_hz=hz)
            self.assertTrue(proof["ok"])
            self.assertEqual(proof["expected_stride"], 1)
            self.assertFalse(prs.npc_stride_proof([], hz, 20, [{"1": 20}],
                netfox_profile=profile)["ok"])
        for profile, native, requested in [("compare60", 30, 60), ("compare30", 60, 30),
                                          ("compare60", 60, 30), ("compare60", 60, 40),
                                          ("bad", 60, 60)]:
            self.assertIsNone(prs.expected_npc_stride(requested,
                netfox_profile=profile, verified_native_hz=native))
        for unsupported in [60, 20, 7, 0, -30]:
            self.assertIsNone(prs.expected_npc_stride(unsupported))

    def test_verified_native60_still_rejects_incomplete_unknown_or_extra_population(self):
        for observed in [[], [{"1": 19}], [{"1": 20, "missing": 1}],
                         [{"1": 20, "unknown": 1}], [{"1": 20, "2": 1}]]:
            self.assertFalse(prs.npc_stride_proof([], 60, 20, observed,
                netfox_profile="compare60", verified_native_hz=60)["ok"])
        parser = prs.CombinedLogParser()
        parser.feed("[PERF] npc_authoritative_stride_counts={1:20}")
        self.assertEqual(parser.authoritative_stride_intervals, [{"1": 20}])

    def test_phase_trace_is_bounded_numeric_only_and_opt_in_on_comparison_clients(self):
        safe = "[PROFILE_PHASE] t_usec=10 source=phase_event phase=2 ui_before=4 ui_after=4 network_tick=12"
        self.assertEqual(prs.safe_phase_trace(safe + " PRIVATE_SUFFIX"), [safe])
        self.assertEqual(prs.safe_phase_trace("[PROFILE_PHASE] arbitrary_secret=value"), [])
        self.assertEqual(len(prs.safe_phase_trace((safe + "\n") * 200)), 128)
        base = dict(account=prs.Account("test", "test"), lobby_hold_seconds=0,
                    warmup_seconds=5, sample_seconds=10)
        self.assertNotIn("NOIKAR_PROFILE_PHASE_TRACE", prs.client_probe_env(**base))
        self.assertEqual(prs.client_probe_env(**base, netfox_profile="compare30")["NOIKAR_PROFILE_PHASE_TRACE"], "1")

    def test_readback_verifies_cached_values_not_only_settings(self):
        row = dict(profile="compare60", role="server", network_hz=60, physics_hz=50,
                   sync_to_physics=False, max_fps=75, history_ticks=300,
                   display_offset_ticks=2, input_delay_ticks=0, input_redundancy=3,
                   stage="before_network_start")
        text = "prefix [NETFOX_PROFILE] " + json.dumps(row)
        self.assertTrue(prs.verify_profile_readback(prs.profile_readbacks(text), "compare60", "server"))
        for key, value in [("network_hz", 30), ("physics_hz", 60), ("history_ticks", 128), ("sync_to_physics", True)]:
            with self.subTest(key=key):
                bad = dict(row); bad[key] = value
                self.assertFalse(prs.verify_profile_readback([bad], "compare60", "server"))
        self.assertFalse(prs.verify_profile_readback([], "compare60", "server"))

class LoadTwentyTests(unittest.TestCase):
    def args(self, profile="compare60"):
        return prs.parse_args(["--player-count", "20", "--mob-count", "20", "--netfox-profile", profile,
                               "--warmup-seconds", "10", "--sample-seconds", "60"])

    def population(self):
        ids = list(range(2, 22))
        return dict(owners=ids, input_authorities=ids, connected_peers=ids, authenticated_accounts=20,
                    authenticated_peers=20, lobby_players=20, red=10, blue=10, alive_players=20,
                    server_state_authorities=20, live_mobs=20, alive_mobs=20,
                    positions={str(i): [float(i), 0.0, 0.0] for i in ids})

    def test_real_twenty_env_role_and_command_are_explicit(self):
        for profile in ["compare30", "compare60"]:
            args = self.args(profile)
            self.assertEqual(args.player_count, 20)
            server = prs.noray_env(Path("/repo"), Path("/godot"), "test", args.npc_rate_hz,
                                   mob_count=20, netfox_profile=profile, player_count=20, start_file=Path("/start"))
            client = prs.client_probe_env(account=prs.Account("test", "test"), lobby_hold_seconds=0,
                       warmup_seconds=10, sample_seconds=60, mob_count=20, player_count=20, player_index=19,
                       netfox_profile=profile, selection_file=Path("/select"), start_file=Path("/start"))
            self.assertEqual(server["NOIKAR_BENCHMARK_PLAYER_LIMIT"], "20")
            self.assertNotIn("NOIKAR_BENCHMARK_CLIENT", server)
            self.assertEqual(client["NOIKAR_BENCHMARK_CLIENT"], "1")
            self.assertEqual(client["NOIKAR_PROFILE_PLAYER_INDEX"], "19")
            self.assertEqual(client["NOIKAR_PROFILE_START_FILE"], server["NOIKAR_PROFILE_START_FILE"])
            self.assertIn("--headless", prs.client_command(Path("/godot"), Path("/repo"), 20))
            self.assertNotIn("--headless", prs.client_command(Path("/godot"), Path("/repo"), 2))

    def test_twenty_requires_exact_profile_and_population(self):
        for args in [["--player-count", "20"], ["--player-count", "20", "--mob-count", "20"],
                     ["--player-count", "20", "--netfox-profile", "compare30", "--mob-count", "0"],
                     ["--player-count", "19"], ["--player-count", "20.0"]]:
            with self.subTest(args=args), self.assertRaises(SystemExit):
                prs.parse_args(args + ["--warmup-seconds", "10", "--sample-seconds", "60"])

    def test_twenty_unique_indices_owners_and_ten_per_team_no_clamping(self):
        rows = [dict(index=i, owner=i+2, team=1 if i<10 else 2) for i in range(20)]
        self.assertTrue(prs.verified_twenty_owners(rows))
        for bad in [rows[:19], rows + [rows[0]], [dict(row, owner=2) for row in rows],
                    [dict(row, team=1) for row in rows]]:
            self.assertFalse(prs.verified_twenty_owners(bad))

    def test_actual_population_rejects_shortage_mismatch_unknown_types(self):
        row = self.population()
        self.assertTrue(prs.verified_owner_population(row, set(range(2, 22))))
        for key, value in [("red", 9), ("blue", 11), ("alive_mobs", 19), ("authenticated_accounts", 19),
                           ("server_state_authorities", 19), ("owners", [2]*20), ("input_authorities", [1]*20),
                           ("live_mobs", 20.0), ("positions", {})]:
            self.assertFalse(prs.verified_owner_population(dict(row, **{key: value})))
        self.assertFalse(prs.verified_owner_population(row, set(range(3, 23))))
        self.assertEqual(prs.authoritative_moving_owners([row]), set())
        moved = self.population(); moved["positions"] = {key: [p[0]+2, p[1], p[2]] for key, p in row["positions"].items()}
        self.assertEqual(prs.authoritative_moving_owners([row, moved]), set(range(2, 22)))

    def test_capacity_marker_uses_real_clone_readback(self):
        row = dict(role="server", requested_players=20, max_players_per_team=10, total_capacity=20,
                   runtime_clone=True, authored_max_players_per_team=3)
        marker = "[PROFILE_CAPACITY] " + json.dumps(row)
        self.assertTrue(prs.verified_capacity_readback(marker, "server"))
        self.assertFalse(prs.verified_capacity_readback(marker, "client"))
        self.assertFalse(prs.verified_capacity_readback(marker + "\n" + marker, "server"))
        for key, value in [("runtime_clone", False), ("authored_max_players_per_team", 10), ("total_capacity", 6)]:
            self.assertFalse(prs.verified_capacity_readback("[PROFILE_CAPACITY] " + json.dumps(dict(row, **{key:value})), "server"))

    def test_headless_load20_starts_as_real_client_with_actual_main_capacity_readback(self):
        godot = Path("/Applications/Godot.app/Contents/MacOS/Godot")
        if not godot.exists(): self.skipTest("Godot unavailable")
        repo = Path(__file__).resolve().parents[2]
        env = prs.client_probe_env(account=prs.Account("fixture", "fixture"), lobby_hold_seconds=0,
                  warmup_seconds=10, sample_seconds=60, mob_count=20, player_count=20,
                  player_index=0, netfox_profile="compare60")
        with tempfile.TemporaryDirectory(prefix="noikar-load20-fixture-") as directory:
            script = Path(directory) / "check.gd"
            script.write_text('extends SceneTree\nfunc _initialize() -> void:\n\tcall_deferred("_check")\nfunc _check() -> void:\n\tawait process_frame\n\tawait process_frame\n\tvar profile := root.get_node("BenchmarkProfile")\n\tvar game := root.get_node("GameManager")\n\tif not profile.valid or profile.player_limit != 20 or not profile.headless_client or game._is_headless_environment():\n\t\tprinterr("LOAD20_HEADLESS_FIXTURE_FAIL role")\n\t\tquit(1)\n\t\treturn\n\tvar main: Node = load("res://scenes/main.tscn").instantiate()\n\troot.add_child(main)\n\tawait process_frame\n\tvar director := main.get_node("MatchDirector")\n\tvar menu := main.get_node_or_null("ConnectionMenu")\n\tif menu == null or director.rules.max_players_per_team != 10 or menu._max_players_per_team() != 10:\n\t\tprinterr("LOAD20_HEADLESS_FIXTURE_FAIL capacity/client UI")\n\t\tquit(1)\n\t\treturn\n\tif Engine.max_fps != 60 or Engine.physics_ticks_per_second != 50 or root.get_node("NetworkTime").tickrate != 60:\n\t\tprinterr("LOAD20_HEADLESS_FIXTURE_FAIL cached timing")\n\t\tquit(1)\n\t\treturn\n\tprint("LOAD20_HEADLESS_FIXTURE_PASS ordinaryclient=true totalcapacity=20 maxteam=10 fps=60 physics=50 native=60")\n\tquit(0)\n')
            result = subprocess.run([str(godot), "--headless", "--path", str(repo), "--script", str(script)],
                                    env=env, capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("LOAD20_HEADLESS_FIXTURE_PASS", output)
        self.assertTrue(prs.verified_capacity_readback(output, "client"), output)
        self.assertTrue(prs.verify_profile_readback(prs.profile_readbacks(output), "compare60", "client"), output)
        self.assertNotIn("SCRIPT ERROR", output)
        self.assertNotIn("ERROR:", output)

    def test_complete_real_twenty_proof_requires_one_oid_actual_owners_and_cadence(self):
        capacity = dict(role="server", requested_players=20, max_players_per_team=10,
                        total_capacity=20, runtime_clone=True, authored_max_players_per_team=3)
        row = self.population(); row["workload_started"] = True
        moved = self.population(); moved["workload_started"] = True
        moved["positions"] = {key: [point[0]+2, 0.0, 0.0] for key, point in row["positions"].items()}
        with tempfile.TemporaryDirectory() as directory:
            clients = []
            for i in range(20):
                path = Path(directory) / str(i)
                path.write_text("[PROFILE_CAPACITY] " + json.dumps(dict(capacity, role="client")) +
                    "\n[LIVE-PROBE] OWNER_READY index=%d owner=%d team=%d" % (i, i+2, 1 if i<10 else 2) +
                    "\n[PROFILE_CLIENT_CLOCK] ticks=4560 elapsed_sec=76.000000 achieved_hz=60.000")
                clients.append(SimpleNamespace(index=i, log_path=path, parser=SimpleNamespace(admitted_oid="test-room")))
            text = "[PROFILE_CAPACITY] " + json.dumps(capacity) + "\n" + "\n".join(
                "[PERF] owner_population=" + json.dumps(pop) + " native_achieved_hz=60.000" for pop in [row, moved])
            self.assertTrue(prs.load20_proof(clients, text, "compare60")["ok"])
            clients[19].parser.admitted_oid = "different-room"
            self.assertFalse(prs.load20_proof(clients, text, "compare60")["ok"])
            clients[19].parser.admitted_oid = "test-room"
            self.assertFalse(prs.load20_proof(clients, text.replace("native_achieved_hz=60.000", "native_achieved_hz=45.000"), "compare60")["ok"])
            self.assertFalse(prs.load20_proof(clients[:19], text, "compare60")["ok"])
            self.assertFalse(prs.load20_proof(clients, text, "compare30")["ok"])

    def test_memory_guard_fails_closed_and_marks_units(self):
        self.assertEqual(prs.parse_memory_free_percent("System-wide memory free percentage: 31%"), 31)
        prs.guard_load20(15, 8*1024*1024)
        for free, rss in [(14, 0), (50, 8*1024*1024+1)]:
            with self.assertRaises(RuntimeError): prs.guard_load20(free, rss)
        with self.assertRaises(RuntimeError): prs.parse_memory_free_percent("unavailable")

if __name__ == "__main__":
    unittest.main()
