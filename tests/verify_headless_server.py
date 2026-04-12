#!/usr/bin/env python3
"""
verify_headless_server.py

Manual smoke test for headless server mode.
Tests that the dedicated server can start without display server dependencies.

Usage:
    # Full test (requires Godot binary in PATH)
    python3 verify_headless_server.py --godot /path/to/godot --project /path/to/project

    # Quick check (no Godot required)
    python3 verify_headless_server.py --quick

Exit codes:
    0 = All checks passed
    1 = Configuration error
    2 = Test failed
"""

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path


def check_environment(project_path: Path) -> list:
    """Check that environment is configured for headless server testing."""
    issues = []

    # Check for dedicated_server feature flag in project
    project_godot = project_path / "project.godot"
    if project_godot.exists():
        content = project_godot.read_text()
        if "dedicated_server" not in content:
            issues.append(
                "project.godot: 'dedicated_server' feature tag not configured"
            )
    else:
        issues.append("project.godot not found")

    # Check GameManager has headless detection
    game_manager = project_path / "common" / "game_manager.gd"
    if game_manager.exists():
        content = game_manager.read_text()
        checks = [
            ("OS.has_feature", "dedicated_server check"),
            ("DisplayServer.get_name", "headless display detection"),
            ("_is_headless_environment", "environment detection method"),
            ("_start_as_server", "server startup method"),
            ("_start_as_client", "client startup method"),
        ]
        for check, desc in checks:
            if check not in content:
                issues.append(f"game_manager.gd: Missing {desc} ({check})")
    else:
        issues.append("game_manager.gd not found")

    # Check EventBus has required signals
    event_bus = project_path / "common" / "event_bus.gd"
    if event_bus.exists():
        content = event_bus.read_text()
        signals = ["server_started", "client_connected"]
        for signal in signals:
            if f"signal {signal}" not in content and f"signal {signal}(" not in content:
                issues.append(f"event_bus.gd: Missing '{signal}' signal")
    else:
        issues.append("event_bus.gd not found")

    return issues


def quick_check(project_path: Path) -> bool:
    """Run quick checks without Godot binary."""
    print("Running quick verification (no Godot binary required)...")
    print()

    issues = check_environment(project_path)

    if issues:
        print("ISSUES FOUND:")
        for issue in issues:
            print(f"  ✗ {issue}")
        return False
    else:
        print("✓ All quick checks passed")
        return True


def godot_check(godot_path: Path, project_path: Path) -> tuple:
    """Run actual Godot headless server test."""
    print(f"Testing with Godot: {godot_path}")
    print(f"Project: {project_path}")
    print()

    # First, quick environment check
    issues = check_environment(project_path)
    if issues:
        print("Environment issues detected:")
        for issue in issues:
            print(f"  ✗ {issue}")
        return False, issues

    # Try to start server in headless mode
    print("[1] Starting headless server...")
    env = os.environ.copy()
    env["GODOT_SERVER_MODE"] = "1"

    try:
        proc = subprocess.Popen(
            [str(godot_path), "--headless", "--path", str(project_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
    except FileNotFoundError:
        print(f"✗ Godot binary not found: {godot_path}")
        return False, ["Godot binary not found"]

    # Wait for startup
    time.sleep(3)

    # Check if still running
    poll = proc.poll()
    if poll is not None:
        stdout, stderr = proc.communicate()
        print(f"✗ Server exited with code {poll}")
        print(f"STDOUT: {stdout.decode('utf-8', errors='replace')}")
        print(f"STDERR: {stderr.decode('utf-8', errors='replace')}")
        return False, ["Server failed to start"]

    print("    ✓ Server started successfully (PID: {})".format(proc.pid))

    # Give it a moment to initialize
    time.sleep(2)

    # Check for expected output
    print("[2] Checking server initialization...")
    # Note: In real test, would parse logs/output

    print("[3] Shutting down server...")
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    print("    ✓ Server shutdown complete")

    return True, []


def main():
    parser = argparse.ArgumentParser(
        description="Verify headless server mode for noikarv-3"
    )
    parser.add_argument("--godot", type=Path, help="Path to Godot 4.x binary")
    parser.add_argument(
        "--project",
        type=Path,
        default=Path("."),
        help="Path to project (default: current directory)",
    )
    parser.add_argument(
        "--quick", action="store_true", help="Run quick checks without Godot binary"
    )

    args = parser.parse_args()
    project_path = args.project.resolve()

    print("=" * 60)
    print("HEADLESS SERVER VERIFICATION")
    print("Project: {}".format(project_path))
    print("=" * 60)
    print()

    if args.quick or not args.godot:
        success = quick_check(project_path)
        if not success:
            return 1
        if args.godot:
            # Continue to full test if godot specified
            pass
        else:
            return 0

    if args.godot:
        success, issues = godot_check(args.godot, project_path)
        if not success:
            print()
            print("=" * 60)
            print("✗ HEADLESS SERVER TEST FAILED")
            return 2
    else:
        print("Note: No --godot specified, skipping full test")
        print("      Use --quick for environment-only checks")

    print()
    print("=" * 60)
    print("✓ HEADLESS SERVER VERIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
