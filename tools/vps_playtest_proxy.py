#!/usr/bin/env python3
"""Loopback-only scoped-room proxy for the explicitly isolated F5 VPS test."""
import argparse
import hmac
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time
from urllib.parse import urlsplit
import uuid


class RoomProcess:
    def __init__(self, executable: Path, directory: Path, port: int, api_url: str):
        if port != 24580 or not re.fullmatch(r"http://127\.0\.0\.1:[0-9]+", api_url):
            raise ValueError("Only the isolated fixed game port and loopback API are allowed")
        self.executable, self.directory, self.port, self.api_url = executable, directory, port, api_url
        self.lock = threading.RLock()
        self.process = None
        self.room = {}
        self.started = 0.0

    def is_running(self):
        return self.process is not None and self.process.poll() is None

    def start(self, room):
        with self.lock:
            if self.is_running():
                return False
            try:
                if set(room) != {"room_id", "room_credential", "host_identity"} or set(room["host_identity"]) != {"account_id", "username"}:
                    return False
                uuid.UUID(room["room_id"])
                uuid.UUID(room["host_identity"]["account_id"])
                if not isinstance(room["host_identity"]["username"], str) or not room["host_identity"]["username"] or not 32 <= len(room["room_credential"]) <= 128:
                    return False
            except (ValueError, TypeError, KeyError, AttributeError):
                return False
            self.room = dict(room)
            env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(self.directory), "LANG": "C.UTF-8",
                   "NOIKAR_BACKEND_URL": self.api_url, "NOIKAR_ISOLATED_AUTH_API": "1",
                   "NOIKAR_VPS_PLAYTEST_BOOTSTRAP": json.dumps({**room, "port": self.port})}
            log = self.directory / "world.log"
            fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                with os.fdopen(fd, "wb") as output:
                    self.process = subprocess.Popen([str(self.executable), "--headless", "--main-pack", str(self.executable.with_suffix(".pck")), "--", "--server", "--vps-playtest-server"], cwd=self.directory, env=env, stdout=output, stderr=output, start_new_session=True)
            except OSError:
                self.process = None
                return False
            self.started = time.monotonic()
            until = self.started + 8
            while self.is_running() and time.monotonic() < until:
                if "VPS_PLAYTEST_READY" in log.read_text(errors="replace"):
                    return True
                time.sleep(0.02)
            self.shutdown()
            return False

    def stop(self, room_id, credential):
        with self.lock:
            if room_id != self.room.get("room_id") or not hmac.compare_digest(str(credential), self.room.get("room_credential", "")):
                return False
            self.shutdown()
            return True

    def shutdown(self):
        with self.lock:
            if self.is_running():
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=2)
            self.process = None


class Proxy:
    def __init__(self, runner, api_port):
        self.runner, self.api_port = runner, api_port

    def forward(self, method, path, data, headers):
        connection = http.client.HTTPConnection("127.0.0.1", self.api_port, timeout=10)
        try:
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            return response.status, response.read(65537)
        finally:
            connection.close()

    def close_backend_room(self, room):
        if room:
            try:
                self.forward("POST", "/api/v1/listen-rooms/%s/close" % room["room_id"], b"{}", {"Content-Type": "application/json", "X-Room-Credential": room["room_credential"]})
            except (OSError, http.client.HTTPException):
                pass  # Backend expiry is the final bound if unavailable.

    def discard_created_room(self, room):
        # Capture ownership from this response, never from mutable current state.
        with self.runner.lock:
            self.close_backend_room(room)
            self.runner.stop(room["room_id"], room["room_credential"])

    def reap_once(self, now=None):
        now = time.monotonic() if now is None else now
        with self.runner.lock:
            if not self.runner.room:
                return
            log = self.runner.directory / "world.log"
            admitted = log.is_file() and "\nVPS_PLAYTEST_ADMITTED\n" in log.read_text(errors="replace")
            unclaimed = now - self.runner.started > 30 and not admitted
            if not self.runner.is_running() or now - self.runner.started > 7200 or unclaimed:
                room = dict(self.runner.room)
                self.discard_created_room(room)
                self.runner.room = {}

    def request(self, method, path, data, headers):
        if path == "/api/v1/listen-rooms" and method == "POST":
            with self.runner.lock:
                if self.runner.is_running():
                    return 409, b'{"error":"A VPS test room is already active. Leave it before creating another."}'
                status, body = self.forward(method, path, data, headers)
                if status != 201:
                    return status, body
                room = json.loads(body)
                if not self.runner.start(room):
                    self.close_backend_room(room)
                    return 503, b'{"error":"The isolated VPS world did not become ready"}'
                return 201, json.dumps({**room, "game_port": self.runner.port}).encode()
        status, body = self.forward(method, path, data, headers)
        if status == 204 and path == "/api/v1/listen-rooms/%s/close" % self.runner.room.get("room_id"):
            self.runner.stop(self.runner.room["room_id"], headers.get("X-Room-Credential", ""))
        return status, body


def handler_for(proxy):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # Never log request/account/room material.

        def do_GET(self):
            self.handle_api()

        def do_POST(self):
            self.handle_api()

        def handle_api(self):
            allowed = re.fullmatch(r"/api/v1/(health|auth/(register|login|me)|listen-rooms(?:/[0-9a-f-]{36}/(?:tickets|admissions|close))?)", self.path)
            if not allowed or self.headers.get("Transfer-Encoding"):
                self.send_error(404)
                return
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 <= size <= 4096:
                    self.send_error(413)
                    return
                headers = {key: self.headers[key] for key in ["Authorization", "X-Room-Credential", "Content-Type"] if key in self.headers}
                status, body = proxy.request(self.command, self.path, self.rfile.read(size), headers)
            except (ValueError, KeyError, OSError, http.client.HTTPException):
                status, body = 503, b'{"error":"Isolated VPS service unavailable"}'
            created_room = json.loads(body) if self.path == "/api/v1/listen-rooms" and status == 201 else None
            try:
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
            except OSError:
                if created_room is not None:
                    proxy.discard_created_room(created_room)
    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    runner = RoomProcess(root / "world/noikar-f5-server.x86_64", root / "runtime", 24580, "http://127.0.0.1:18493")
    proxy = Proxy(runner, 18493)
    server = ThreadingHTTPServer(("127.0.0.1", 18491), handler_for(proxy))
    server.daemon_threads = True

    def reap():
        while True:
            time.sleep(1)
            proxy.reap_once()
    threading.Thread(target=reap, daemon=True).start()
    try:
        server.serve_forever()
    finally:
        runner.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
