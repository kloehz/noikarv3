#!/usr/bin/env python3
"""Local 1-3 room profiling supervisor for noikar.

This script intentionally uses only Python's standard library and only loopback
networking. It owns the exact local processes, Docker container/volume, and temp
artifacts it creates, then tears them down in one finally block.
"""

from __future__ import annotations

import argparse
import ast
import json
import math
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterable, Sequence
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO

OWNED_PORTS = [15432, 18090, 8890, 8891, 8809]
RELAY_RANGE = range(20000, 20101)
FORBIDDEN_PORTS = {8080, 8090}
FORBIDDEN_PID = 95146
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}
BENCHMARK_SCENARIOS = {
    "A": {"players": 0, "mobs": 0, "connected": False},
    "B": {"players": 0, "mobs": 20, "connected": False},
    "C": {"players": 0, "mobs": 20, "connected": False},
    "D": {"players": 1, "mobs": 0, "connected": True},
    "E": {"players": 1, "mobs": 20, "connected": True},
    "F": {"players": 1, "mobs": 20, "connected": True},
}
SERVER_READY_RE = re.compile(r"players\s*=\s*1\s+entities\s*=\s*21")
POPULATION_READY_RE = re.compile(
    r"\[PROFILE_POPULATION_READY\]\s+mode=fixed_population\s+expectedcount=(?P<expected>\d+)\s+actualcount=(?P<actual>\d+)\s+seed=120120"
)
POPULATION_FAILED_RE = re.compile(
    r"\[PROFILE_POPULATION_FAILED\]\s+mode=fixed_population\s+expectedcount=(?P<expected>\d+)\s+actualcount=(?P<actual>\d+)\s+seed=(?P<seed>\d+)"
)
PASS_RE = re.compile(r"\[LIVE-PROBE\]\s+PASS\b")
FIXED_WORKLOAD_END_RE = re.compile(r"\[LIVE-PROBE\]\s+FIXED_WORKLOAD_END\b")
SPAWN_READY_RE = re.compile(
    r"\[LIVE-PROBE\]\s+spawned\s+player=.+\s+mobs=(?P<mobs>\d+)\b"
)
HUMAN_READY_RE = re.compile(r"\[LIVE-PROBE\]\s+HUMAN_READY\b")
METRICS_RE = re.compile(
    r"movement=(?P<movement>[0-9.]+)m\s+mob_displacement=(?P<mob>[0-9.]+)m\s+"
    r"max_projectiles=(?P<projectiles>\d+)\s+attacks=(?P<attacks0>-?\d+)->(?P<attacks1>-?\d+)\s+dead=(?P<dead>\w+)"
)
WORKLOAD_DISTANCE_RE = re.compile(
    r"nearest_npc_m=(?P<nearest_min>[0-9.]+|null)/(?P<nearest_mean>[0-9.]+|null)/(?P<nearest_max>[0-9.]+|null)\s+"
    r"observed_npcs_90m=(?P<within_min>\d+)/(?P<within_max>\d+)\s+"
    r"alive_npcs=(?P<alive>\d+)\s+player_sample_travel=(?P<travel>[0-9.]+)m\s+"
    r"endpoint=(?P<endpoint>[0-9.]+)m\s+invalid=(?P<invalid>\w+)"
)
ERROR_RE = re.compile(r"(sync|rpc|error|exception|fail)", re.IGNORECASE)
TELEMETRY_RE = re.compile(
    r"\[LIVE-PROBE\]\s+telemetry\s+npc_stride_counts=(?P<strides>\{[^}]*\})\s+"
    r"interpolator_buffer_counts=(?P<buffers>\{[^}]*\})"
)
NPC_COST_KEY_RE = re.compile(
    r"(?P<name>npc_(?:ai_inclusive|movement|combat))_(?P<field>total_usec|calls|max_usec)=(?P<value>\d+)"
)
NPC_COUNTER_KEY_RE = re.compile(
    r"(?P<name>npc_(?:target_scan|avoidance)_visits)=(?P<value>\d+)"
)


@dataclass(frozen=True)
class Account:
    username: str
    password: str


@dataclass(frozen=True)
class DockerSpec:
    image: str
    command: list[str]


@dataclass(frozen=True)
class ProcessRow:
    pid: int
    ppid: int
    command: str
    rss_kb: int = 0


@dataclass(frozen=True)
class ProfileWindow:
    requested_warmup_seconds: float = 0.0
    requested_sample_seconds: float = 0.0
    stable_started: float | None = None
    run_started: float | None = None
    active_end_rows_discarded: int = 0

    @property
    def long_mode(self) -> bool:
        return (
            self.requested_warmup_seconds > 0.0 or self.requested_sample_seconds > 0.0
        )


@dataclass(frozen=True)
class StableGate:
    exact_server_count: bool
    clients_ready: bool
    sampling_ok: bool
    stable_wall_seconds: float
    pinned_pids: set[int]
    no_early_client_exit: bool = True
    population_marker_verified: bool = True

    @property
    def ok(self) -> bool:
        return (
            self.exact_server_count
            and self.clients_ready
            and self.sampling_ok
            and self.stable_wall_seconds >= 8.0
            and self.no_early_client_exit
            and self.population_marker_verified
        )


@dataclass
class StopRequest:
    requested: bool = False
    signum: int | None = None

    def request(self, signum: int) -> None:
        self.requested = True
        self.signum = signum


@contextmanager
def install_stop_handlers(stop: StopRequest):
    previous_int = signal.getsignal(signal.SIGINT)
    previous_term = signal.getsignal(signal.SIGTERM)

    def _handler(signum, _frame):
        stop.request(int(signum))

    signal.signal(signal.SIGINT, _handler)
    signal.signal(signal.SIGTERM, _handler)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)


@dataclass
class ClientProcess:
    index: int
    account: Account
    process: subprocess.Popen
    log_path: Path
    start_monotonic: float = field(default_factory=time.monotonic)
    end_monotonic: float | None = None
    parser: ClientLogParser = field(default_factory=lambda: ClientLogParser())


