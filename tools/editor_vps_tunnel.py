#!/usr/bin/env python3
"""Keep one SSH tunnel alive only while its owning editor game process exists."""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time


def process_identity(pid):
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True, timeout=2)
    return result.stdout.strip() if result.returncode == 0 else ""


def run_for_parent(parent_pid, command, stop_file=None, cancelled=None):
    identity = process_identity(parent_pid)
    if not identity:
        return 1
    cancelled = cancelled or threading.Event()
    process = subprocess.Popen(command, start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    try:
        while process.poll() is None:
            if cancelled.is_set() or (stop_file is not None and stop_file.exists()) or process_identity(parent_pid) != identity:
                return 0
            time.sleep(0.15)
        return process.returncode
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=2)
        if stop_file is not None:
            stop_file.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parent", type=int, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--stop-file", type=Path, required=True)
    args = parser.parse_args()
    if args.parent <= 1 or not re.fullmatch(r"[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+", args.target):
        parser.error("Invalid owning game process or SSH target")
    cancelled = threading.Event()
    for signum in [signal.SIGTERM, signal.SIGINT]:
        signal.signal(signum, lambda *_args: cancelled.set())
    command = ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-N", "-L", "127.0.0.1:19091:127.0.0.1:18491", args.target]
    raise SystemExit(run_for_parent(args.parent, command, args.stop_file, cancelled))


if __name__ == "__main__":
    main()
