#!/usr/bin/env python3
"""
verify_export_isolation.py

Verifies that server-only files (res://core/) are excluded from client exports
and client-only files (res://client/) are excluded from server exports.

This script checks the Godot export_presets.cfg for proper folder-based filters.

Usage:
    python verify_export_isolation.py [--project PATH]

Exit codes:
    0 = All checks passed
    1 = Configuration error or missing files
    2 = Isolation violation detected
"""

import argparse
import os
import re
import sys
from pathlib import Path


def parse_export_presets(presets_path: Path) -> dict:
    """Parse export_presets.cfg and extract filter configurations."""
    if not presets_path.exists():
        return {}

    presets = {}
    current_preset = None

    with open(presets_path, "r") as f:
        for line in f:
            line = line.strip()

            # Detect new preset section
            if line.startswith("[") and line.endswith("]"):
                preset_name = line[1:-1]
                current_preset = preset_name
                presets[preset_name] = {"include_folders": [], "exclude_folders": []}

            # Extract folder filters
            elif current_preset and "=" in line:
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()

                if "include_filter" in key:
                    presets[current_preset]["include_folders"].extend(
                        f.strip() for f in value.split(",") if f.strip()
                    )
                elif "exclude_filter" in key:
                    presets[current_preset]["exclude_folders"].extend(
                        f.strip() for f in value.split(",") if f.strip()
                    )

    return presets


def check_folder_isolation(project_root: Path) -> list:
    """
    Check that folder structure follows server/client isolation.

    Returns list of violations.
    """
    violations = []

    # Check that core/ only contains server logic
    core_path = project_root / "core"
    if core_path.exists():
        for item in core_path.iterdir():
            if item.is_file() and item.suffix in [".gd", ".cs"]:
                # Check for client-only indicators
                if "Visual" in item.name or "Client" in item.name or "HUD" in item.name:
                    violations.append(
                        f"CORE LEAKAGE: {item} contains client-only naming"
                    )

    # Check that client/ only contains client logic
    client_path = project_root / "client"
    if client_path.exists():
        for item in client_path.iterdir():
            if item.is_file() and item.suffix in [".gd", ".cs"]:
                # Check for server-only indicators
                if "Logic" in item.name or "Server" in item.name or "AI" in item.name:
                    violations.append(
                        f"CLIENT LEAKAGE: {item} contains server-only naming"
                    )

    # Verify common/ folder doesn't import from core or client specifically
    common_path = project_root / "common"
    if common_path.exists():
        for item in common_path.rglob("*.gd"):
            try:
                content = item.read_text()
                # These imports would indicate tight coupling
                if "res://core/" in content or "res://client/" in content:
                    # Some imports are OK (like registering autoloads)
                    if "LogicComponent" in content or "VisualComponent" in content:
                        violations.append(
                            f"COMMON COUPLING: {item} imports from core/client folders"
                        )
            except Exception:
                pass

    return violations


def verify_export_presets(project_root: Path) -> list:
    """
    Verify that export_presets.cfg has proper filters for isolation.

    Returns list of issues.
    """
    issues = []

    presets_path = project_root / "export_presets.cfg"

    if not presets_path.exists():
        issues.append(
            "MISSING: export_presets.cfg not found - client/server export filtering not configured"
        )
        return issues

    presets = parse_export_presets(presets_path)

    if not presets:
        issues.append("WARNING: No export presets found in export_presets.cfg")
        return issues

    # Check each preset for appropriate filters
    for preset_name, config in presets.items():
        preset_lower = preset_name.lower()

        # For Client presets - should exclude core/
        if (
            "client" in preset_lower
            or "windows" in preset_lower
            or "macos" in preset_lower
            or "ios" in preset_lower
            or "android" in preset_lower
        ):
            exclude_folders = config.get("exclude_folders", [])
            if not any("core" in f.lower() for f in exclude_folders):
                issues.append(
                    f"PRESET '{preset_name}': Should exclude 'res://core/' for security"
                )

        # For Server/Dedicated presets - should exclude client/
        if (
            "server" in preset_lower
            or "dedicated" in preset_lower
            or "headless" in preset_lower
        ):
            exclude_folders = config.get("exclude_folders", [])
            if not any("client" in f.lower() for f in exclude_folders):
                issues.append(
                    f"PRESET '{preset_name}': Should exclude 'res://client/' for security"
                )

    return issues


def check_gdignore_files(project_root: Path) -> dict:
    """
    Check for .gdignore files that prevent files from being included in exports.

    Returns dict mapping folders to their gdignore status.
    """
    status = {}

    # Check core/ has .gdignore for client exports
    core_gdignore = project_root / "core" / ".gdignore"
    status["core/.gdignore"] = core_gdignore.exists()

    # Check client/ has .gdignore for server exports
    client_gdignore = project_root / "client" / ".gdignore"
    status["client/.gdignore"] = client_gdignore.exists()

    return status


def main():
    parser = argparse.ArgumentParser(
        description="Verify Godot project export isolation between server and client code."
    )
    parser.add_argument(
        "--project",
        type=Path,
        default=Path("."),
        help="Path to Godot project root (default: current directory)",
    )
    parser.add_argument(
        "--fix", action="store_true", help="Create missing .gdignore files"
    )

    args = parser.parse_args()
    project_root = args.project.resolve()

    print(f"Verifying export isolation for: {project_root}")
    print("=" * 60)

    all_violations = []
    all_issues = []

    # 1. Check folder isolation
    print("\n[1] Checking folder structure isolation...")
    violations = check_folder_isolation(project_root)
    if violations:
        print("    VIOLATIONS FOUND:")
        for v in violations:
            print(f"      - {v}")
            all_violations.extend(violations)
    else:
        print("    ✓ No folder leakage detected")

    # 2. Check export presets
    print("\n[2] Checking export_presets.cfg configuration...")
    issues = verify_export_presets(project_root)
    if issues:
        print("    ISSUES FOUND:")
        for issue in issues:
            print(f"      - {issue}")
            all_issues.extend(issues)
    else:
        print("    ✓ Export presets properly configured")

    # 3. Check .gdignore files
    print("\n[3] Checking .gdignore files...")
    gdignore_status = check_gdignore_files(project_root)
    for folder, exists in gdignore_status.items():
        status = "✓ exists" if exists else "✗ MISSING"
        print(f"    {folder}: {status}")

    if args.fix:
        print("\n[+] Creating missing .gdignore files...")
        if not gdignore_status.get("core/.gdignore"):
            core_path = project_root / "core"
            if core_path.exists():
                (core_path / ".gdignore").write_text("*.gd\n*.cs\n")
                print("    Created core/.gdignore")
        if not gdignore_status.get("client/.gdignore"):
            client_path = project_root / "client"
            if client_path.exists():
                (client_path / ".gdignore").write_text("*.gd\n*.cs\n")
                print("    Created client/.gdignore")

    # 4. Summary
    print("\n" + "=" * 60)
    print("SUMMARY:")
    print(f"  Folder violations: {len(all_violations)}")
    print(f"  Configuration issues: {len(all_issues)}")
    print(
        f"  .gdignore files: {sum(gdignore_status.values())}/{len(gdignore_status)} present"
    )

    if all_violations or all_issues:
        print("\n✗ EXPORT ISOLATION VERIFICATION FAILED")
        return 2
    else:
        print("\n✓ EXPORT ISOLATION VERIFICATION PASSED")
        return 0


if __name__ == "__main__":
    sys.exit(main())
