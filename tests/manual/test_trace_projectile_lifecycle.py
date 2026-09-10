import importlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import profile_room_scaling as prs

tpl = importlib.import_module("trace_projectile_lifecycle")


class TraceProjectileLifecycleTests(unittest.TestCase):
    def test_wrapper_preserves_argv_and_inserts_script_before_separator_for_server(
        self,
    ):
        with tempfile.TemporaryDirectory() as temp_s:
            temp = Path(temp_s)
            capture = temp / "argv.json"
            real = temp / "real_godot.py"
            real.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                f"open({str(capture)!r}, 'w').write(json.dumps(sys.argv))\n",
                encoding="utf-8",
            )
            real.chmod(0o700)
            wrapper = tpl.create_godot_wrapper(temp, real)
            subprocess.run(
                [
                    str(wrapper),
                    "--headless",
                    "--path",
                    "/repo",
                    "--",
                    "--server",
                    "room",
                ],
                check=True,
            )
            argv = json.loads(capture.read_text(encoding="utf-8"))
            self.assertEqual(argv[0], str(real))
            self.assertEqual(argv[1:4], ["--headless", "--path", "/repo"])
            self.assertEqual(argv[4:6], ["--script", tpl.TRACE_SCRIPT])
            self.assertEqual(argv[6:], ["--", "--server", "room"])

    def test_wrapper_does_not_substitute_non_server_launches(self):
        with tempfile.TemporaryDirectory() as temp_s:
            temp = Path(temp_s)
            capture = temp / "argv.json"
            real = temp / "real_godot.py"
            real.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                f"open({str(capture)!r}, 'w').write(json.dumps(sys.argv))\n",
                encoding="utf-8",
            )
            real.chmod(0o700)
            wrapper = tpl.create_godot_wrapper(temp, real)
            subprocess.run(
                [str(wrapper), "--path", "/repo", "--script", "client.gd"], check=True
            )
            argv = json.loads(capture.read_text(encoding="utf-8"))
            self.assertEqual(argv[1:], ["--path", "/repo", "--script", "client.gd"])
            self.assertNotIn(tpl.TRACE_SCRIPT, argv)

    def test_trace_parser_caps_and_sanitizes_allowlisted_fields(self):
        with tempfile.TemporaryDirectory() as temp_s:
            log = Path(temp_s) / "noray.log"
            lines = []
            for i in range(3):
                lines.append(
                    tpl.TRACE_PREFIX
                    + json.dumps(
                        {
                            "stage": "after_process_tick",
                            "tick": i,
                            "player": "2",
                            "argv": ["secret"],
                            "env": {"TOKEN": "secret"},
                        }
                    )
                )
            lines.append(tpl.TRACE_PREFIX + "not-json")
            log.write_text("\n".join(lines), encoding="utf-8")
            parsed = tpl.parse_trace_log(log, cap=2)
            self.assertEqual(parsed["total"], 3)
            self.assertTrue(parsed["capped"])
            self.assertEqual(parsed["malformed"], 1)
            self.assertEqual(len(parsed["records"]), 2)
            self.assertNotIn("argv", parsed["records"][0])
            self.assertNotIn("env", parsed["records"][0])

    def test_run_trial_restores_patched_profile_functions_after_success(self):
        original_noray_env = prs.noray_env
        original_build_result = prs.build_result
        original_cleanup_run = prs.CleanupPlan.run
        with tempfile.TemporaryDirectory() as temp_s:
            godot = Path(temp_s) / "Godot"
            godot.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            godot.chmod(0o700)
            with mock.patch.object(prs, "run", return_value=0) as run_mock:
                code = tpl.run_trial(["--godot", str(godot)])
        self.assertEqual(code, 0)
        run_mock.assert_called_once()
        self.assertIs(prs.noray_env, original_noray_env)
        self.assertIs(prs.build_result, original_build_result)
        self.assertIs(prs.CleanupPlan.run, original_cleanup_run)

    def test_run_trial_restores_patched_profile_functions_after_failure_exception(self):
        original_noray_env = prs.noray_env
        original_build_result = prs.build_result
        original_cleanup_run = prs.CleanupPlan.run
        with tempfile.TemporaryDirectory() as temp_s:
            godot = Path(temp_s) / "Godot"
            godot.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            godot.chmod(0o700)
            with (
                mock.patch.object(prs, "run", side_effect=RuntimeError("boom")),
                self.assertRaises(RuntimeError),
            ):
                tpl.run_trial(["--godot", str(godot)])
        self.assertIs(prs.noray_env, original_noray_env)
        self.assertIs(prs.build_result, original_build_result)
        self.assertIs(prs.CleanupPlan.run, original_cleanup_run)

    def test_cleanup_hook_collects_trace_before_original_cleanup(self):
        seen = {}

        def fake_run(_argv):
            temp_dir = Path(tempfile.mkdtemp())
            cleanup = prs.CleanupPlan(temp_dir=temp_dir)
            (temp_dir / "noray.log").write_text(
                tpl.TRACE_PREFIX
                + json.dumps({"stage": "server_spawn", "node": "Projectile"}),
                encoding="utf-8",
            )
            cleanup.run()
            return 1

        def fake_cleanup(cleanup):
            assert cleanup.temp_dir is not None
            seen["exists_during_cleanup"] = (cleanup.temp_dir / "noray.log").exists()

        with tempfile.TemporaryDirectory() as temp_s:
            godot = Path(temp_s) / "Godot"
            godot.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            godot.chmod(0o700)
            with (
                mock.patch.object(prs, "run", side_effect=fake_run),
                mock.patch.object(prs.CleanupPlan, "run", fake_cleanup),
                mock.patch("trace_projectile_lifecycle.print") as print_mock,
            ):
                code = tpl.run_trial(["--godot", str(godot)])
        self.assertEqual(code, 1)
        self.assertTrue(seen["exists_during_cleanup"])
        final_payload = json.loads(print_mock.call_args.args[0])
        self.assertEqual(final_payload["diagnostic_projectile_trace_final"]["total"], 1)

    def test_run_stops_on_first_invalid_trial(self):
        with mock.patch.object(tpl, "run_trial", side_effect=[2, 0]) as run_trial:
            self.assertEqual(tpl.run(["--trials", "4", "--rooms", "1"]), 2)
        run_trial.assert_called_once_with(["--rooms", "1"])

    def test_godot_observe_players_deduplicates_per_player_and_stage(self):
        godot = Path("/Applications/Godot.app/Contents/MacOS/Godot")
        if not godot.exists():
            self.skipTest(f"Godot executable not found: {godot}")
        repo = Path(__file__).resolve().parents[2]
        with tempfile.NamedTemporaryFile(
            "w", suffix=".gd", prefix="trace_projectile_dedupe_", delete=False
        ) as script:
            script_path = Path(script.name)
            script.write(
                """extends "res://tests/manual/trace_projectile_server.gd"

class FakeCombat:
\textends Node
\tvar sync_attack_count := 0
\tvar current_attack_state := 0
\tvar _state_timer := 0.0
\tvar is_charging := false
\tvar _active_attack_slot := 0
\tvar _primary := Object.new()

var records := []
var failures := []
var combat: FakeCombat

func _initialize() -> void:
\tcall_deferred("_run")

func _boot() -> void:
\tpass

func _trace(record: Dictionary) -> void:
\trecords.append(record.duplicate(true))

func _expect_count(label: String, expected: int) -> void:
\tif records.size() != expected:
\t\tfailures.append("%s expected %s records, got %s" % [label, expected, records.size()])
\telse:
\t\tprint("TRACE_DEDUPE_%s=%s" % [label, expected])

func _observe_pair(tick: int) -> void:
\t_observe_players("after_prepare_tick", tick)
\t_observe_players("after_process_tick", tick)

func _run() -> void:
\tvar scene := Node.new()
\tscene.name = "TraceScene"
\tvar players := Node.new()
\tplayers.name = "Players"
\tvar player := Node.new()
\tplayer.name = "player"
\tcombat = FakeCombat.new()
\tcombat.name = "CombatComponent"
\tplayer.add_child(combat)
\tplayers.add_child(player)
\tscene.add_child(players)
\troot.add_child(scene)
\tcurrent_scene = scene

\tfor i in range(10):
\t\t_observe_pair(i)
\t_expect_count("INITIAL", 2)

\tcombat._state_timer = 42.0
\t_observe_pair(99)
\t_expect_count("TIMER_ONLY", 2)

\tcombat.sync_attack_count += 1
\t_observe_pair(100)
\t_expect_count("ATTACK_COUNT", 4)

\tcombat._active_attack_slot = 1
\tcombat.current_attack_state = 2
\t_observe_pair(101)
\t_expect_count("SLOT_STATE", 6)

\tcurrent_scene = null
\tscene.queue_free()
\tif failures.is_empty():
\t\tprint("TRACE_DEDUPE_PASS")
\t\tquit(0)
\telse:
\t\tfor failure in failures:
\t\t\tpush_error(failure)
\t\tquit(1)
""",
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
        self.assertEqual(result.returncode, 0, output)
        self.assertIn("TRACE_DEDUPE_INITIAL=2", output)
        self.assertIn("TRACE_DEDUPE_TIMER_ONLY=2", output)
        self.assertIn("TRACE_DEDUPE_ATTACK_COUNT=4", output)
        self.assertIn("TRACE_DEDUPE_SLOT_STATE=6", output)
        self.assertIn("TRACE_DEDUPE_PASS", output)


if __name__ == "__main__":
    unittest.main()
