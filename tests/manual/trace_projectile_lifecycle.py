#!/usr/bin/env python3
"""Projectile lifecycle diagnostic wrapper around profile_room_scaling.

This is a test-only harness. It preserves the profiler's pass/fail gates and only
adds bounded [PROJECTILE-TRACE] collection from the Noray-owned server log.
Trace results are diagnostics, not performance comparisons.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import stat
import sys
import tempfile
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import profile_room_scaling as prs  # noqa: E402

TRACE_SCRIPT = "res://tests/manual/trace_projectile_server.gd"
TRACE_PREFIX = "[PROJECTILE-TRACE]"
TRACE_RECORD_CAP = 256
ALLOWED_TRACE_FIELDS = {
    "stage",
    "tick",
    "phase",
    "player",
    "attack_count",
    "state",
    "timer",
    "charging",
    "slot",
    "primary_configured",
    "projectile_count",
    "node",
    "capped",
    "records",
    "server_spawns",
    "note",
}


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trials", type=int, default=1, choices=range(1, 5))
    args, profiler_args = parser.parse_known_args(argv)
    args.profiler_args = profiler_args
    return args


def _injected_server_args(args: Sequence[str]) -> list[str]:
    out = list(args)
    if "--server" not in out or TRACE_SCRIPT in out:
        return out
    insert_at = out.index("--") if "--" in out else len(out)
    out[insert_at:insert_at] = ["--script", TRACE_SCRIPT]
    return out


def create_godot_wrapper(directory: Path, real_godot: Path) -> Path:
    wrapper = directory / "godot-projectile-trace-wrapper.py"
    wrapper.write_text(
        "#!/usr/bin/env python3\n"
        "import os, sys\n"
        f"real = {str(real_godot)!r}\n"
        "args = sys.argv[1:]\n"
        f"trace = {TRACE_SCRIPT!r}\n"
        "if '--server' in args and trace not in args:\n"
        "    pos = args.index('--') if '--' in args else len(args)\n"
        "    args = args[:pos] + ['--script', trace] + args[pos:]\n"
        "os.execv(real, [real] + args)\n",
        encoding="utf-8",
    )
    wrapper.chmod(wrapper.stat().st_mode | stat.S_IXUSR)
    return wrapper


def trace_noray_env_factory(
    real: Callable[..., dict[str, str]], wrapper: Path
) -> Callable[..., dict[str, str]]:
    def traced_noray_env(*args: Any, **kwargs: Any) -> dict[str, str]:
        env = real(*args, **kwargs)
        env["GODOT_EXECUTABLE_PATH"] = str(wrapper)
        return env

    return traced_noray_env


def parse_trace_log(path: Path, cap: int = TRACE_RECORD_CAP) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    total = 0
    malformed = 0
    capped = False
    if not path.exists():
        return {"records": records, "total": 0, "capped": False, "malformed": 0}
    for line in path.read_text(errors="replace").splitlines():
        if TRACE_PREFIX not in line:
            continue
        payload = line.split(TRACE_PREFIX, 1)[1].strip()
        try:
            raw = json.loads(payload)
        except json.JSONDecodeError:
            malformed += 1
            continue
        if not isinstance(raw, dict):
            malformed += 1
            continue
        total += 1
        if len(records) >= cap:
            capped = True
            continue
        records.append({k: raw[k] for k in ALLOWED_TRACE_FIELDS if k in raw})
    return {
        "records": records,
        "total": total,
        "capped": capped,
        "malformed": malformed,
    }


class TraceCollector:
    def __init__(self) -> None:
        self.last: dict[str, Any] = {
            "records": [],
            "total": 0,
            "capped": False,
            "malformed": 0,
        }

    def collect(self, tmp: Path) -> dict[str, Any]:
        self.last = parse_trace_log(tmp / "noray.log")
        return self.last


def run_trial(profiler_args: Sequence[str]) -> int:
    collector = TraceCollector()
    with tempfile.TemporaryDirectory(prefix="noikar-projectile-trace-") as temp_s:
        temp = Path(temp_s)
        real_noray_env = prs.noray_env
        real_build_result = prs.build_result
        real_cleanup_run = prs.CleanupPlan.run
        wrapper_holder: dict[str, Path] = {}

        def traced_build_result(*args: Any, **kwargs: Any) -> dict[str, Any]:
            result = real_build_result(*args, **kwargs)
            tmp = args[6]
            result["diagnostic_projectile_trace"] = collector.collect(tmp)
            result["diagnostic_note"] = (
                "projectile trace only; not a performance comparison"
            )
            return result

        def traced_cleanup_run(cleanup: prs.CleanupPlan) -> None:
            if cleanup.temp_dir is not None:
                collector.collect(cleanup.temp_dir)
            return real_cleanup_run(cleanup)

        try:
            parsed = prs.parse_args(profiler_args)
            real_godot = parsed.godot
            if not real_godot.is_absolute():
                raise RuntimeError(
                    "--godot must resolve to an absolute executable path"
                )
            wrapper = create_godot_wrapper(temp, real_godot)
            wrapper_holder["path"] = wrapper
            prs.noray_env = trace_noray_env_factory(real_noray_env, wrapper)  # type: ignore[assignment]
            prs.build_result = traced_build_result  # type: ignore[assignment]
            prs.CleanupPlan.run = traced_cleanup_run  # type: ignore[assignment]
            return prs.run(profiler_args)
        finally:
            prs.noray_env = real_noray_env  # type: ignore[assignment]
            prs.build_result = real_build_result  # type: ignore[assignment]
            prs.CleanupPlan.run = real_cleanup_run  # type: ignore[assignment]
            wrapper = wrapper_holder.get("path")
            if wrapper is not None:
                with contextlib.suppress(OSError):
                    wrapper.unlink(missing_ok=True)
            print(
                json.dumps(
                    {"diagnostic_projectile_trace_final": collector.last},
                    sort_keys=True,
                )
            )


def run(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    for trial in range(1, args.trials + 1):
        print(f"Projectile trace trial {trial}/{args.trials}")
        code = run_trial(args.profiler_args)
        if code != 0:
            return code
    return 0


if __name__ == "__main__":
    sys.exit(run())
