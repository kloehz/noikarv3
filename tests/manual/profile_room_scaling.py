#!/usr/bin/env python3
"""Local 1-3 room profiling supervisor for noikar.

This script intentionally uses only Python's standard library and only loopback
networking. It owns the exact local processes, Docker container/volume, and temp
artifacts it creates, then tears them down in one finally block.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import math
import os
import re
import secrets
import shutil
import signal
import socket
import statistics
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
ADMITTED_OID_RE = re.compile(r"\[LIVE-PROBE\]\s+admitted\s+oid=(?P<oid>\S+)")
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
ERROR_RE = re.compile(r"(rpc|error|exception|fail)", re.IGNORECASE)
TELEMETRY_RE = re.compile(
    r"\[LIVE-PROBE\]\s+telemetry\s+npc_stride_counts=(?P<strides>\{[^}]*\})\s+"
    r"interpolator_buffer_counts=(?P<buffers>\{[^}]*\})"
)
AUTHORITATIVE_STRIDE_RE = re.compile(
    r"npc_authoritative_stride_counts=(?P<strides>\{[^}]*\})"
)
NPC_COST_KEY_RE = re.compile(
    r"(?P<name>npc_(?:ai_inclusive|movement_inclusive|movement_prepare_child|movement_slide_child|movement_flush_child|combat))_(?P<field>total_usec|calls|max_usec)=(?P<value>\d+)"
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
        for command in (["docker", "rm", "-f", self.container] if self.container else None,
                        ["docker", "volume", "rm", "-f", self.volume] if self.volume else None):
            if command is None:
                continue
            try:
                result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
                if result.returncode != 0:
                    print("cleanup: owned Docker resource removal failed", file=sys.stderr)
            except subprocess.TimeoutExpired:
                print("cleanup: owned Docker resource removal timed out", file=sys.stderr)

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
        self.active_errors: list[str] = []
        self.teardown_errors: list[str] = []
        self.perf_lines: list[str] = []

    def feed(self, text: str, *, teardown_only: bool = False) -> None:
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
            if is_error_line(line):
                if teardown_only:
                    self.teardown_errors.append(line)
                else:
                    self.errors.append(line)
                    self.active_errors.append(line)
            if is_perf_line(line):
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
        self.admitted_oid: str | None = None
        self.errors: list[str] = []
        self.active_errors: list[str] = []
        self.teardown_errors: list[str] = []
        self._active_complete_seen = False

    def feed(self, text: str) -> None:
        for line in text.splitlines():
            admitted = ADMITTED_OID_RE.search(line)
            if admitted:
                self.admitted_oid = admitted.group("oid")
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
                self._active_complete_seen = True
            if PASS_RE.search(line):
                self.passed = True
                self._active_complete_seen = True
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
            if is_error_line(line):
                self.errors.append(line)
                if self._active_complete_seen:
                    self.teardown_errors.append(line)
                else:
                    self.active_errors.append(line)


class CombinedLogParser:
    def __init__(self) -> None:
        self.perf_lines: list[str] = []
        self.npc_cost_intervals: list[dict[str, object]] = []
        self.authoritative_stride_intervals: list[dict[str, int]] = []
        self.errors: list[str] = []
        self.active_errors: list[str] = []
        self.teardown_errors: list[str] = []

    def feed(self, text: str, *, teardown_only: bool = False) -> None:
        for line in text.splitlines():
            if is_perf_line(line) and line not in self.perf_lines:
                self.perf_lines.append(line)
                cost = parse_npc_cost_interval(line)
                if cost and len(self.npc_cost_intervals) < 40:
                    self.npc_cost_intervals.append(cost)
                authoritative = parse_authoritative_stride_interval(line)
                if (
                    authoritative is not None
                    and len(self.authoritative_stride_intervals) < 40
                ):
                    self.authoritative_stride_intervals.append(authoritative)
            if is_error_line(line):
                if teardown_only:
                    self.teardown_errors.append(line)
                else:
                    self.errors.append(line)
                    self.active_errors.append(line)


def _parse_nullable_float(text: str) -> float | None:
    return None if text == "null" else float(text)


def _parse_int_dict(text: str) -> dict[str, int]:
    try:
        raw = ast.literal_eval(text)
    except (SyntaxError, ValueError):
        return _parse_loose_int_dict(text)
    if not isinstance(raw, dict):
        return {}
    parsed: dict[str, int] = {}
    for key, value in raw.items():
        try:
            parsed[str(key)] = int(value)
        except (TypeError, ValueError):
            continue
    return parsed


def _parse_loose_int_dict(text: str) -> dict[str, int]:
    stripped = text.strip()
    if not stripped.startswith("{") or not stripped.endswith("}"):
        return {}
    body = stripped[1:-1].strip()
    if not body:
        return {}
    parsed: dict[str, int] = {}
    for entry in body.split(","):
        if ":" not in entry:
            continue
        key, value = entry.split(":", 1)
        key = key.strip().strip("'\"")
        try:
            parsed[key] = int(value.strip())
        except ValueError:
            continue
    return parsed


def is_perf_line(line: str) -> bool:
    return "[BENCHMARK]" in line or "PerfProbe" in line or "perf" in line.lower()


def is_error_line(line: str) -> bool:
    return ERROR_RE.search(line) is not None


def parser_list_attr(parser: object, name: str) -> list[str]:
    value = getattr(parser, name, [])
    return value if isinstance(value, list) else []


def parse_npc_cost_interval(line: str) -> dict[str, object]:
    interval: dict[str, object] = {}
    for match in NPC_COST_KEY_RE.finditer(line):
        bucket = interval.setdefault(match.group("name"), {})
        if isinstance(bucket, dict):
            bucket[match.group("field")] = int(match.group("value"))
    for match in NPC_COUNTER_KEY_RE.finditer(line):
        interval[match.group("name")] = int(match.group("value"))
    return interval


def parse_authoritative_stride_interval(line: str) -> dict[str, int] | None:
    match = AUTHORITATIVE_STRIDE_RE.search(line)
    if not match:
        return None
    return _parse_int_dict(match.group("strides"))


def cpu_interval_peak(
    rows: list[tuple[float, float, int]],
) -> tuple[float, float]:
    peak = 0.0
    resolution = 0.0
    for index in range(len(rows) - 1):
        start, end = rows[index], rows[index + 1]
        wall_seconds = max(0.0, end[0] - start[0])
        if wall_seconds <= 0.0:
            continue
        interval_cpu = cpu_percent_delta(start[1], end[1], wall_seconds)
        if interval_cpu > peak:
            peak = interval_cpu
        if resolution == 0.0 or wall_seconds < resolution:
            resolution = wall_seconds
    return peak, resolution


def expected_npc_stride(npc_rate_hz: int, *, netfox_profile: str | None = None,
                        verified_native_hz: int | None = None) -> int | None:
    # Legacy snapshot experiments use the authored native30 clock. Explicit
    # comparison arms fail closed until cached server/client readbacks agree.
    if netfox_profile is None:
        native_hz = 30 if verified_native_hz is None else verified_native_hz
        if native_hz != 30:
            return None
    else:
        native_hz = {"compare30": 30, "compare60": 60}.get(netfox_profile)
        if native_hz is None or verified_native_hz != native_hz or npc_rate_hz != native_hz:
            return None
    if npc_rate_hz <= 0 or native_hz % npc_rate_hz != 0:
        return None
    stride = native_hz // npc_rate_hz
    return stride if stride in (1, 2, 3) else None


def npc_stride_proof(
    client_results: list[dict[str, object]],
    npc_rate_hz: int,
    mob_count: int | None,
    authoritative_intervals: Sequence[dict[str, int]] | None = None,
    *,
    netfox_profile: str | None = None,
    verified_native_hz: int | None = None,
) -> dict[str, object]:
    expected_stride = expected_npc_stride(npc_rate_hz, netfox_profile=netfox_profile,
                                         verified_native_hz=verified_native_hz)
    exempt = mob_count is None or mob_count == 0
    client_proofs = []
    for client in client_results:
        telemetry = client.get("telemetry", {})
        observed: dict[str, int] = {}
        if isinstance(telemetry, dict):
            raw = telemetry.get("npc_stride_counts", {})
            if isinstance(raw, dict):
                observed = {str(key): int(value) for key, value in raw.items()}
        client_proofs.append(
            {
                "index": client.get("index"),
                "observed": observed,
                "ok": True
                if exempt
                else expected_stride is not None
                and observed.get(str(expected_stride)) == mob_count,
                "diagnostic_only": mob_count is not None and mob_count > 0,
            }
        )
    if exempt:
        return {
            "ok": True,
            "exempt": True,
            "expected_stride": expected_stride,
            "expected_population": mob_count,
            "source": "exempt_zero_or_unspecified_population",
            "clients": client_proofs,
        }
    if mob_count is not None and mob_count > 0:
        intervals = list(authoritative_intervals or [])
        if not intervals:
            return {
                "ok": False,
                "exempt": False,
                "expected_stride": expected_stride,
                "expected_population": mob_count,
                "source": "server_authoritative_perf_probe",
                "reason": "missing_authoritative_perf_probe_evidence",
                "authoritative_observed": {},
                "authoritative_missing": 0,
                "authoritative_unknown": 0,
                "clients": client_proofs,
            }
        observed = {str(key): int(value) for key, value in intervals[-1].items()}
        missing = observed.get("missing", 0)
        unknown = observed.get("unknown", 0)
        expected_count = (
            observed.get(str(expected_stride), 0) if expected_stride is not None else 0
        )
        ok = (
            expected_stride is not None
            and expected_count == mob_count
            and missing == 0
            and unknown == 0
            and all(value >= 0 for value in observed.values())
            and sum(observed.values()) == mob_count
        )
        reason = "ok" if ok else "authoritative_stride_mismatch_or_incomplete"
        return {
            "ok": ok,
            "exempt": False,
            "expected_stride": expected_stride,
            "expected_population": mob_count,
            "source": "server_authoritative_perf_probe",
            "reason": reason,
            "authoritative_observed": observed,
            "authoritative_missing": missing,
            "authoritative_unknown": unknown,
            "clients": client_proofs,
        }
    ok = bool(client_results) and all(
        client.get("ok", False) for client in client_proofs
    )
    return {
        "ok": ok,
        "exempt": False,
        "expected_stride": expected_stride,
        "expected_population": mob_count,
        "source": "client_diagnostic_legacy",
        "clients": client_proofs,
    }


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
            timeout=min(5, max(0.1, deadline - time.monotonic())),
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


def read_incremental_text(path: Path, offset: int) -> tuple[str, int]:
    if not path.exists():
        return "", 0
    size = path.stat().st_size
    start = offset if 0 <= offset <= size else 0
    with path.open("rb") as handle:
        handle.seek(start)
        data = handle.read()
    if not data:
        return "", start
    last_newline = data.rfind(b"\n")
    if last_newline < 0:
        return "", start
    safe_end = last_newline + 1
    return data[:safe_end].decode(errors="replace"), start + safe_end


def fixed_workload_completion_seen(clients: Sequence[ClientProcess]) -> bool:
    return any(
        cp.parser.fixed_workload_ended or cp.end_monotonic is not None for cp in clients
    )


def update_fixed_workload_closed(
    current: bool, clients: Sequence[ClientProcess], mob_count: int | None
) -> bool:
    return current or (
        mob_count is not None and fixed_workload_completion_seen(clients)
    )


def route_incremental_noray_log(
    path: Path,
    offset: int,
    combined_parser: CombinedLogParser,
    server_parsers: dict[int, ServerLogParser],
    *,
    teardown_only: bool,
) -> int:
    noray_text, new_size = read_incremental_text(path, offset)
    if not noray_text and new_size == offset:
        return offset
    combined_parser.feed(noray_text, teardown_only=teardown_only)
    for parser in server_parsers.values():
        parser.feed(noray_text, teardown_only=teardown_only)
    return new_size


def finite_nonnegative_float(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a finite nonnegative number") from exc
    if not math.isfinite(parsed) or parsed < 0.0:
        raise argparse.ArgumentTypeError("must be a finite nonnegative number")
    return parsed


def readiness_trace_rows(text: str, role: str, index: int | None = None) -> list[dict]:
    # The standalone remote agent owns the same allowlist; no unchecked marker text.
    from vps_benchmark_agent import sanitize_readiness_row
    rows=[]
    for line in text.splitlines():
        if not line.startswith('[PROFILE_READINESS] '):continue
        try:row=sanitize_readiness_row(json.loads(line.split(' ',1)[1]),role,index)
        except ValueError:continue
        if row is not None:rows.append(row)
        if len(rows)==192:break
    return rows


def safe_phase_trace(text: str) -> list[str]:
    # Exact numeric-only event envelope: no account, OID, tokens or arbitrary text.
    pattern = re.compile(r"\[PROFILE_PHASE\] t_usec=\d+ source=(?:lobby_snapshot|phase_event|ui_switch) phase=-?\d+ ui_before=\d+ ui_after=\d+ network_tick=\d+")
    return [match.group(0) for match in pattern.finditer(text)][:128]


def profile_readbacks(text: str) -> list[dict[str, object]]:
    rows = []
    for line in text.splitlines():
        match = re.search(r"\[NETFOX_PROFILE\] (\{.*\})", line)
        if not match:
            continue
        try:
            row = json.loads(match.group(1))
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("stage") == "before_network_start":
            rows.append(row)
    return rows


def verify_profile_readback(rows: list[dict[str, object]], profile: str, role: str) -> bool:
    hz = 30 if profile == "compare30" else 60
    expected = {"profile": profile, "role": role, "network_hz": hz,
                "physics_hz": 50, "sync_to_physics": False,
                "max_fps": 75 if role == "server" else 60,
                "history_ticks": hz * 5, "display_offset_ticks": 2,
                "input_delay_ticks": 0, "input_redundancy": 3}
    return bool(rows) and all(all(row.get(k) == v for k, v in expected.items()) for row in rows)


def json_marker_rows(text: str, marker: str) -> list[dict[str, object]]:
    rows = []
    decoder = json.JSONDecoder()
    for line in text.splitlines():
        pos = line.find(marker)
        if pos < 0:
            continue
        try:
            row, _ = decoder.raw_decode(line[pos + len(marker):].lstrip())
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def owner_markers(clients: Sequence[ClientProcess], stage: str) -> list[dict[str, int]]:
    pattern = re.compile(r"\[LIVE-PROBE\] " + stage + r" index=(\d+) owner=(\d+) team=(\d+)")
    rows = []
    for cp in clients:
        matches = list(pattern.finditer(cp.log_path.read_text(errors="replace")))
        if len(matches) != 1:
            continue
        match = matches[0]
        rows.append(dict(index=int(match[1]), owner=int(match[2]), team=int(match[3])))
    return rows


def verified_owners(rows: list[dict[str, int]], player_count: int = 20) -> bool:
    if type(player_count) is not int or player_count not in (10, 20):
        return False
    return (len(rows) == player_count and all(type(r.get("index")) is int for r in rows)
            and sorted(r.get("index", -1) for r in rows) == list(range(player_count))
            and len({r.get("owner") for r in rows}) == player_count
            and all(type(r.get("owner")) is int and r["owner"] > 1 for r in rows)
            and all(type(r.get("team")) is int and r["team"] == (1 if r["index"] < player_count // 2 else 2) for r in rows))


def verified_twenty_owners(rows: list[dict[str, int]]) -> bool:
    return verified_owners(rows, 20)


def verified_owner_population(row: dict[str, object], owners: set[int] | None = None, player_count: int = 20) -> bool:
    if type(player_count) is not int or player_count not in (10, 20):
        return False
    ids = row.get("owners")
    if not isinstance(ids, list) or len(ids) != player_count or any(type(i) is not int or i <= 1 for i in ids) or len(set(ids)) != player_count:
        return False
    if owners is not None and set(ids) != owners:
        return False
    expected = dict(authenticated_accounts=player_count, authenticated_peers=player_count, lobby_players=player_count,
                    red=player_count // 2, blue=player_count // 2, alive_players=player_count, server_state_authorities=player_count, live_mobs=20, alive_mobs=20)
    if not all(type(row.get(k)) is int and row[k] == v for k, v in expected.items()):
        return False
    for key in ("input_authorities", "connected_peers"):
        value = row.get(key)
        if not isinstance(value, list) or any(type(v) is not int for v in value) or sorted(value) != sorted(ids):
            return False
    positions = row.get("positions")
    if not isinstance(positions, dict) or set(positions) != {str(i) for i in ids}:
        return False
    return all(isinstance(p, list) and len(p) == 3 and all(type(v) in (int, float) and math.isfinite(v) for v in p) for p in positions.values())


def authoritative_moving_owners(rows: list[dict[str, object]], player_count: int = 20) -> set[int]:
    if not rows or not all(verified_owner_population(row, player_count=player_count) for row in rows):
        return set()
    start = rows[0]["positions"]
    return {int(i) for i, point in start.items() if any(math.dist(point, row["positions"][i]) >= 1.0 for row in rows[1:])}


def verified_capacity_readback(text: str, role: str, player_count: int = 20) -> bool:
    if type(player_count) is not int or player_count not in (10, 20):
        return False
    rows = json_marker_rows(text, "[PROFILE_CAPACITY]")
    expected = dict(role=role, requested_players=player_count, max_players_per_team=player_count // 2,
                    total_capacity=player_count, runtime_clone=True, authored_max_players_per_team=3)
    return len(rows) == 1 and all(type(rows[0].get(k)) is type(v) and rows[0][k] == v for k, v in expected.items())


def client_command(godot: Path, repo: Path, player_count: int | None) -> list[str]:
    return [str(godot), *(["--headless"] if player_count in (10, 20) else []),
            "--path", str(repo), "--script", "res://tests/manual/live_gameplay_probe.gd"]


def load20_proof(clients: Sequence[ClientProcess], server_text: str, profile: str, player_count: int = 20) -> dict[str, object]:
    markers = owner_markers(clients, "OWNER_READY")
    ids = {row["owner"] for row in markers}
    rows = json_marker_rows(server_text, "owner_population=")
    active = [row for row in rows if row.get("workload_started") is True]
    one_oid = len({cp.parser.admitted_oid for cp in clients}) == 1 and all(cp.parser.admitted_oid for cp in clients)
    capacity = verified_capacity_readback(server_text, "server", player_count) and all(verified_capacity_readback(cp.log_path.read_text(errors="replace"), "client", player_count) for cp in clients)
    population = bool(active) and all(verified_owner_population(row, ids, player_count) for row in active)
    moving = authoritative_moving_owners(active, player_count) == ids and len(ids) == player_count
    hz = 30 if profile == "compare30" else 60
    clocks = []
    for cp in clients:
        matches = re.findall(r"\[PROFILE_CLIENT_CLOCK\] ticks=(\d+) elapsed_sec=([0-9.]+) achieved_hz=([0-9.]+)", cp.log_path.read_text(errors="replace"))
        if len(matches) == 1:
            ticks, elapsed, actual = matches[0]
            clocks.append(dict(index=cp.index, ticks=int(ticks), elapsed_sec=float(elapsed), achieved_hz=float(actual)))
    server_hz = [float(m[1]) for line in server_text.splitlines() if "owner_population=" in line and '"workload_started":true' in line.replace(" ", "") for m in [re.search(r"native_achieved_hz=([0-9.]+)", line)] if m]
    server_clock_ok = bool(server_hz) and all(hz * 0.9 <= value <= hz * 1.1 for value in server_hz)
    clock_ok = len(clocks) == player_count and all(c["ticks"] > 0 and c["elapsed_sec"] > 0 and abs(c["ticks"] / c["elapsed_sec"] - c["achieved_hz"]) < 0.02 and hz * 0.9 <= c["achieved_hz"] <= hz * 1.1 for c in clocks)
    return dict(requested_players=player_count, team_size=player_count // 2, ok=verified_owners(markers, player_count) and one_oid and capacity and population and moving and clock_ok and server_clock_ok,
                server_native_cadence=server_clock_ok, server_achieved_hz=server_hz,
                unique_authenticated_owners=verified_owners(markers, player_count), one_room_oid=one_oid,
                capacity_readback=capacity, authoritative_population=population,
                authoritative_movement=moving, moving_owner_count=len(authoritative_moving_owners(active, player_count)),
                client_native_cadence=clock_ok, client_clocks=clocks, owner_markers=markers,
                authoritative_intervals=active)


def parse_memory_free_percent(text: str) -> int:
    match = re.search(r"System-wide memory free percentage:\s*(\d+)%", text)
    if not match or not 0 <= int(match[1]) <= 100:
        raise RuntimeError("memory pressure query unavailable; refusing unguarded load20")
    return int(match[1])


def memory_free_percent() -> int:
    result = subprocess.run(["/usr/bin/memory_pressure", "-Q"], capture_output=True, text=True, timeout=5, check=True)
    return parse_memory_free_percent(result.stdout)


def guard_load20(free_percent: int, owned_rss_kib: int) -> None:
    if free_percent < 15 or owned_rss_kib > 8 * 1024 * 1024:
        raise RuntimeError("load20 resource guard: memory free/reclaimable below15% or owned process RSS above8GiB")


# Observation envelopes are numeric-only and bounded. Unknown fields fail closed.
OBSERVATION_KEYS = set("""schema index row unix_usec uptime_usec interval_usec phase process_frames physics_frames native_ticks
effective_process_hz effective_physics_hz effective_native_hz missing unknown
max_fps physics_hz native_hz network_loop_calls network_loop_usec_inclusive network_max_ticks_per_loop catchup_extra_native_ticks
rollback_loop_calls rollback_process_tick_callbacks rollback_loop_usec_inclusive native_interval_p95_ms native_interval_p99_ms
native_interval_dropped last_loop_monitors network_loop_ms rollback_loop_ms network_ticks rollback_ticks rollback_nodes players mobs activation
actor_load_calls actor_load_usec actor_load_max_usec entity_ready_calls entity_ready_usec entity_ready_max_usec population
start_unix_usec end_unix_usec duration_usec native_achieved_hz native_interval_samples population_start population_end population_samples
stride_start stride_end owners input_authorities connected_peers authenticated_accounts authenticated_peers lobby_players red blue
alive_players server_state_authorities positions live_mobs alive_mobs""".split())


def numeric_observation(value: object, depth: int = 0) -> bool:
    if depth > 6:
        return False
    if value is None or type(value) is bool:
        return True
    if type(value) in (int, float):
        return math.isfinite(value)
    if isinstance(value, list):
        return len(value) <= 64 and all(numeric_observation(v, depth + 1) for v in value)
    if isinstance(value, dict):
        return len(value) <= 64 and all(isinstance(k, str) and (k in OBSERVATION_KEYS or k.isdecimal())
            and numeric_observation(v, depth + 1) for k, v in value.items())
    return False


def safe_observation_rows(text: str, marker: str, limit: int = 180) -> list[dict[str, object]]:
    return [row for row in json_marker_rows(text, marker)
            if type(row.get("schema")) is int and row.get("schema") == 1 and numeric_observation(row)][:limit]


def timed_ps_sample(pid: int) -> dict[str, object] | None:
    begin = time.time_ns() // 1000
    value = ps_sample(pid)
    end = time.time_ns() // 1000
    if value is None:
        return None
    return dict(unix_usec=(begin + end) // 2, read_begin_unix_usec=begin,
                read_end_unix_usec=end, cpu_seconds=value[0], rss_kib=value[1])


def interpolate_cpu_boundary(rows: list[dict[str, object]], boundary: int) -> dict[str, object] | None:
    ordered = sorted(rows, key=lambda r: r["unix_usec"])
    for left, right in zip(ordered, ordered[1:]):
        a, b = left["unix_usec"], right["unix_usec"]
        if a <= boundary <= b:
            gap = (b - a) / 1_000_000.0
            c0, c1 = left["cpu_seconds"], right["cpu_seconds"]
            if gap <= 0 or gap > 2.5 or c1 < c0 or not all(math.isfinite(x) for x in (c0, c1)):
                return None
            ratio = (boundary - a) / (b - a)
            return dict(cpu_seconds=c0 + (c1 - c0) * ratio, bracket_seconds=gap,
                        left_offset_seconds=(boundary-a)/1_000_000.0,
                        right_offset_seconds=(b-boundary)/1_000_000.0,
                        max_read_duration_seconds=max(right["read_end_unix_usec"]-right["read_begin_unix_usec"],
                            left["read_end_unix_usec"]-left["read_begin_unix_usec"])/1_000_000.0)
    return None


def build_consecutive_windows(server_text: str, timed_rows: list[dict[str, object]], profile: str, player_count: int = 20,
                             window_count: int = 3, window_seconds: int = 30) -> dict[str, object]:
    if (type(player_count) is not int or type(window_count) is not int or type(window_seconds) is not int
            or (player_count, window_count, window_seconds) not in ((20, 3, 30), (10, 1, 30))):
        raise ValueError("unsupported measured-window plan")
    raw = safe_observation_rows(server_text, "[PROFILE_SERVER_WINDOW] ", window_count + 1)
    windows = []
    previous_end = None
    expected_hz = 30 if profile == "compare30" else 60
    for index, row in enumerate(raw[:window_count]):
        start, end, duration = row.get("start_unix_usec"), row.get("end_unix_usec"), row.get("duration_usec")
        valid_time = all(type(v) is int and v > 0 for v in (start, end, duration))
        if not valid_time:
            windows.append(dict(index=index, ok=False, cpu_percent_one_core=None, rss_median_kib=None,
                                rss_max_kib=None, unavailable_reason="invalid/missing server boundaries"))
            continue
        seconds = duration / 1_000_000.0
        wall_seconds = (end-start) / 1_000_000.0
        start_cpu = interpolate_cpu_boundary(timed_rows, start)
        end_cpu = interpolate_cpu_boundary(timed_rows, end)
        cpu = None
        if start_cpu is not None and end_cpu is not None and seconds > 0:
            delta = end_cpu["cpu_seconds"] - start_cpu["cpu_seconds"]
            if delta >= 0:
                cpu = delta / seconds * 100.0
        rss = [r["rss_kib"] for r in timed_rows if start <= r["unix_usec"] <= end]
        populations = [row.get("population_start", {})] + row.get("population_samples", []) + [row.get("population_end", {})]
        owners = set(populations[0].get("owners", []))
        population_ok = len(populations) >= 3 and all(verified_owner_population(p, owners, player_count) for p in populations)
        movement = authoritative_moving_owners(populations, player_count) if population_ok else set()
        stride_ok = row.get("stride_start") == {"1": 20} and row.get("stride_end") == {"1": 20}
        ticks = row.get("native_ticks")
        native_hz = ticks / seconds if type(ticks) is int and ticks > 0 and seconds > 0 else None
        cadence_ok = native_hz is not None and expected_hz * .9 <= native_hz <= expected_hz * 1.1
        consecutive = type(row.get("index")) is int and row.get("index") == index and (previous_end is None or start == previous_end)
        wall_clock_ok = abs(wall_seconds-seconds) <= .25
        valid_duration = window_seconds <= seconds <= window_seconds + 1.0
        ok = (cpu is not None and bool(rss) and population_ok and len(movement) == player_count and stride_ok
              and cadence_ok and consecutive and wall_clock_ok and valid_duration and type(row.get("native_interval_dropped")) is int and row.get("native_interval_dropped") == 0)
        windows.append(dict(index=index, ok=ok, start_unix_usec=start, end_unix_usec=end,
            actual_duration_seconds=seconds, cpu_percent_one_core=round(cpu, 3) if cpu is not None else None,
            cpu_source="cumulative ps TIME deltas, linearly interpolated to measured native-window boundaries",
            cpu_boundary_readbacks=dict(start=start_cpu, end=end_cpu),
            rss_median_kib=statistics.median(rss) if rss else None, rss_max_kib=max(rss) if rss else None,
            rss_sample_count=len(rss), native_ticks=ticks, native_achieved_hz=native_hz,
            native_interval_p95_ms=row.get("native_interval_p95_ms"), native_interval_p99_ms=row.get("native_interval_p99_ms"),
            native_interval_samples=row.get("native_interval_samples"), native_interval_dropped=row.get("native_interval_dropped"),
            population_samples=len(populations), all_population_samples_verified=population_ok,
            authoritative_moving_owner_count=len(movement), stride_verified=stride_ok,
            native_cadence_envelope_verified=cadence_ok, consecutive_boundary_verified=consecutive,
            wall_clock_consistent=wall_clock_ok, unavailable_reason=None if cpu is not None and rss else "missing bracketing CPU/RSS samples"))
        previous_end = end
    return dict(requested_windows=window_count, requested_window_seconds=window_seconds, windows=windows,
                ok=len(raw) == window_count and len(windows) == window_count and all(w["ok"] for w in windows),
                limits=["single short REAL10 window, not REAL20/three-window parity" if window_count == 1 else "three consecutive windows from one cohort, not independent runs",
                        "CPU boundary interpolation is an estimator; read durations/brackets are explicit",
                        "callback cadence is not packet cadence or exclusive tick CPU",
                        "90%-110% native envelope is not exact cadence parity"])


def observation_artifact(clients: Sequence[ClientProcess], client_cpu_rows: list[dict[str, object]],
                         server_text: str) -> dict[str, object]:
    return dict(client_rows={str(cp.index): safe_observation_rows(cp.log_path.read_text(errors="replace"),
                "[PROFILE_CLIENT_OBSERVATION] ") if cp.log_path.exists() else [] for cp in clients},
                client_process_samples=client_cpu_rows,
                server_rows=safe_observation_rows(server_text, "[PROFILE_SERVER_OBSERVATION] "),
                server_windows=safe_observation_rows(server_text, "[PROFILE_SERVER_WINDOW] ", 3),
                limits=["numeric sanitized rows capped at180 per client; process samples capped at180 rounds",
                        "inclusive network/rollback/activation wall times overlap, not additive CPU attribution",
                        "last-loop monitors are snapshots, not interval sums; null means unavailable"])


def comparison_manifest(repo: Path, args: argparse.Namespace, noray_log: Path,
                        clients: list[ClientProcess], server_parsers: dict[int, ServerLogParser]) -> dict[str, object]:
    server = profile_readbacks(noray_log.read_text(errors="replace"))
    client = [profile_readbacks(cp.log_path.read_text(errors="replace")) for cp in clients]
    sources = ["project.godot", "common/benchmark_profile.gd", "tools/benchmark_profiles.json",
               "common/game_manager.gd", "common/match_manager.gd", "common/match_director.gd", "common/perf_probe.gd",
               "common/benchmark_observer.gd", "common/BaseEntity.gd",
               "tests/manual/live_gameplay_probe.gd", "common/resources/default_match_rules.tres",
               "tests/manual/profile_room_scaling.py", "core/LogicComponent.gd",
               "addons/netfox/plugin.cfg", "addons/netfox/network-time.gd",
               "addons/netfox/rollback/network-rollback.gd", "addons/netfox/rollback/rollback-synchronizer.gd",
               "scenes/BaseEntity.tscn", "scenes/EnemyEntity.tscn", "scenes/main.tscn"]
    digest = {p: hashlib.sha256((repo / p).read_bytes()).hexdigest() for p in sources}
    engine = subprocess.run([str(args.godot), "--version"], capture_output=True, text=True, timeout=10, check=True)
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True)
    cadence = {str(pid): [line for line in parser.perf_lines if "native_ticks=" in line]
               for pid, parser in server_parsers.items()}
    plugin = (repo / "addons/netfox/plugin.cfg").read_text()
    version = re.search(r'version="([^"]+)"', plugin)
    return {"profile": args.netfox_profile, "godot_version": engine.stdout.strip(),
            "netfox_version": version.group(1) if version else "unknown",
            "source_revision": revision.stdout.strip(), "source_sha256": digest,
            "cpu_units": "percent of one core (100% = one core)", "rss_units": "KiB",
            "requested_players": args.player_count or args.rooms, "requested_mobs": args.mob_count,
            "client_presentation": "headless-full-game" if args.player_count == 20 else "rendered",
            "sampling_shape": "three consecutive30s windows" if args.sample_windows == 3 else "one aggregate window, not three repeated windows",
            "client_observation_enabled": args.observe_clients,
            "server_readback": server, "client_readback": client, "cadence_intervals": cadence,
            "client_phase_trace": [safe_phase_trace(cp.log_path.read_text(errors="replace")) for cp in clients],
            "readback_verified": verify_profile_readback(server, args.netfox_profile, "server")
                and len(client) == len(clients) and bool(client)
                and all(verify_profile_readback(rows, args.netfox_profile, "client") for rows in client)
                and bool(cadence) and all(cadence.values())
                and (args.player_count != 20 or (all(row.get("player_limit") == 20 and row.get("headless_client") is False for row in server)
                    and all(row.get("player_limit") == 20 and row.get("headless_client") is True and row.get("display_server") == "headless" for rows in client for row in rows))),
            "limits": ["local host, not VPS capacity", "no FishNet queue/stale-input equivalence",
                       "ordinary room limit six; load20 only explicit runtime clone", "cadence intervals include warmup; not aligned CPU proof"]}


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rooms", type=int, default=1, choices=[1, 2, 3])
    parser.add_argument(
        "--player-count",
        type=int,
        default=None,
        choices=[1, 2, 4, 8, 20],
        help="launch one hosted room with this many automated clients; defaults to 0 mobs unless --mob-count 20 is supplied",
    )
    parser.add_argument("--human", action="store_true")
    parser.add_argument("--deadline-seconds", type=int, default=None)
    parser.add_argument(
        "--lobby-hold-seconds", type=finite_nonnegative_float, default=0.0
    )
    parser.add_argument("--netfox-profile", choices=["compare30", "compare60"], default=None)
    parser.add_argument("--npc-rate-hz", type=int, default=None, choices=[60, 30, 15, 10])
    parser.add_argument("--mob-count", type=int, default=None, choices=[0, 1, 20])
    parser.add_argument(
        "--benchmark",
        choices=sorted(BENCHMARK_SCENARIOS),
        default=None,
        help="connected server benchmark scenario; valid Noray/client-probe selections are D, E, and F",
    )
    parser.add_argument("--warmup-seconds", type=finite_nonnegative_float, default=0.0)
    parser.add_argument("--sample-seconds", type=finite_nonnegative_float, default=0.0)
    parser.add_argument("--sample-windows", type=int, choices=[1, 3], default=1,
                        help="3 requires REAL20 comparison, warmup10s and sample-seconds30 per window")
    parser.add_argument("--observe-clients", action="store_true",
                        help="bounded numeric1Hz client clocks/rollback/activation diagnostics; REAL20 only")
    parser.add_argument("--preparation-timeout-seconds", type=int, choices=[5, 15], default=5,
                        help="probe IN_GAME observation allowance only;15s requires explicit REAL20")
    parser.add_argument("--dedupe-phase-trace", action="store_true")
    parser.add_argument("--keep-artifacts", action="store_true")
    parser.add_argument("--noray-root", type=Path, default=None)
    parser.add_argument(
        "--godot",
        type=Path,
        default=Path("/Applications/Godot.app/Contents/MacOS/Godot"),
    )
    args = parser.parse_args(argv)
    if (args.preparation_timeout_seconds != 5 or args.dedupe_phase_trace) and (not args.netfox_profile or args.player_count != 20 or args.mob_count != 20):
        parser.error("preparation override/trace dedupe require explicit REAL20 comparison and mob20")
    if args.sample_windows == 3:
        if not args.netfox_profile or args.player_count != 20 or args.mob_count != 20 or args.warmup_seconds != 10 or args.sample_seconds != 30:
            parser.error("three windows require REAL20 comparison with mob20, warmup10 and sample-seconds30")
        args.sample_seconds = 90.0
    if args.observe_clients and (not args.netfox_profile or args.player_count != 20 or args.mob_count != 20):
        parser.error("client observations require explicit REAL20 comparison and mob20")
    if args.netfox_profile:
        if args.rooms != 1:
            parser.error("comparison profiles use one room; do not conflate room scaling with tickrate")
        profile_rate = 30 if args.netfox_profile == "compare30" else 60
        if args.npc_rate_hz not in (None, profile_rate):
            parser.error("--netfox-profile requires NPC snapshots at the selected network rate")
        args.npc_rate_hz = profile_rate
        if args.human or args.warmup_seconds <= 0 or args.sample_seconds < 10:
            parser.error("comparison profiles require automated positive warmup and >=10s sample")
        if args.player_count == 8:
            parser.error("current game rules cap rooms at six players; eight is not comparable")
    else:
        args.npc_rate_hz = args.npc_rate_hz or 30
        if args.npc_rate_hz == 60:
            parser.error("60Hz NPC snapshots require --netfox-profile compare60")
    if args.player_count == 20 and (not args.netfox_profile or args.mob_count != 20):
        parser.error("twenty real clients require --netfox-profile compare30/compare60 and --mob-count 20")
    if args.player_count == 8:
        parser.error("eight is unsupported by the ordinary six-player rules; use explicit load20 comparison")
    if args.deadline_seconds is None:
        args.deadline_seconds = 1800 if args.human else 180
    if args.player_count is not None:
        if args.rooms != 1:
            parser.error(
                "--player-count uses one hosted room; do not combine it with --rooms"
            )
        if args.human:
            parser.error("--player-count is incompatible with --human")
        if args.benchmark is not None:
            parser.error(
                "--player-count is a connected scaling mode; do not combine it with --benchmark"
            )
        if args.mob_count not in (None, 0, 20):
            parser.error(
                "--player-count supports --mob-count 0 or 20 when --mob-count is supplied"
            )
        if args.warmup_seconds <= 0.0 or args.sample_seconds <= 0.0:
            parser.error("--player-count requires positive warmup and sample windows")
        if args.mob_count is None:
            args.mob_count = 0
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
    netfox_profile: str | None = None,
    player_count: int | None = None,
    start_file: Path | None = None,
    sample_windows: int = 1,
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
    if netfox_profile:
        env["NOIKAR_NETFOX_PROFILE"] = netfox_profile
        env["NOIKAR_SERVER_MAX_FPS"] = "75"
    if player_count == 20:
        env["NOIKAR_BENCHMARK_PLAYER_LIMIT"] = "20"
        if start_file is not None:
            env["NOIKAR_PROFILE_START_FILE"] = str(start_file)
    if mob_count is not None:
        env["NOIKAR_PROFILE_FIXED_POPULATION"] = "1"
        env["NOIKAR_PROFILE_MOB_COUNT"] = str(mob_count)
    if sample_windows == 3:
        env["NOIKAR_PROFILE_WINDOW_COUNT"] = "3"
        env["NOIKAR_PROFILE_WARMUP_SEC"] = "10.0"
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
    player_count: int | None = None,
    player_index: int | None = None,
    room_oid: str | None = None,
    release_file: Path | None = None,
    netfox_profile: str | None = None,
    selection_file: Path | None = None,
    start_file: Path | None = None,
    observe_clients: bool = False,
    preparation_timeout_seconds: int = 5,
    dedupe_phase_trace: bool = False,
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
    if netfox_profile:
        env["NOIKAR_NETFOX_PROFILE"] = netfox_profile
        env["NOIKAR_PROFILE_PHASE_TRACE"] = "1"
    if player_count in (10, 20):
        env["NOIKAR_BENCHMARK_PLAYER_LIMIT"] = str(player_count)
        env["NOIKAR_BENCHMARK_CLIENT"] = "1"
        if selection_file is not None:
            env["NOIKAR_PROFILE_SELECTION_FILE"] = str(selection_file)
        if start_file is not None:
            env["NOIKAR_PROFILE_START_FILE"] = str(start_file)
    if preparation_timeout_seconds not in (5, 15) or (preparation_timeout_seconds == 15 and player_count not in (10, 20)):
        raise ValueError("unsupported preparation timeout")
    if preparation_timeout_seconds != 5:
        env["NOIKAR_PROFILE_PREPARATION_SEC"] = str(preparation_timeout_seconds)
    if dedupe_phase_trace:
        if player_count not in (10, 20) or not netfox_profile:
            raise ValueError("trace dedupe requires explicit REAL10/REAL20 comparison")
        env["NOIKAR_PROFILE_PHASE_TRACE_DEDUPE"] = "1"
    if observe_clients:
        env["NOIKAR_PROFILE_CLIENT_OBSERVE"] = "1"
    if human:
        env["NOIKAR_PROFILE_HUMAN"] = "1"
    if mob_count is not None:
        env["NOIKAR_PROFILE_EXPECTED_MOB_COUNT"] = str(mob_count)
        env["NOIKAR_PROFILE_FIXED_ROUTE"] = "1"
    if player_count is not None:
        env["NOIKAR_PROFILE_PLAYER_COUNT"] = str(player_count)
    if player_index is not None:
        env["NOIKAR_PROFILE_PLAYER_INDEX"] = str(player_index)
    if room_oid:
        env["NOIKAR_PROFILE_JOIN_OID"] = room_oid
    if release_file is not None:
        env["NOIKAR_PROFILE_RELEASE_FILE"] = str(release_file)
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
    expected_clients: int | None = None,
) -> StableGate:
    stable_wall = 0.0 if stable_started is None else max(0.0, now - stable_started)
    expected_pids = set(active_pids) if pinned_pids is None else set(pinned_pids)
    exact_server_count = len(active_pids) == rooms and set(active_pids) == expected_pids
    required_clients = rooms if expected_clients is None else expected_clients
    clients_ready = len(clients) == required_clients and all(
        cp.parser.ready for cp in clients
    )
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
    release_file = tmp / "release-clients"
    selection_file = tmp / "selection-ready"
    start_file = tmp / "start-workload"
    resource_rows: list[dict[str, object]] = []
    client_cpu_rows: list[dict[str, object]] = []
    timed_server_rows: dict[int, list[dict[str, object]]] = {}
    load20_active_server_text: str | None = None
    generator_samples: dict[int, tuple[float, float]] = {}
    generator_overload_intervals = 0
    success = False
    run_started = time.monotonic()
    deadline = run_started + args.deadline_seconds
    stop_request = StopRequest()
    handler_context = install_stop_handlers(stop_request)
    handler_context.__enter__()
    if args.human:
        print(f"Human mode deadline: {args.deadline_seconds}s", flush=True)
    try:
        if args.player_count == 20:
            guard_load20(memory_free_percent(), 0)
        suffix = secrets.token_hex(6)
        container = f"noikar-profile-pg-{suffix}"
        volume = f"noikar-profile-pgdata-{suffix}"
        cleanup.container = container
        cleanup.volume = volume
        spec = postgres_spec(container, volume)
        subprocess.run(spec.command, check=True, timeout=min(45, max(1, deadline - time.monotonic())))
        wait_pg(container, min(deadline, time.monotonic() + 45))

        jwt_secret = secrets.token_urlsafe(32)
        provisioner = secrets.token_urlsafe(32)
        secrets_to_redact.extend([jwt_secret, provisioner])
        backend_log = tmp / "backend.log"
        database_url = "postgres://postgres@127.0.0.1:15432/postgres?sslmode=disable"
        backend_env = complete_env(
            {
                "DATABASE_URL": database_url,
                "PORT": "18090",
                "BIND_HOST": "127.0.0.1",
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
        wait_http("http://127.0.0.1:18090/api/v1/health", min(deadline, time.monotonic() + 60))

        expected_clients = args.player_count or args.rooms
        accounts = generate_accounts(expected_clients)
        secrets_to_redact.extend(a.password for a in accounts)
        for account in accounts:
            if time.monotonic() >= deadline or stop_request.requested:
                raise RuntimeError("whole-arm deadline/stop during account registration")
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
                benchmark=args.benchmark,
                netfox_profile=args.netfox_profile,
                player_count=args.player_count,
                start_file=start_file, sample_windows=args.sample_windows,
            ),
            log_path=noray_log,
            cleanup=cleanup,
        )

        wait_listener("127.0.0.1", 8890, min(deadline, time.monotonic() + 45), "Noray")

        def launch_client(
            i: int, account: Account, room_oid: str | None = None
        ) -> None:
            client_log = tmp / f"client-{i}.log"
            client_env = client_probe_env(
                account=account,
                lobby_hold_seconds=args.lobby_hold_seconds,
                warmup_seconds=args.warmup_seconds,
                sample_seconds=args.sample_seconds,
                human=args.human,
                mob_count=args.mob_count,
                player_count=args.player_count,
                player_index=i if args.player_count is not None else None,
                room_oid=room_oid,
                release_file=release_file,
                netfox_profile=args.netfox_profile,
                selection_file=selection_file, start_file=start_file, observe_clients=args.observe_clients,
                preparation_timeout_seconds=args.preparation_timeout_seconds, dedupe_phase_trace=args.dedupe_phase_trace,
            )

            proc = start_process(
                client_command(args.godot, repo, args.player_count),
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

        if args.player_count is None:
            for i, account in enumerate(accounts):
                launch_client(i, account)
        else:
            launch_client(0, accounts[0])
            oid_deadline = min(deadline, time.monotonic() + min(
                60.0, max(10.0, args.deadline_seconds / 3.0)
            ))
            while time.monotonic() < oid_deadline:
                host = clients[0]
                if host.log_path.exists():
                    host.parser.feed(host.log_path.read_text(errors="replace"))
                if host.parser.admitted_oid:
                    break
                if host.process.poll() is not None:
                    raise RuntimeError("host client exited before publishing room OID")
                time.sleep(0.5)
            if not clients[0].parser.admitted_oid:
                raise RuntimeError("timed out waiting for host room OID")
            for i, account in enumerate(accounts[1:], start=1):
                if time.monotonic() >= deadline or stop_request.requested:
                    raise RuntimeError("whole-arm deadline/stop during client ramp")
                if args.player_count == 20:
                    rows = read_process_rows()
                    guard_load20(memory_free_percent(), sum(row.rss_kb for row in rows if row.pid in descendants(rows, {noray_proc.pid}) | {cp.process.pid for cp in clients}))
                launch_client(i, account, clients[0].parser.admitted_oid)
                if args.player_count == 20:
                    time.sleep(0.25)

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

        def refresh_noray_log(*, teardown_only: bool) -> None:
            nonlocal last_noray_size
            last_noray_size = route_incremental_noray_log(
                noray_log,
                last_noray_size,
                combined_parser,
                server_parsers,
                teardown_only=teardown_only,
            )

        while time.monotonic() < deadline and not stop_request.requested:
            now = time.monotonic()
            rows = read_process_rows()
            server_pids = filter_owned_server_pids(rows, {noray_proc.pid}, repo)
            cleanup.server_pids.update(server_pids)
            for pid in server_pids:
                server_parsers.setdefault(pid, ServerLogParser(args.mob_count))
            refresh_client_logs(now)
            fixed_workload_closed = update_fixed_workload_closed(
                fixed_workload_closed, clients, args.mob_count
            )
            refresh_noray_log(teardown_only=fixed_workload_closed)
            if args.player_count == 20 and fixed_workload_closed and load20_active_server_text is None:
                load20_active_server_text = noray_log.read_text(errors="replace")
            if args.player_count == 20:
                owned = descendants(rows, {proc.pid for proc in cleanup.processes}) | {proc.pid for proc in cleanup.processes}
                free = memory_free_percent()
                rss = sum(row.rss_kb for row in rows if row.pid in owned)
                resource_rows.append(dict(elapsed_seconds=round(now-run_started, 3), free_reclaimable_percent=free, owned_rss_kib=rss))
                guard_load20(free, rss)
                generator_cpu = 0.0
                measured_clients = 0
                for cp in clients:
                    reading = timed_ps_sample(cp.process.pid)
                    value = (reading["cpu_seconds"], reading["rss_kib"]) if reading is not None else None
                    previous = generator_samples.get(cp.process.pid)
                    if len(client_cpu_rows) < 180*20:
                        individual_cpu = cpu_percent_delta(previous[1], value[0], now-previous[0]) if value is not None and previous is not None else None
                        client_cpu_rows.append(dict(index=cp.index, pid=cp.process.pid,
                            supervisor_monotonic=now, sample=reading, cpu_percent_one_core=individual_cpu))
                    if value is None:
                        continue
                    if previous is not None:
                        generator_cpu += cpu_percent_delta(previous[1], value[0], now - previous[0])
                        measured_clients += 1
                    generator_samples[cp.process.pid] = (now, value[0])
                resource_rows[-1]["generator_cpu_percent_one_core"] = round(generator_cpu, 2) if measured_clients == 20 else None
                resource_rows[-1]["host_load_average_1m"] = os.getloadavg()[0]
                saturated = measured_clients == 20 and generator_cpu >= (os.cpu_count() or 1) * 85.0
                generator_overload_intervals = generator_overload_intervals + 1 if saturated else 0
                if generator_overload_intervals >= 3:
                    raise RuntimeError("load20 generator CPU guard: >=85% logical-core capacity for3 intervals")
                if any(cp.process.poll() is not None and not cp.parser.passed for cp in clients):
                    raise RuntimeError("load20 client failed before workload completion")
                if not selection_file.exists() and verified_twenty_owners(owner_markers(clients, "SELECTION_PREPARED")):
                    if not all(cp.parser.admitted_oid == clients[0].parser.admitted_oid for cp in clients):
                        raise RuntimeError("load20 clients admitted to different rooms")
                    selection_file.write_text("ordinary selection ready\n", encoding="utf-8")
            if (
                clients
                and all(cp.parser.passed for cp in clients)
                and not release_file.exists()
            ):
                release_file.write_text("release\n", encoding="utf-8")
            if (
                pinned_pids is None
                and len(server_pids) == args.rooms
                and len(clients) == expected_clients
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
                if args.player_count == 20:
                    text = noray_log.read_text(errors="replace")
                    markers = owner_markers(clients, "OWNER_READY")
                    population = json_marker_rows(text, "owner_population=")
                    if not verified_twenty_owners(markers) or not population or not verified_owner_population(population[-1], {m["owner"] for m in markers}):
                        time.sleep(0.25)
                        continue
                    if not verified_capacity_readback(text, "server") or not all(verified_capacity_readback(cp.log_path.read_text(errors="replace"), "client") for cp in clients):
                        raise RuntimeError("load20 capacity readback mismatch")
                    start_file.write_text("ordinary workload intentions\n", encoding="utf-8")
                pinned_pids = set(server_pids)
                stable_started = now
                samples = {pid: [] for pid in pinned_pids}
            if pinned_pids is not None:
                if args.player_count == 20 and now >= stable_started + args.warmup_seconds and not fixed_workload_closed:
                    active_owners = [row for row in json_marker_rows(noray_log.read_text(errors="replace"), "owner_population=") if row.get("workload_started") is True]
                    ready_baseline = [row for row in json_marker_rows(noray_log.read_text(errors="replace"), "owner_population=") if row.get("workload_started") is not True and verified_owner_population(row)]
                    if len(authoritative_moving_owners(ready_baseline[-1:] + active_owners)) != 20:
                        raise RuntimeError("load20 lacks20 moving authoritative owners before CPU sample")
                for pid in sorted(pinned_pids):
                    if pid in server_pids and not fixed_workload_closed:
                        timed_sample = timed_ps_sample(pid)
                        sample = (timed_sample["cpu_seconds"], timed_sample["rss_kib"]) if timed_sample is not None else None
                        sample_time = time.monotonic()
                        if sample:
                            if args.mob_count is not None:
                                refresh_client_logs(time.monotonic())
                                if fixed_workload_completion_seen(clients) or any(
                                    cp.process.poll() is not None for cp in clients
                                ):
                                    active_end_rows_discarded += 1
                                    fixed_workload_closed = True
                                    refresh_noray_log(teardown_only=True)
                                    continue
                            samples.setdefault(pid, []).append(
                                (sample_time, sample[0], sample[1])
                            )
                            timed_server_rows.setdefault(pid, []).append(timed_sample)
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
        refresh_noray_log(teardown_only=fixed_workload_closed)

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
                expected_clients=expected_clients,
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
            expected_clients=expected_clients,
        )
        if not gate.ok and legacy_mode:
            raise RuntimeError(f"stable sampling gate failed: {gate}")
        functional = all(
            cp.process.returncode == 0 and cp.parser.passed and cp.parser.metrics
            for cp in clients
        )
        comparison = None
        verified_native_hz = None
        if args.netfox_profile:
            comparison = comparison_manifest(repo, args, noray_log, clients, server_parsers)
            if comparison["readback_verified"]:
                verified_native_hz = int(comparison["server_readback"][0]["network_hz"])
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
            player_count=args.player_count,
            netfox_profile=args.netfox_profile,
            verified_native_hz=verified_native_hz,
        )

        if args.player_count == 20:
            result["load20"] = load20_proof(clients, load20_active_server_text or noray_log.read_text(errors="replace"), args.netfox_profile)
            result["resource_guard"] = dict(minimum_free_reclaimable_percent=min(row["free_reclaimable_percent"] for row in resource_rows),
                                           peak_owned_rss_kib=max(row["owned_rss_kib"] for row in resource_rows),
                                           free_floor_percent=15, owned_rss_ceiling_kib=8*1024*1024, samples=resource_rows)
            result["gate"]["real20_one_room_10v10"] = result["load20"]["ok"]
            functional = functional and result["load20"]["ok"]
        if args.observe_clients or args.sample_windows == 3:
            result["observation"] = observation_artifact(clients, client_cpu_rows, load20_active_server_text or noray_log.read_text(errors="replace"))
        if args.sample_windows == 3:
            result["consecutive_windows"] = build_consecutive_windows(load20_active_server_text or noray_log.read_text(errors="replace"),
                timed_server_rows.get(next(iter(pinned_pids)), []) if pinned_pids and len(pinned_pids) == 1 else [], args.netfox_profile)
            result["gate"]["three_consecutive_windows"] = result["consecutive_windows"]["ok"]
            functional = functional and result["consecutive_windows"]["ok"]
        if args.netfox_profile:
            result["comparison"] = comparison
            if not result["comparison"]["readback_verified"]:
                raise RuntimeError("comparison profile readback missing or mismatched on server/clients")
            (tmp / "comparison.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
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
            and bool(result_gate["active_sample_errors"])
            and bool(result_gate["alive"])
            and bool(result_gate["mob_population_stable"])
            and bool(result_gate["movement"])
            and bool(result_gate["projectile"])
            and bool(result_gate["mob_movement"])
            and bool(result_gate["observed_near_npc"])
            and bool(result_gate["marker_verified"])
            and bool(result_gate["workload_valid"])
            and bool(result_gate["npc_stride_counts"])
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
        try:
            roots = {proc.pid for proc in cleanup.processes}
            rows = read_process_rows()
            cleanup.server_pids.update(filter_owned_server_pids(rows, roots, repo))
        except Exception:
            pass  # Process-group cleanup still covers attached Noray children.
        if args.observe_clients or args.sample_windows == 3:
            text = noray_log.read_text(errors="replace") if "noray_log" in locals() and noray_log.exists() else ""
            evidence = observation_artifact(clients, client_cpu_rows, load20_active_server_text or text)
            evidence["server_process_samples"] = {str(pid): rows for pid, rows in timed_server_rows.items()}
            if args.sample_windows == 3:
                evidence["consecutive_windows"] = build_consecutive_windows(load20_active_server_text or text,
                    next(iter(timed_server_rows.values())) if len(timed_server_rows) == 1 else [], args.netfox_profile)
            (tmp / "observation.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        if args.player_count == 20:
            (tmp / "load20-resource-guard.json").write_text(json.dumps(resource_rows, indent=2), encoding="utf-8")
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
    player_count: int | None = None,
    netfox_profile: str | None = None,
    verified_native_hz: int | None = None,
) -> dict[str, object]:
    profile = profile or ProfileWindow(stable_started=None)
    sample_start = (
        profile.stable_started + profile.requested_warmup_seconds
        if profile.stable_started is not None
        else None
    )
    per_room = []
    cpu_values = []
    cpu_interval_peaks = []
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
            cpu = None
            peak_cpu = None
            peak_resolution = None
            rss = None
        else:
            start_row, end_row = sample_rows[0], sample_rows[-1]
            duration = max(0.0, end_row[0] - start_row[0])
            sample_durations.append(duration)
            cpu = cpu_percent_delta(start_row[1], end_row[1], duration)
            peak_cpu, peak_resolution = cpu_interval_peak(sample_rows)
            rss = max(r[2] for r in sample_rows)
        if cpu is not None:
            cpu_values.append(cpu)
            cpu_interval_peaks.append(peak_cpu)
            rss_values.append(rss)
        parser = server_parsers.get(pid, ServerLogParser())
        per_room.append(
            {
                "pid": pid,
                "cpu_percent": round(cpu, 2) if cpu is not None else None,
                "cpu_interval_peak_percent": round(peak_cpu, 2) if peak_cpu is not None else None,
                "cpu_interval_sample_resolution_seconds": round(peak_resolution, 2) if peak_resolution is not None else None,
                "cpu_interval_peak_source": "adjacent ps CPU-time deltas over sampled rows",
                "rss_kb": rss,
                "sync_rpc_errors": parser.errors[:10],
                "teardown_rpc_errors": parser.teardown_errors[:10],
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
                "active_errors": parser_list_attr(cp.parser, "active_errors")[:10],
                "teardown_errors": parser_list_attr(cp.parser, "teardown_errors")[:10],
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
    active_server_error_count = (
        len(combined_parser.errors)
        if combined_parser.errors
        else sum(len(parser.errors) for parser in server_parsers.values())
    )
    teardown_server_error_count = (
        len(combined_parser.teardown_errors)
        if combined_parser.teardown_errors
        else sum(len(parser.teardown_errors) for parser in server_parsers.values())
    )
    active_error_count = (
        sum(len(parser_list_attr(cp.parser, "active_errors")) for cp in clients)
        + active_server_error_count
    )
    teardown_error_count = (
        sum(len(parser_list_attr(cp.parser, "teardown_errors")) for cp in clients)
        + teardown_server_error_count
    )
    stride_proof = npc_stride_proof(
        client_results,
        npc_rate_hz,
        mob_count,
        combined_parser.authoritative_stride_intervals,
        netfox_profile=netfox_profile,
        verified_native_hz=verified_native_hz,
    )
    population_markers = [
        dict(server_parsers[pid].population_marker, pid=pid)
        for pid in sorted(samples)
        if pid in server_parsers
    ]
    result = {
        "rooms_requested": rooms,
        "player_count": player_count if player_count is not None else len(clients),
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
        "npc_stride_observed": stride_proof,
        "active_sample_proof": {
            "fixed_workload_end_observed": fixed_workload_end_observed,
            "discarded_end_rows": profile.active_end_rows_discarded,
            "active_error_count": active_error_count,
            "teardown_error_count": teardown_error_count,
            "active_server_error_count": active_server_error_count,
            "teardown_server_error_count": teardown_server_error_count,
        },
        "clients": client_results,
        "gate": {
            "functional": all(
                c["passed"] and c["returncode"] == 0 for c in client_results
            ),
            "active_sample_errors": active_error_count == 0,
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
            "npc_stride_counts": bool(stride_proof["ok"]),
            "no_early_client_exit": gate.no_early_client_exit,
            "pass_count": sum(1 for c in client_results if c["passed"]),
        },
        "rooms": per_room,
        "combined_server_perf_probe": combined_parser.perf_lines[-20:],
        "npc_cost_intervals": combined_parser.npc_cost_intervals[-20:],
        "npc_authoritative_stride_intervals": combined_parser.authoritative_stride_intervals[
            -20:
        ],
        "combined_server_errors": combined_parser.errors[:20],
        "combined_server_teardown_errors": combined_parser.teardown_errors[:20],
        "aggregate": {
            "cpu_percent_total": round(sum(cpu_values), 2) if len(cpu_values) == rooms else None,
            "cpu_interval_peak_percent": round(max(cpu_interval_peaks), 2) if len(cpu_values) == rooms else None,
            "cpu_interval_peak_source": "max adjacent ps CPU-time delta across rooms",
            "rss_kb_total": sum(rss_values) if len(rss_values) == rooms else None,
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
    print(f"Players: {result.get('player_count')} rooms={result['rooms_requested']}")
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