@dataclass
class CleanupPlan:
    processes: list[subprocess.Popen] = field(default_factory=list)
    server_pids: set[int] = field(default_factory=set)
    container: str | None = None
    volume: str | None = None
    temp_dir: Path | None = None
    log_files: list[BinaryIO] = field(default_factory=list)
    keep_artifacts: bool = False

    def terminate_process_groups(self) -> None:
        for proc in reversed(self.processes):
            if proc.poll() is not None:
                continue
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except ProcessLookupError:
                continue
            except Exception as exc:
                print(
                    f"cleanup: could not terminate pgid for pid {proc.pid}: {exc}",
                    file=sys.stderr,
                )
        deadline = time.monotonic() + 8
        for proc in reversed(self.processes):
            while proc.poll() is None and time.monotonic() < deadline:
                time.sleep(0.1)
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except Exception as exc:
                    print(
                        f"cleanup: could not kill pgid for pid {proc.pid}: {exc}",
                        file=sys.stderr,
                    )

    def terminate_server_pids(self) -> None:
        for pid in sorted(self.server_pids):
            if pid == FORBIDDEN_PID:
                continue
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            except Exception as exc:
                print(
                    f"cleanup: could not terminate server pid {pid}: {exc}",
                    file=sys.stderr,
                )

    def cleanup_docker(self) -> None:
        if self.container:
            subprocess.run(
                ["docker", "rm", "-f", self.container],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        if self.volume:
            subprocess.run(
                ["docker", "volume", "rm", "-f", self.volume],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    def cleanup_temp(self) -> None:
        for handle in self.log_files:
            try:
                handle.close()
            except Exception as exc:
                print(f"cleanup: could not close log file: {exc}", file=sys.stderr)
        if self.temp_dir and not self.keep_artifacts:
            shutil.rmtree(self.temp_dir, ignore_errors=True)

    def run(self) -> None:
        self.terminate_process_groups()
        self.terminate_server_pids()
        self.cleanup_docker()
        self.cleanup_temp()


class ServerLogParser:
    def __init__(self, expected_mob_count: int | None = None) -> None:
        self.expected_mob_count = expected_mob_count
        self.ready = False
        self.population_ready = expected_mob_count is None
        self.population_failed = False
        self.population_marker: dict[str, object] = {
            "expected": None,
            "actual": None,
            "seed": None,
            "failed": False,
            "verified": expected_mob_count is None,
        }
        self.errors: list[str] = []
        self.perf_lines: list[str] = []

    def feed(self, text: str) -> None:
        for line in text.splitlines():
            if SERVER_READY_RE.search(line):
                self.ready = True
            marker = POPULATION_READY_RE.search(line)
            if marker:
                expected = int(marker.group("expected"))
                actual = int(marker.group("actual"))
                verified = (
                    self.expected_mob_count is not None
                    and expected == self.expected_mob_count
                    and actual == self.expected_mob_count
                )
                self.population_marker = {
                    "expected": expected,
                    "actual": actual,
                    "seed": 120120,
                    "failed": False,
                    "verified": verified,
                }
                if verified:
                    self.population_ready = True
            failed_marker = POPULATION_FAILED_RE.search(line)
            if failed_marker:
                self.population_failed = True
                self.population_ready = False
                self.population_marker = {
                    "expected": int(failed_marker.group("expected")),
                    "actual": int(failed_marker.group("actual")),
                    "seed": int(failed_marker.group("seed")),
                    "failed": True,
                    "verified": False,
                }
            if ERROR_RE.search(line):
                self.errors.append(line)
            if "PerfProbe" in line or "perf" in line.lower():
                self.perf_lines.append(line)


class ClientLogParser:
    def __init__(self, expected_mob_count: int | None = None) -> None:
        self.expected_mob_count = expected_mob_count
        self.ready = False
        self.passed = False
        self.metrics: dict[str, object] = {}
        self.telemetry: dict[str, dict[str, int]] = {}
        self.human_ready = False
        self.fixed_workload_ended = False
        self.errors: list[str] = []

    def feed(self, text: str) -> None:
        for line in text.splitlines():
            spawn = SPAWN_READY_RE.search(line)
            if spawn:
                mobs = int(spawn.group("mobs"))
                expected = (
                    20 if self.expected_mob_count is None else self.expected_mob_count
                )
                if mobs == expected:
                    self.ready = True
            if HUMAN_READY_RE.search(line):
                self.ready = True
                self.human_ready = True
            if FIXED_WORKLOAD_END_RE.search(line):
                self.fixed_workload_ended = True
            if PASS_RE.search(line):
                self.passed = True
            metric = METRICS_RE.search(line)
            if metric:
                self.metrics = {
                    "movement": float(metric.group("movement")),
                    "mob_displacement": float(metric.group("mob")),
                    "max_projectiles": int(metric.group("projectiles")),
                    "attacks_start": int(metric.group("attacks0")),
                    "attacks_end": int(metric.group("attacks1")),
                    "dead": metric.group("dead").lower() == "true",
                }
                mob_match = re.search(r"mobs=(\d+)->(\d+)", line)
                if mob_match:
                    self.metrics["mobs_start"] = int(mob_match.group(1))
                    self.metrics["mobs_end"] = int(mob_match.group(2))
                workload_match = re.search(r"workload=([a-z_]+)", line)
                if workload_match:
                    self.metrics["workload"] = workload_match.group(1)
                sample_match = re.search(r"sample=([0-9.]+)s", line)
                if sample_match:
                    self.metrics["actual_sample_seconds"] = float(sample_match.group(1))
                workload_distance = WORKLOAD_DISTANCE_RE.search(line)
                if workload_distance:
                    self.metrics["nearest_npc_distance"] = {
                        "min": _parse_nullable_float(
                            workload_distance.group("nearest_min")
                        ),
                        "mean": _parse_nullable_float(
                            workload_distance.group("nearest_mean")
                        ),
                        "max": _parse_nullable_float(
                            workload_distance.group("nearest_max")
                        ),
                    }
                    self.metrics["observed_npcs_within_90m"] = {
                        "min": int(workload_distance.group("within_min")),
                        "max": int(workload_distance.group("within_max")),
                    }
                    self.metrics["alive_npcs"] = int(workload_distance.group("alive"))
                    self.metrics["player_sample_travel"] = float(
                        workload_distance.group("travel")
                    )
                    self.metrics["player_sample_endpoint"] = float(
                        workload_distance.group("endpoint")
                    )
                    self.metrics["workload_invalid"] = (
                        workload_distance.group("invalid").lower() == "true"
                    )
            telemetry = TELEMETRY_RE.search(line)
            if telemetry is None and HUMAN_READY_RE.search(line):
                telemetry = re.search(
                    r"npc_stride_counts=(?P<strides>\{[^}]*\})\s+interpolator_buffer_counts=(?P<buffers>\{[^}]*\})",
                    line,
                )
            if telemetry:
                self.telemetry = {
                    "npc_stride_counts": _parse_int_dict(telemetry.group("strides")),
                    "interpolator_buffer_counts": _parse_int_dict(
                        telemetry.group("buffers")
                    ),
                }
            if ERROR_RE.search(line):
                self.errors.append(line)


class CombinedLogParser:
    def __init__(self) -> None:
        self.perf_lines: list[str] = []
        self.npc_cost_intervals: list[dict[str, object]] = []
        self.errors: list[str] = []

    def feed(self, text: str) -> None:
        for line in text.splitlines():
            if (
                "PerfProbe" in line or "perf" in line.lower()
            ) and line not in self.perf_lines:
                self.perf_lines.append(line)
                cost = parse_npc_cost_interval(line)
                if cost and len(self.npc_cost_intervals) < 40:
                    self.npc_cost_intervals.append(cost)
            if ERROR_RE.search(line):
                self.errors.append(line)


def _parse_nullable_float(text: str) -> float | None:
    return None if text == "null" else float(text)


def _parse_int_dict(text: str) -> dict[str, int]:
    try:
        raw = ast.literal_eval(text)
    except (SyntaxError, ValueError):
        return {}
    if not isinstance(raw, dict):
        return {}
    parsed: dict[str, int] = {}
    for key, value in raw.items():
        try:
            parsed[str(key)] = int(value)
        except (TypeError, ValueError):
            continue
    return parsed


def parse_npc_cost_interval(line: str) -> dict[str, object]:
    interval: dict[str, object] = {}
    for match in NPC_COST_KEY_RE.finditer(line):
        bucket = interval.setdefault(match.group("name"), {})
        if isinstance(bucket, dict):
            bucket[match.group("field")] = int(match.group("value"))
    for match in NPC_COUNTER_KEY_RE.finditer(line):
        interval[match.group("name")] = int(match.group("value"))
    return interval


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[2]


def require_loopback_host(value: str, label: str) -> str:
    host = value.strip().strip("[]")
    if host not in LOOPBACK_HOSTS:
        try:
            infos = socket.getaddrinfo(host, None)
        except socket.gaierror as exc:
            raise ValueError(
                f"{label} must resolve to loopback; got {value!r}: {exc}"
            ) from exc
        if not infos or any(
            not ipaddress_is_loopback(str(info[4][0])) for info in infos
        ):
            raise ValueError(f"{label} must be loopback-only; got {value!r}")
    return value


def ipaddress_is_loopback(addr: str) -> bool:
    return addr.startswith("127.") or addr == "::1"


def require_loopback_url(value: str, label: str) -> str:
    parsed = urllib.parse.urlparse(value)
    if (
        parsed.scheme not in {"http", "https", "ws", "wss", "tcp"}
        or not parsed.hostname
    ):
        raise ValueError(f"{label} must be a URL with a host; got {value!r}")
    require_loopback_host(parsed.hostname, label)
    if parsed.port in FORBIDDEN_PORTS:
        raise ValueError(f"{label} uses forbidden port {parsed.port}")
    return value


def parse_ps_time(value: str) -> float:
    original = value
    value = value.strip()
    days = 0
    if "-" in value:
        day_s, value = value.split("-", 1)
        days = int(day_s)
    if ":" not in value:
        seconds = float(value)
        if not math.isfinite(seconds):
            raise ValueError(f"unsupported ps TIME format: {original!r}")
        return seconds
    parts = value.split(":")
    if len(parts) == 2:
        hours, minutes, seconds = 0, int(parts[0]), float(parts[1])
    elif len(parts) == 3:
        hours, minutes, seconds = int(parts[0]), int(parts[1]), float(parts[2])
    else:
        raise ValueError(f"unsupported ps TIME format: {original!r}")
    total = days * 86400 + hours * 3600 + minutes * 60 + seconds
    if not math.isfinite(total):
        raise ValueError(f"unsupported ps TIME format: {original!r}")
    return float(total)


def cpu_percent_delta(
    start_seconds: float, end_seconds: float, wall_seconds: float
) -> float:
    if wall_seconds <= 0:
        return 0.0
    return max(0.0, end_seconds - start_seconds) / wall_seconds * 100.0


def generate_accounts(count: int) -> list[Account]:
    prefix = "prof" + secrets.token_hex(4)
    return [
        Account(f"{prefix}{i}", secrets.token_urlsafe(18)[:24]) for i in range(count)
    ]


def redact(text: str, secrets_to_redact: Iterable[str]) -> str:
    redacted = text
    for secret in secrets_to_redact:
        if secret:
            redacted = redacted.replace(secret, "<redacted>")
    return redacted


def postgres_spec(container: str, volume: str) -> DockerSpec:
    cmd = [
        "docker",
        "run",
        "--name",
        container,
        "-d",
        "--rm",
        "-p",
        "127.0.0.1:15432:5432",
        "-v",
        f"{volume}:/var/lib/postgresql/data",
        "-e",
        "POSTGRES_USER=postgres",
        "-e",
        "POSTGRES_DB=postgres",
        "-e",
        "POSTGRES_HOST_AUTH_METHOD=trust",
        "postgres:16-alpine",
    ]
    return DockerSpec("postgres:16-alpine", cmd)


def port_is_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.2)
        return sock.connect_ex(("127.0.0.1", port)) != 0


def preflight_ports() -> None:
    for port in list(OWNED_PORTS) + list(RELAY_RANGE):
        if port in FORBIDDEN_PORTS:
            raise RuntimeError(f"refusing forbidden port {port}")
        if not port_is_free(port):
            raise RuntimeError(
                f"required owned loopback port {port} is occupied; stop that process before profiling"
            )


def assert_ports_clear() -> dict[int, bool]:
    return {port: port_is_free(port) for port in list(OWNED_PORTS) + list(RELAY_RANGE)}


def enforce_ports_clear(clear: dict[int, bool]) -> None:
    uncleared = [port for port, ok in clear.items() if not ok]
    if uncleared:
        print(f"cleanup: ports still occupied: {uncleared}", file=sys.stderr)
        raise SystemExit(3)


def start_process(
    args: Sequence[str],
    *,
    cwd: Path,
    env: dict[str, str],
    log_path: Path,
    cleanup: CleanupPlan,
) -> subprocess.Popen:
    log = log_path.open("ab", buffering=0)
    cleanup.log_files.append(log)
    proc = subprocess.Popen(
        args,
        cwd=str(cwd),
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    cleanup.processes.append(proc)
    return proc


def wait_http(url: str, deadline: float) -> None:
    require_loopback_url(url, "health URL")
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2) as response:  # noqa: S310 - loopback URL validated immediately above.
                if response.status < 500:
                    return
        except Exception:
            time.sleep(1)
    raise RuntimeError(f"timed out waiting for {url}")


def wait_listener(host: str, port: int, deadline: float, label: str) -> None:
    require_loopback_host(host, label)
    if port in FORBIDDEN_PORTS:
        raise RuntimeError(f"{label} uses forbidden port {port}")
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(1)
            if sock.connect_ex((host, port)) == 0:
                return
        time.sleep(0.5)
    raise RuntimeError(f"timed out waiting for {label} on {host}:{port}")


def wait_pg(container: str, deadline: float) -> None:
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["docker", "exec", container, "pg_isready", "-U", "postgres"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode == 0:
            return
        time.sleep(1)
    raise RuntimeError("timed out waiting for postgres pg_isready")


def register_account(
    base_url: str, account: Account, secrets_to_redact: list[str]
) -> None:
    require_loopback_url(base_url, "backend base URL")
    payload = json.dumps(
        {"username": account.username, "password": account.password}
    ).encode()
    for path in (
        "/api/v1/auth/register",
        "/api/auth/register",
        "/auth/register",
        "/register",
    ):
        req = urllib.request.Request(  # noqa: S310 - loopback base URL validated immediately above.
            base_url.rstrip("/") + path,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as response:  # noqa: S310 - request URL is built from loopback base URL.
                if response.status < 500:
                    return
        except urllib.error.HTTPError as exc:
            if exc.code in (200, 201, 204, 409):
                return
        except Exception as exc:
            print(
                f"register account path {path} failed locally: {exc}", file=sys.stderr
            )
            continue

    raise RuntimeError(
        f"could not register local profile account {account.username}; backend API paths failed"
    )


def read_process_rows() -> list[ProcessRow]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,rss=,command="],
        text=True,
        capture_output=True,
        check=True,
    )
    rows: list[ProcessRow] = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) == 4:
            rows.append(
                ProcessRow(int(parts[0]), int(parts[1]), parts[3], int(parts[2]))
            )
    return rows


def descendants(rows: Sequence[ProcessRow], roots: set[int]) -> set[int]:
    owned = set(roots)
    changed = True
    while changed:
        changed = False
        for row in rows:
            if row.ppid in owned and row.pid not in owned:
                owned.add(row.pid)
                changed = True
    return owned


def filter_owned_server_pids(
    rows: Sequence[ProcessRow], noray_pids: set[int], repo_root: Path
) -> list[int]:
    ancestry = descendants(rows, noray_pids)
    repo = str(repo_root)
    out = []
    for row in rows:
        cmd = row.command
        if row.pid == FORBIDDEN_PID:
            continue
        if (
            row.pid in ancestry
            and "--server" in cmd
            and repo in cmd
            and ("Godot" in cmd or "godot" in cmd)
        ):
            out.append(row.pid)
    return sorted(out)


def ps_sample(pid: int) -> tuple[float, int] | None:
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "time=,rss="],
            text=True,
            capture_output=True,
            check=True,
        )
    except subprocess.CalledProcessError:
        return None
    parts = result.stdout.strip().split()
    if len(parts) < 2:
        return None
    return parse_ps_time(parts[0]), int(parts[1])


