"""Fault injection around real room ownership; only the upstream HTTP API is fake."""
from email.message import Message
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ROOM_A = {"room_id": "bcb9b91b-f418-4c27-a4bb-5b83a595c599", "room_credential": "a" * 43,
          "host_identity": {"account_id": "2caf37c4-e0ae-419a-9f5e-687e30ae9a72", "username": "A"}}
ROOM_B = {"room_id": "03c68aef-cf79-43bc-b345-139905c1c3ef", "room_credential": "b" * 43,
          "host_identity": {"account_id": "101122de-a6d2-432c-b862-4be67191b33f", "username": "B"}}


class VpsResponseCleanupTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("vps_response_proxy", ROOT / "tools/vps_playtest_proxy.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        world = root / "world"
        world.write_text('#!/usr/bin/env python3\nimport time\nprint("VPS_PLAYTEST_READY",flush=True)\ntime.sleep(30)\n')
        world.chmod(0o700)
        self.runner = self.module.RoomProcess(world, root, 24580, "http://127.0.0.1:18493")
        self.proxy = self.module.Proxy(self.runner, 18493)
        self.closed = []

        def backend(_method, path, _body, _headers):
            if path == "/api/v1/listen-rooms":
                return 201, json.dumps(ROOM_A).encode()
            self.closed.append(path)
            return 204, b""
        self.proxy.forward = backend

    def tearDown(self):
        self.runner.shutdown()
        self.tmp.cleanup()

    def handler(self):
        handler = object.__new__(self.module.handler_for(self.proxy))
        handler.path = "/api/v1/listen-rooms"
        handler.command = "POST"
        handler.headers = Message()
        handler.headers["Content-Length"] = "2"
        handler.rfile = io.BytesIO(b"{}")
        handler.wfile = io.BytesIO()
        handler.send_response = lambda *_args: None
        handler.send_header = lambda *_args: None
        handler.end_headers = lambda: None
        return handler

    def test_disconnected_response_headers_retire_only_the_created_room(self):
        handler = self.handler()

        def broken_headers():
            raise BrokenPipeError()
        handler.end_headers = broken_headers
        try:
            handler.handle_api()
        except BrokenPipeError:
            pass
        self.assertFalse(self.runner.is_running(), "Header failure must release the only world slot")
        self.assertEqual(self.closed, ["/api/v1/listen-rooms/%s/close" % ROOM_A["room_id"]])

    def test_stale_response_failure_cannot_close_or_kill_a_newer_room(self):
        handler = self.handler()
        runner = self.runner

        class DelayedWriter:
            def write(self, _body):
                runner.stop(ROOM_A["room_id"], ROOM_A["room_credential"])
                if not runner.start(ROOM_B):
                    raise AssertionError("Replacement fixture room failed to start")
                raise BrokenPipeError()
        handler.wfile = DelayedWriter()
        handler.handle_api()
        self.assertTrue(self.runner.is_running(), "A's failed response must leave B running")
        self.assertEqual(self.runner.room["room_id"], ROOM_B["room_id"])
        self.assertEqual(self.closed, ["/api/v1/listen-rooms/%s/close" % ROOM_A["room_id"]])

    def test_unclaimed_world_releases_slot_within_thirty_seconds(self):
        self.assertTrue(hasattr(self.proxy, "reap_once"), "An unclaimed room needs a bounded admission lease")
        if not hasattr(self.proxy, "reap_once"):
            return
        self.assertTrue(self.runner.start(ROOM_A))
        self.proxy.reap_once(self.runner.started + 31)
        self.assertFalse(self.runner.is_running())
        self.assertEqual(self.closed, ["/api/v1/listen-rooms/%s/close" % ROOM_A["room_id"]])

    def test_admitted_room_is_not_killed_by_the_initial_admission_lease(self):
        self.assertTrue(hasattr(self.proxy, "reap_once"))
        if not hasattr(self.proxy, "reap_once"):
            return
        self.assertTrue(self.runner.start(ROOM_A))
        with (self.runner.directory / "world.log").open("a") as log:
            log.write("VPS_PLAYTEST_ADMITTED\n")
        self.proxy.reap_once(self.runner.started + 31)
        self.assertTrue(self.runner.is_running())
        self.assertEqual(self.closed, [])


if __name__ == "__main__":
    unittest.main()
