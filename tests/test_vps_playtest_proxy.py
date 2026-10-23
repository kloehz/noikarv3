"""Test the isolated VPS room boundary; no live accounts or VPS access."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools/vps_playtest_proxy.py"
ROOM = {"room_id": "bcb9b91b-f418-4c27-a4bb-5b83a595c599", "room_credential": "c" * 43,
        "host_identity": {"account_id": "2caf37c4-e0ae-419a-9f5e-687e30ae9a72", "username": "Tester"}}


class VpsPlaytestProxyTests(unittest.TestCase):
    def setUp(self):
        self.module = None
        if SOURCE.is_file():
            spec = importlib.util.spec_from_file_location("vps_playtest_proxy", SOURCE)
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)

    def require_module(self):
        self.assertIsNotNone(self.module, "Isolated scoped-room proxy is missing")
        return self.module

    def test_room_uses_scoped_bootstrap_and_never_inherits_account_or_backend_secrets(self):
        module = self.require_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            world = root / "world"
            world.write_text('#!/usr/bin/env python3\nimport json,os,time\nfrom pathlib import Path\nPath("captured.json").write_text(json.dumps(dict(os.environ)))\nprint("VPS_PLAYTEST_READY",flush=True)\ntime.sleep(30)\n')
            world.chmod(0o700)
            runner = module.RoomProcess(world, root, 24580, "http://127.0.0.1:18493")
            try:
                with patch.dict(os.environ, {"JWT_SECRET": "backend-secret", "ACCOUNT_BEARER": "account-secret"}):
                    self.assertTrue(runner.start(ROOM))
                env = json.loads((root / "captured.json").read_text())
                self.assertNotIn("JWT_SECRET", env)
                self.assertNotIn("ACCOUNT_BEARER", env)
                bootstrap = json.loads(env["NOIKAR_VPS_PLAYTEST_BOOTSTRAP"])
                self.assertEqual(bootstrap["room_id"], ROOM["room_id"])
                self.assertEqual(bootstrap["room_credential"], ROOM["room_credential"])
                self.assertEqual(bootstrap["host_identity"], ROOM["host_identity"])
                self.assertFalse(runner.start(ROOM), "A running room must not be replaced")
                self.assertFalse(runner.stop("different-room", "c" * 43))
                self.assertFalse(runner.stop(ROOM["room_id"], "wrong"))
                self.assertTrue(runner.stop(ROOM["room_id"], ROOM["room_credential"]))
                self.assertFalse(runner.is_running())
            finally:
                runner.shutdown()

    def test_invalid_or_credential_smuggling_bootstrap_never_spawns_a_process(self):
        module = self.require_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as tmp:
            runner = module.RoomProcess(Path("/bin/false"), Path(tmp), 24580, "http://127.0.0.1:18493")
            for room in [{}, {**ROOM, "room_id": "../other"}, {**ROOM, "host_identity": {**ROOM["host_identity"], "access_token": "must-not-forward"}}]:
                self.assertFalse(runner.start(room))
                self.assertFalse(runner.is_running())

    def test_failed_world_start_is_not_reported_ready(self):
        module = self.require_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as tmp:
            runner = module.RoomProcess(Path("/bin/false"), Path(tmp), 24580, "http://127.0.0.1:18493")
            self.assertFalse(runner.start(ROOM))
            self.assertFalse(runner.is_running())

    def test_failed_provisioning_closes_the_captured_backend_room(self):
        module = self.require_module()
        if module is None:
            return
        with tempfile.TemporaryDirectory() as tmp:
            runner = module.RoomProcess(Path("/bin/false"), Path(tmp), 24580, "http://127.0.0.1:18493")
            proxy = module.Proxy(runner, 18493)
            calls = []

            def backend(method, path, data, headers):
                calls.append((method, path, headers))
                return (201, json.dumps(ROOM).encode()) if path == "/api/v1/listen-rooms" else (204, b"")

            proxy.forward = backend
            status, body = proxy.request("POST", "/api/v1/listen-rooms", b'{"session_id":"fixture"}', {"Authorization": "Bearer account-secret"})
            self.assertEqual(status, 503)
            self.assertNotIn(b"account-secret", body)
            self.assertEqual(calls[1][1], "/api/v1/listen-rooms/%s/close" % ROOM["room_id"])
            self.assertEqual(calls[1][2]["X-Room-Credential"], ROOM["room_credential"])
            self.assertNotIn("Authorization", calls[1][2])


if __name__ == "__main__":
    unittest.main()