def tail(path: Path, lines: int = 80) -> str:
    if not path.exists():
        return ""
    data = path.read_text(errors="replace").splitlines()
    return "\n".join(data[-lines:])


def finite_nonnegative_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a finite nonnegative number") from exc
    if not math.isfinite(parsed) or parsed < 0.0:
        raise argparse.ArgumentTypeError("must be a finite nonnegative number")
    return parsed


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rooms", type=int, default=1, choices=[1, 2, 3])
    parser.add_argument("--human", action="store_true")
    parser.add_argument("--deadline-seconds", type=int, default=None)
    parser.add_argument(
        "--lobby-hold-seconds", type=finite_nonnegative_float, default=0.0
    )
    parser.add_argument("--npc-rate-hz", type=int, default=30, choices=[30, 15, 10])
    parser.add_argument("--mob-count", type=int, default=None, choices=[0, 1, 20])
    parser.add_argument(
        "--benchmark",
        choices=sorted(BENCHMARK_SCENARIOS),
        default=None,
        help="connected server benchmark scenario; valid Noray/client-probe selections are D, E, and F",
    )
    parser.add_argument("--warmup-seconds", type=finite_nonnegative_float, default=0.0)
    parser.add_argument("--sample-seconds", type=finite_nonnegative_float, default=0.0)
    parser.add_argument("--keep-artifacts", action="store_true")
    parser.add_argument("--noray-root", type=Path, default=None)
    parser.add_argument(
        "--godot",
        type=Path,
        default=Path("/Applications/Godot.app/Contents/MacOS/Godot"),
    )
    args = parser.parse_args(argv)
    if args.deadline_seconds is None:
        args.deadline_seconds = 1800 if args.human else 180
    if args.benchmark is not None:
        scenario = BENCHMARK_SCENARIOS[args.benchmark]
        if not scenario["connected"]:
            parser.error(
                "--benchmark A/B/C are direct headless-only scenarios; use D, E, or F with this Noray/client-probe harness"
            )
        if args.rooms != 1:
            parser.error("--benchmark D/E/F require --rooms 1")
        if args.human:
            parser.error(
                "--benchmark D/E/F require the automated client-probe route, not --human"
            )
        expected_mobs = int(scenario["mobs"])
        if args.mob_count is not None and args.mob_count != expected_mobs:
            parser.error(
                f"--benchmark {args.benchmark} requires --mob-count {expected_mobs}"
            )
        args.mob_count = expected_mobs
    if args.human:
        if args.rooms != 1:
            parser.error("--human supports exactly one room")
        if args.mob_count is not None:
            parser.error("--human is incompatible with --mob-count")
        if args.warmup_seconds > 0.0 or args.sample_seconds > 0.0:
            parser.error("--human is incompatible with benchmark warmup/sample windows")
        args.keep_artifacts = False
    if args.mob_count is not None:
        if args.rooms != 1:
            parser.error("--mob-count supports exactly one room")
        if args.warmup_seconds <= 0.0 or args.sample_seconds <= 0.0:
            parser.error("--mob-count requires positive warmup and sample windows")
    if (
        args.warmup_seconds > 0.0 or args.sample_seconds > 0.0
    ) and args.deadline_seconds < args.warmup_seconds + args.sample_seconds + 20.0:
        parser.error(
            "--deadline-seconds must cover warmup + sample + startup/poll margin"
        )
    return args


