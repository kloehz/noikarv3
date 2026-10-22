#!/usr/bin/env python3
"""Exercise real startup policy and engine contracts without live services."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get("GODOT_BIN", "/Applications/Godot.app/Contents/MacOS/Godot")
TEMP_ROOT = "/private/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/opencode"


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tests" / (name + ".py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HEADLESS = module("verify_headless_server")


class EngineContractTests(unittest.TestCase):
    def run_bootstrap_probe(self, *arguments, test_env=""):
        # Only the external startup boundaries are replaced. _ready and its
        # argument policy execute from the actual production source, unchanged.
        with tempfile.TemporaryDirectory(prefix="noikar-bootstrap-", dir=TEMP_ROOT) as tmp:
            path = Path(tmp)
            shutil.copy2(ROOT / "common/game_manager.gd", path / "game_manager.gd")
            (path / "project.godot").write_text(
                'config_version=5\n[application]\nconfig/name="Bootstrap fixture"\nrun/main_scene="res://probe.tscn"\n'
                '[autoload]\n' + "".join(
                    f'{name}="*res://boundary.gd"\n'
                    for name in ["BenchmarkProfile", "Noray", "AuthService", "PacketHandshake", "EventBus"]
                )
            )
            (path / "boundary.gd").write_text('''extends Node
signal on_connect_nat(address, port)
signal on_connect_relay(address, port)
signal on_oid
signal on_pid
signal server_started
signal client_ready
var valid := true
var selected_profile := ""
var headless_client := false
var remote_transport := false
var player_limit := 0
var oid := ""
var pid := ""
var local_port := 0
func before_network_start(_server: bool) -> bool:
    return true
func connect_to_host(_host: String, _port: int = 0) -> int:
    push_error("Unexpected external startup")
    return ERR_UNAVAILABLE
func validate_room_creator_ticket(_ticket, _instance, _credential) -> Dictionary:
    push_error("Unexpected external authentication")
    return {}
func register_server(_token) -> void:
    pass
func register_host() -> void:
    pass
func register_remote(_a = 0, _b = 0, _c = 0.0, _d = 0) -> int:
    return ERR_UNAVAILABLE
func server_ready() -> void:
    pass
func over_enet_peer(_peer, _address, _port) -> void:
    pass
''')
            (path / "probe.tscn").write_text(
                '[gd_scene load_steps=2 format=3]\n'
                '[ext_resource type="Script" path="res://probe.gd" id="1"]\n'
                '[node name="Probe" type="Node"]\nscript = ExtResource("1")\n'
            )
            (path / "probe.gd").write_text('''extends Node
class Probe:
    extends "res://game_manager.gd"
    var server_starts := 0
    var client_starts := 0
    func _start_as_server() -> void:
        server_starts += 1
    func _start_as_client() -> void:
        client_starts += 1
func _ready() -> void:
    call_deferred("run")
func run() -> void:
    var probe = Probe.new()
    probe._ready()
    var script = load("res://game_manager.gd")
    var has_policy := false
    for method in script.get_script_method_list():
        if method.name == "bootstrap_mode_for":
            has_policy = true
    var release_policy := -1
    if has_policy:
        release_policy = int(script.call("bootstrap_mode_for", ["--noikar-test-mode"], false))
    print("BOOTSTRAP_RESULT ", JSON.stringify({"server_starts": probe.server_starts,
        "client_starts": probe.client_starts, "release_policy": release_policy,
        "has_peer": multiplayer.has_multiplayer_peer(),
        "engine": Engine.get_version_info().string}))
    probe.free()
    get_tree().quit()
''')
            imported = subprocess.run(
                [GODOT, "--headless", "--editor", "--path", str(path), "--quit"],
                capture_output=True, text=True, timeout=15,
            )
            self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)
            result = subprocess.run(
                [GODOT, "--headless", "--quit-after", "30", "--path", str(path), "--", *arguments],
                capture_output=True, text=True, timeout=15,
                env={**os.environ, "NOIKAR_NETFOX_PROFILE": "", "NOIKAR_SERVER_MAX_FPS": "", "NOIKAR_TEST_MODE": test_env},
            )
            text = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, text)
            self.assertNotIn("SCRIPT ERROR", text, text)
            self.assertNotIn("ERROR:", text, text)
            lines = [line for line in text.splitlines() if line.startswith("BOOTSTRAP_RESULT ")]
            self.assertEqual(len(lines), 1, text)
            return json.loads(lines[0].split(" ", 1)[1])

    def test_exact_engine_and_template_version(self):
        result = subprocess.run([GODOT, "--version"], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.stdout.strip(), "4.8.beta1.official.4d10419ca")
        self.assertEqual(HEADLESS.check_environment(ROOT), [])
        templates = Path.home() / "Library/Application Support/Godot/export_templates/4.8.beta1"
        for name in ["windows_debug_x86_64.exe", "macos.zip"]:
            self.assertTrue((templates / name).is_file(), name)

    def test_tests_do_not_start_noray_or_http(self):
        data = self.run_bootstrap_probe("--noikar-test-mode")
        self.assertEqual((data["server_starts"], data["client_starts"]), (0, 0))

    def test_test_mode_is_not_a_production_admission_bypass(self):
        data = self.run_bootstrap_probe("--noikar-test-mode")
        self.assertEqual(data["release_policy"], 2)

    def test_normal_bootstrap_is_not_disabled_by_default(self):
        data = self.run_bootstrap_probe()
        self.assertEqual((data["server_starts"], data["client_starts"]), (1, 0))

    def test_launcher_isolates_both_full_and_focused_gut_children(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as tmp:
            binary = Path(tmp) / "godot-boundary"
            binary.write_text('#!/bin/sh\nprintf "MODE=%s\\n" "$NOIKAR_TEST_MODE"\n')
            binary.chmod(0o700)
            env = {**os.environ, "GODOT_BIN": str(binary)}
            env.pop("NOIKAR_TEST_MODE", None)
            for args in [["tests"], ["test", "game_manager"]]:
                result = subprocess.run(["bash", str(ROOT / "play.sh"), *args], env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.splitlines()[-1], "MODE=1")

    def test_gut_can_request_isolation_without_an_unknown_cli_option(self):
        data = self.run_bootstrap_probe(test_env="1")
        self.assertEqual((data["server_starts"], data["client_starts"]), (0, 0))

    def test_vendor_obj_does_not_reference_absent_material_libraries(self):
        missing = []
        for path in (ROOT / "assets").rglob("*.obj"):
            for line in path.read_text().splitlines():
                if line.startswith("mtllib ") and not (path.parent / line.removeprefix("mtllib ").strip()).is_file():
                    missing.append(str(path.relative_to(ROOT)))
        self.assertEqual(missing, [])

if __name__ == "__main__":
    unittest.main()