def complete_env(extra: dict[str, str]) -> dict[str, str]:
    base = {
        "PATH": os.environ.get(
            "PATH", "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        ),
        "HOME": os.environ.get("HOME", str(Path.home())),
        "TMPDIR": os.environ.get("TMPDIR", tempfile.gettempdir()),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
    }
    base.update(extra)
    return base


def noray_env(
    repo: Path,
    godot: Path,
    provisioner: str,
    npc_rate_hz: int = 30,
    mob_count: int | None = None,
    benchmark: str | None = None,
) -> dict[str, str]:
    env = {
        "NOIKAR_BACKEND_URL": "http://127.0.0.1:18090",
        "NOIKAR_PROVISIONER_CREDENTIAL": provisioner,
        "GODOT_EXECUTABLE_PATH": str(godot),
        "GODOT_PROJECT_PATH": str(repo),
        "NORAY_SOCKET_HOST": "127.0.0.1",
        "NORAY_SOCKET_PORT": "8890",
        "NORAY_HTTP_HOST": "127.0.0.1",
        "NORAY_HTTP_PORT": "8891",
        "NORAY_UDP_RELAY_PORTS": "20000-20100",
        "NORAY_UDP_REGISTRAR_PORT": "8809",
        "NOIKAR_PERF_PROBE": "1",
        "NOIKAR_PERF_PROBE_NPC_COST": "1",
        "NOIKAR_NPC_SNAPSHOT_HZ": str(npc_rate_hz),
        "NOIKAR_SERVER_MAX_FPS": "60",
    }
    if mob_count is not None:
        env["NOIKAR_PROFILE_FIXED_POPULATION"] = "1"
        env["NOIKAR_PROFILE_MOB_COUNT"] = str(mob_count)
    if benchmark is not None:
        env["NOIKAR_BENCHMARK_SCENARIO"] = benchmark
    return complete_env(env)


def client_probe_env(
    *,
    account: Account,
    lobby_hold_seconds: float,
    warmup_seconds: float,
    sample_seconds: float,
    human: bool = False,
    mob_count: int | None = None,
) -> dict[str, str]:
    env = {
        "NOIKAR_PROFILE_ACCOUNT": account.username,
        "NOIKAR_PROFILE_PASSWORD": account.password,
        "NOIKAR_PROFILE_LOBBY_HOLD_SEC": str(max(0.0, lobby_hold_seconds)),
        "NOIKAR_PROFILE_WARMUP_SEC": str(max(0.0, warmup_seconds)),
        "NOIKAR_PROFILE_SAMPLE_SEC": str(max(0.0, sample_seconds)),
        "NOIKAR_BACKEND_URL": "http://127.0.0.1:18090",
        "NOIKAR_NORAY_HOST": "127.0.0.1",
        "NOIKAR_NORAY_PORT": "8890",
        "NOIKAR_PERF_PROBE": "1",
    }
    if human:
        env["NOIKAR_PROFILE_HUMAN"] = "1"
    if mob_count is not None:
        env["NOIKAR_PROFILE_EXPECTED_MOB_COUNT"] = str(mob_count)
        env["NOIKAR_PROFILE_FIXED_ROUTE"] = "1"
    return complete_env(env)


def evaluate_stable_gate(
    *,
    rooms: int,
    active_pids: Sequence[int],
    clients: Sequence[ClientProcess],
    stable_started: float | None,
    now: float,
    samples: dict[int, list[tuple[float, float, int]]],
    pinned_pids: set[int] | None = None,
    server_parsers: dict[int, ServerLogParser] | None = None,
    mob_count: int | None = None,
) -> StableGate:
    stable_wall = 0.0 if stable_started is None else max(0.0, now - stable_started)
    expected_pids = set(active_pids) if pinned_pids is None else set(pinned_pids)
    exact_server_count = len(active_pids) == rooms and set(active_pids) == expected_pids
    clients_ready = len(clients) == rooms and all(cp.parser.ready for cp in clients)
    sampling_ok = (
        len(samples) == rooms
        and set(samples) == expected_pids
        and all(len(rows) >= 2 for rows in samples.values())
    )
    no_early_client_exit = all(
        cp.end_monotonic is None
        or stable_started is not None
        and cp.end_monotonic - stable_started >= 8.0
        for cp in clients
    )
    if mob_count is None:
        population_marker_verified = True
    else:
        parsers = server_parsers or {}
        population_marker_verified = len(expected_pids) == rooms and all(
            pid in parsers
            and parsers[pid].population_ready
            and not parsers[pid].population_failed
            for pid in expected_pids
        )
    return StableGate(
        exact_server_count=exact_server_count,
        clients_ready=clients_ready,
        sampling_ok=sampling_ok,
        stable_wall_seconds=stable_wall,
        pinned_pids=expected_pids,
        no_early_client_exit=no_early_client_exit,
        population_marker_verified=population_marker_verified,
    )


def run(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    repo = repo_root_from_script()
    noray_root = args.noray_root or (repo.parent / "noikar-noray")
    if not (repo / "project.godot").exists():
        raise RuntimeError(f"repo root check failed: {repo}/project.godot missing")
    if not noray_root.exists() or not (noray_root / "bin" / "noray.mjs").exists():
        raise RuntimeError(
            f"Noray repo missing; expected sibling {noray_root} with bin/noray.mjs"
        )
    if not args.godot.exists():
        raise RuntimeError(
            f"Godot executable missing at {args.godot}; pass --godot /absolute/path/to/Godot"
        )
    preflight_ports()

    tmp = Path(tempfile.mkdtemp(prefix="noikar-profile-"))
    cleanup = CleanupPlan(temp_dir=tmp, keep_artifacts=args.keep_artifacts)
    secrets_to_redact: list[str] = []
    server_parsers: dict[int, ServerLogParser] = {}
    combined_parser = CombinedLogParser()
    clients: list[ClientProcess] = []
    samples: dict[int, list[tuple[float, float, int]]] = {}
    success = False
    run_started = time.monotonic()
    stop_request = StopRequest()
    handler_context = install_stop_handlers(stop_request)
    handler_context.__enter__()
    if args.human:
        print(f"Human mode deadline: {args.deadline_seconds}s", flush=True)
    try:
        suffix = secrets.token_hex(6)
        container = f"noikar-profile-pg-{suffix}"
        volume = f"noikar-profile-pgdata-{suffix}"
        cleanup.container = container
        cleanup.volume = volume
        spec = postgres_spec(container, volume)
        subprocess.run(spec.command, check=True)
        wait_pg(container, time.monotonic() + 45)

        jwt_secret = secrets.token_urlsafe(32)
        provisioner = secrets.token_urlsafe(32)
        secrets_to_redact.extend([jwt_secret, provisioner])
        backend_log = tmp / "backend.log"
        database_url = "postgres://postgres@127.0.0.1:15432/postgres?sslmode=disable"
        backend_env = complete_env(
            {
                "DATABASE_URL": database_url,
                "PORT": "18090",
                "JWT_SECRET": jwt_secret,
                "PROVISIONER_CREDENTIAL": provisioner,
            }
        )
        start_process(
            ["go", "run", "./cmd/server"],
            cwd=repo / "backend",
            env=backend_env,
            log_path=backend_log,
            cleanup=cleanup,
        )
        wait_http("http://127.0.0.1:18090/api/v1/health", time.monotonic() + 60)

        accounts = generate_accounts(args.rooms)
        secrets_to_redact.extend(a.password for a in accounts)
        for account in accounts:
            register_account("http://127.0.0.1:18090", account, secrets_to_redact)

        noray_log = tmp / "noray.log"
        noray_proc = start_process(
            ["node", "bin/noray.mjs"],
            cwd=noray_root,
            env=noray_env(
                repo,
                args.godot,
                provisioner,
                npc_rate_hz=args.npc_rate_hz,
                mob_count=args.mob_count,
            ),
            log_path=noray_log,
            cleanup=cleanup,
        )

        wait_listener("127.0.0.1", 8890, time.monotonic() + 45, "Noray")

        for i, account in enumerate(accounts):
            client_log = tmp / f"client-{i}.log"
            client_env = client_probe_env(
                account=account,
                lobby_hold_seconds=args.lobby_hold_seconds,
                warmup_seconds=args.warmup_seconds,
                sample_seconds=args.sample_seconds,
                human=args.human,
                mob_count=args.mob_count,
            )

            proc = start_process(
                [
                    str(args.godot),
                    "--path",
                    str(repo),
                    "--script",
                    "res://tests/manual/live_gameplay_probe.gd",
                ],
                cwd=repo,
                env=client_env,
                log_path=client_log,
                cleanup=cleanup,
            )
            clients.append(
                ClientProcess(
                    index=i,
                    account=account,
                    process=proc,
                    log_path=client_log,
                    parser=ClientLogParser(args.mob_count),
                )
            )

        deadline = time.monotonic() + args.deadline_seconds
        stable_started: float | None = None
        pinned_pids: set[int] | None = None
        last_sizes: dict[Path, int] = {}
        last_noray_size = 0
        human_ready_emitted = False
        active_end_rows_discarded = 0
        fixed_workload_closed = False

        def refresh_client_logs(now: float) -> None:
            for cp in clients:
                size = cp.log_path.stat().st_size if cp.log_path.exists() else 0
                if size != last_sizes.get(cp.log_path, 0):
                    cp.parser.feed(cp.log_path.read_text(errors="replace"))
                    last_sizes[cp.log_path] = size
                if cp.process.poll() is not None and cp.end_monotonic is None:
                    cp.end_monotonic = now

        while time.monotonic() < deadline and not stop_request.requested:
            now = time.monotonic()
            rows = read_process_rows()
            server_pids = filter_owned_server_pids(rows, {noray_proc.pid}, repo)
            cleanup.server_pids.update(server_pids)
            for pid in server_pids:
                server_parsers.setdefault(pid, ServerLogParser(args.mob_count))
            if noray_log.exists() and noray_log.stat().st_size != last_noray_size:
                noray_text = noray_log.read_text(errors="replace")
                combined_parser.feed(noray_text)
                for parser in server_parsers.values():
                    parser.feed(noray_text)
                last_noray_size = noray_log.stat().st_size
            refresh_client_logs(now)
            if (
                pinned_pids is None
                and len(server_pids) == args.rooms
                and all(cp.parser.ready for cp in clients)
                and (
                    args.mob_count is None
                    or all(
                        server_parsers.get(pid) is not None
                        and server_parsers[pid].population_ready
                        and not server_parsers[pid].population_failed
                        for pid in server_pids
                    )
                )
            ):
                pinned_pids = set(server_pids)
                stable_started = now
                samples = {pid: [] for pid in pinned_pids}
            if pinned_pids is not None:
                for pid in sorted(pinned_pids):
                    if pid in server_pids and not fixed_workload_closed:
                        sample = ps_sample(pid)
                        sample_time = time.monotonic()
                        if sample:
                            if args.mob_count is not None:
                                refresh_client_logs(time.monotonic())
                                if any(
                                    cp.parser.fixed_workload_ended
                                    or cp.process.poll() is not None
                                    for cp in clients
                                ):
                                    active_end_rows_discarded += 1
                                    fixed_workload_closed = True
                                    continue
                            samples.setdefault(pid, []).append(
                                (sample_time, sample[0], sample[1])
                            )
            if (
                args.human
                and not human_ready_emitted
                and pinned_pids is not None
                and all(cp.parser.human_ready for cp in clients)
            ):
                ready_payload = {
                    "supervisor_pid": os.getpid(),
                    "client_pids": [cp.process.pid for cp in clients],
                    "server_pids": sorted(pinned_pids),
                    "temp_dir": str(tmp),
                    "log_dir": str(tmp),
                    "requested_npc_rate_hz": args.npc_rate_hz,
                    "deadline_seconds": args.deadline_seconds,
                }
                print(
                    "HUMAN_SESSION_READY " + json.dumps(ready_payload, sort_keys=True),
                    flush=True,
                )
                human_ready_emitted = True
            if all(cp.process.poll() is not None for cp in clients):
                break
            time.sleep(1)

        refresh_client_logs(time.monotonic())

        if args.human:
            active_pids = filter_owned_server_pids(
                read_process_rows(), {noray_proc.pid}, repo
            )
            gate = evaluate_stable_gate(
                rooms=args.rooms,
                active_pids=active_pids,
                clients=clients,
                stable_started=stable_started,
                now=time.monotonic(),
                samples=samples,
                pinned_pids=pinned_pids,
                server_parsers=server_parsers,
                mob_count=args.mob_count,
            )
            result = build_result(
                args.rooms,
                clients,
                samples,
                server_parsers,
                combined_parser,
                gate,
                tmp,
                profile=ProfileWindow(
                    0.0, 0.0, stable_started, run_started, active_end_rows_discarded
                ),
                npc_rate_hz=args.npc_rate_hz,
                mob_count=args.mob_count,
                human=True,
                supervisor_pid=os.getpid(),
                requested_deadline_seconds=args.deadline_seconds,
            )
            print(json.dumps(result, sort_keys=True), flush=True)
            print("manual_session_not_benchmark", flush=True)
            success = True
            if stop_request.signum is not None:
                return 128 + int(stop_request.signum)
            return 0

        legacy_mode = args.warmup_seconds == 0.0 and args.sample_seconds == 0.0
        for cp in clients:
            if cp.process.poll() is None:
                raise RuntimeError("deadline expired before all clients exited")
            if (
                legacy_mode
                and (cp.end_monotonic or time.monotonic()) - cp.start_monotonic < 8
            ):
                raise RuntimeError(f"client {cp.index} exited before 8s sampling gate")
        active_pids = filter_owned_server_pids(
            read_process_rows(), {noray_proc.pid}, repo
        )
        gate = evaluate_stable_gate(
            rooms=args.rooms,
            active_pids=active_pids,
            clients=clients,
            stable_started=stable_started,
            now=time.monotonic(),
            samples=samples,
            pinned_pids=pinned_pids,
            server_parsers=server_parsers,
            mob_count=args.mob_count,
        )
        if not gate.ok and legacy_mode:
            raise RuntimeError(f"stable sampling gate failed: {gate}")
        functional = all(
            cp.process.returncode == 0 and cp.parser.passed and cp.parser.metrics
            for cp in clients
        )
        result = build_result(
            args.rooms,
            clients,
            samples,
            server_parsers,
            combined_parser,
            gate,
            tmp,
            profile=ProfileWindow(
                args.warmup_seconds,
                args.sample_seconds,
                stable_started,
                run_started,
                active_end_rows_discarded,
            ),
            npc_rate_hz=args.npc_rate_hz,
            mob_count=args.mob_count,
        )

        print_summary(result, secrets_to_redact)
        print(json.dumps(result, sort_keys=True))
        room_results = result["rooms"]
        result_gate = result["gate"]
        success = (
            functional
            and gate.exact_server_count
            and gate.clients_ready
            and gate.sampling_ok
            and (gate.stable_wall_seconds >= 8.0 if legacy_mode else True)
            and isinstance(result_gate, dict)
            and bool(result_gate["sample_window"])
            and bool(result_gate["alive"])
            and bool(result_gate["mob_population_stable"])
            and bool(result_gate["movement"])
            and bool(result_gate["projectile"])
            and bool(result_gate["mob_movement"])
            and bool(result_gate["observed_near_npc"])
            and bool(result_gate["marker_verified"])
            and bool(result_gate["workload_valid"])
            and bool(result_gate["fixed_workload_end_observed"])
            and isinstance(room_results, list)
            and len(room_results) == args.rooms
        )
        return 0 if success else 2
    except Exception as exc:
        print(f"FAILED: {redact(str(exc), secrets_to_redact)}", file=sys.stderr)
        for path in sorted(tmp.glob("*.log")) if tmp.exists() else []:
            print(f"--- {path.name} tail ---", file=sys.stderr)
            print(redact(tail(path), secrets_to_redact), file=sys.stderr)
        return 1
    finally:
        handler_context.__exit__(None, None, None)
        cleanup.run()
        clear = assert_ports_clear()
        uncleared = [p for p, ok in clear.items() if not ok]
        if uncleared:
            print(f"cleanup: ports still occupied: {uncleared}", file=sys.stderr)
            raise SystemExit(3)
        if args.keep_artifacts:
            print(f"artifacts kept at {tmp}")
        elif not success:
            print(
                "artifacts removed; rerun with --keep-artifacts to preserve logs",
                file=sys.stderr,
            )


def select_fixed_population_cpu_rows(
    rows: list[tuple[float, float, int]], requested_sample_seconds: float
) -> list[tuple[float, float, int]]:
    if len(rows) < 2:
        return rows
    start_row = rows[0]
    for end_index in range(1, len(rows)):
        if rows[end_index][0] - start_row[0] >= requested_sample_seconds:
            return rows[: end_index + 1]
    return rows


def build_result(
    rooms: int,
    clients: list[ClientProcess],
    samples: dict[int, list[tuple[float, float, int]]],
    server_parsers: dict[int, ServerLogParser],
    combined_parser: CombinedLogParser,
    gate: StableGate,
    tmp: Path,
    *,
    profile: ProfileWindow | None = None,
    npc_rate_hz: int = 30,
    mob_count: int | None = None,
    human: bool = False,
    supervisor_pid: int | None = None,
    requested_deadline_seconds: int | None = None,
) -> dict[str, object]:
    profile = profile or ProfileWindow(stable_started=None)
    sample_start = (
        profile.stable_started + profile.requested_warmup_seconds
        if profile.stable_started is not None
        else None
    )
    per_room = []
    cpu_values = []
    rss_values = []
    sample_durations = []
    for pid, rows in sorted(samples.items()):
        sample_rows = rows
        if profile.long_mode and sample_start is not None:
            sample_rows = [row for row in rows if row[0] >= sample_start]
            if mob_count is not None:
                sample_rows = select_fixed_population_cpu_rows(
                    sample_rows, profile.requested_sample_seconds
                )
        if len(sample_rows) < 2:
            cpu = 0.0
            rss = 0
        else:
            start_row, end_row = sample_rows[0], sample_rows[-1]
            duration = max(0.0, end_row[0] - start_row[0])
            sample_durations.append(duration)
            cpu = cpu_percent_delta(start_row[1], end_row[1], duration)
            rss = max(r[2] for r in sample_rows)
        cpu_values.append(cpu)
        rss_values.append(rss)
        parser = server_parsers.get(pid, ServerLogParser())
        per_room.append(
            {
                "pid": pid,
                "cpu_percent": round(cpu, 2),
                "rss_kb": rss,
                "sync_rpc_errors": parser.errors[:10],
                "perf_probe": parser.perf_lines[-10:],
                "sample_count": len(sample_rows),
            }
        )
    client_results = []
    for cp in clients:
        client_results.append(
            {
                "index": cp.index,
                "account": cp.account.username,
                "returncode": cp.process.returncode,
                "ready": cp.parser.ready,
                "passed": cp.parser.passed,
                "metrics": cp.parser.metrics,
                "telemetry": cp.parser.telemetry,
                "errors": cp.parser.errors[:10],
            }
        )
    actual_sample_duration = min(sample_durations) if sample_durations else 0.0
    startup_duration = 0.0
    if profile.run_started is not None and profile.stable_started is not None:
        startup_duration = max(0.0, profile.stable_started - profile.run_started)
    sample_window_ok = (
        gate.sampling_ok
        and actual_sample_duration >= profile.requested_sample_seconds
        and all(room["sample_count"] >= 2 for room in per_room)
    )
    expected_mobs = 20 if mob_count is None else mob_count
    fixed_population_mode = mob_count is not None
    alive_ok = all(not c["metrics"].get("dead", False) for c in client_results)
    mob_population_stable = all(
        c["metrics"].get("mobs_start", expected_mobs)
        == c["metrics"].get("mobs_end", expected_mobs)
        == expected_mobs
        for c in client_results
    )
    projectile_ok = all(
        int(c["metrics"].get("max_projectiles", 0)) > 0 for c in client_results
    )
    movement_ok = all(
        float(c["metrics"].get("movement", 0.0)) >= 1.0 for c in client_results
    )
    if fixed_population_mode and mob_count == 0:
        mob_movement_ok = True
        observed_near_npc_ok = True
    else:
        mob_movement_ok = all(
            float(c["metrics"].get("mob_displacement", 0.0)) > 0.1
            for c in client_results
        )
        observed_near_npc_ok = (
            all(
                int(c["metrics"].get("observed_npcs_within_90m", {}).get("max", 0)) > 0
                for c in client_results
            )
            if profile.long_mode
            else True
        )
    workload_valid = all(
        not c["metrics"].get("workload_invalid", False) for c in client_results
    )
    fixed_workload_end_observed = (
        True
        if not fixed_population_mode
        else all(getattr(cp.parser, "fixed_workload_ended", False) for cp in clients)
    )
    population_markers = [
        dict(server_parsers[pid].population_marker, pid=pid)
        for pid in sorted(samples)
        if pid in server_parsers
    ]
    result = {
        "rooms_requested": rooms,
        "requested_npc_rate_hz": npc_rate_hz,
        "requested_warmup_seconds": profile.requested_warmup_seconds,
        "requested_sample_seconds": profile.requested_sample_seconds,
        "startup_duration_seconds": round(startup_duration, 2),
        "warmup_duration_seconds": profile.requested_warmup_seconds,
        "actual_sample_duration_seconds": round(actual_sample_duration, 2),
        "workload": "fixed_route"
        if fixed_population_mode
        else ("orbit" if profile.long_mode else "legacy"),
        "requested_mob_count": mob_count,
        "fixed_population_mode": fixed_population_mode,
        "marker_verified": gate.population_marker_verified,
        "population_markers": population_markers,
        "active_sample_proof": {
            "fixed_workload_end_observed": fixed_workload_end_observed,
            "discarded_end_rows": profile.active_end_rows_discarded,
        },
        "clients": client_results,
        "gate": {
            "functional": all(
                c["passed"] and c["returncode"] == 0 for c in client_results
            ),
            "sampling": gate.sampling_ok,
            "sample_window": sample_window_ok,
            "stable_wall_seconds": round(gate.stable_wall_seconds, 2),
            "exact_server_count": gate.exact_server_count,
            "clients_ready": gate.clients_ready,
            "alive": alive_ok,
            "mob_population_stable": mob_population_stable,
            "movement": movement_ok,
            "projectile": projectile_ok,
            "mob_movement": mob_movement_ok,
            "observed_near_npc": observed_near_npc_ok,
            "workload_valid": workload_valid,
            "fixed_workload_end_observed": fixed_workload_end_observed,
            "marker_verified": gate.population_marker_verified,
            "no_early_client_exit": gate.no_early_client_exit,
            "pass_count": sum(1 for c in client_results if c["passed"]),
        },
        "rooms": per_room,
        "combined_server_perf_probe": combined_parser.perf_lines[-20:],
        "npc_cost_intervals": combined_parser.npc_cost_intervals[-20:],
        "combined_server_errors": combined_parser.errors[:20],
        "aggregate": {
            "cpu_percent_total": round(sum(cpu_values), 2),
            "rss_kb_total": sum(rss_values),
            "cpu_variance": round(variance(cpu_values), 2),
            "rss_variance": round(variance(rss_values), 2),
        },
        "artifacts": str(tmp),
    }
    if human:
        result.update(
            {
                "outcome": "manual_session_not_benchmark",
                "supervisor_pid": os.getpid()
                if supervisor_pid is None
                else supervisor_pid,
                "client_pids": [cp.process.pid for cp in clients],
                "server_pids": sorted(samples.keys()),
                "requested_deadline_seconds": requested_deadline_seconds,
            }
        )
    return result


def variance(values: Sequence[float]) -> float:
    if not values:
        return 0.0
    mean = sum(values) / len(values)
    return sum((v - mean) ** 2 for v in values) / len(values)


def print_summary(result: dict[str, object], secrets_to_redact: Iterable[str]) -> None:
    print("Noikar local room profiling summary")
    print(f"Gate: {result['gate']}")
    for client in result["clients"]:  # type: ignore[index]
        print(
            redact(
                f"Client {client['index']}: passed={client['passed']} metrics={client['metrics']}",
                secrets_to_redact,
            )
        )
    for room in result["rooms"]:  # type: ignore[index]
        print(
            f"Room pid={room['pid']} cpu={room['cpu_percent']}% rss={room['rss_kb']}KB errors={len(room['sync_rpc_errors'])}"
        )
    print(f"Aggregate: {result['aggregate']}")


if __name__ == "__main__":
    sys.exit(run())
