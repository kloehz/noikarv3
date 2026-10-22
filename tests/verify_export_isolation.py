#!/usr/bin/env python3
"""Validate static export boundaries; compiled-pack inspection is a separate gate.

Player-host clients need authoritative simulation. Dedicated scenes also reference
presentation scripts before stripping nodes at runtime. A .gdignore is global to
the editor, not a per-export security boundary, so neither folder may be hidden.
"""

import argparse
import fnmatch
import json
from pathlib import Path
import re
import sys


def parse_export_presets(presets_path: Path) -> dict:
    if not presets_path.is_file():
        return {}
    presets = {}
    current = None
    for raw in presets_path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("["):
            current = None
            if re.fullmatch(r"\[preset\.\d+\]", line):
                current = {"name": line, "exclude_folders": [], "include_folders": []}
                presets[line] = current
            continue
        if current is None or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key not in ("name", "exclude_filter", "include_filter", "dedicated_server"):
            continue
        if key == "dedicated_server":
            current[key] = value == "true"
            continue
        try:
            value = json.loads(value)
        except json.JSONDecodeError:
            continue
        if key == "name":
            current[key] = value
        else:
            target = "exclude_folders" if key == "exclude_filter" else "include_folders"
            current[target] = [part.strip().removeprefix("res://").lstrip("/") for part in value.split(",") if part.strip()]
    return presets


def check_folder_isolation(project_root: Path) -> list:
    problems = []
    for folder in ("common", "core", "client"):
        if (project_root / folder / ".gdignore").exists():
            problems.append(f"{folder}/.gdignore hides required runtime resources from every export")
    return problems


def verify_export_presets(project_root: Path) -> list:
    presets = parse_export_presets(project_root / "export_presets.cfg")
    if not presets:
        return ["Missing export presets"]
    problems = []
    protected = ["backend/private.gd", "noikar-noray/private.gd", "tests/private.gd", "addons/gut/private.gd", ".env", ".env.local", "nested/.env", "nested/.env.local"]
    required = ["core/LogicComponent.gd", "common/BaseEntity.gd", "client/VisualComponent.gd"]
    for preset in presets.values():
        name = preset["name"]
        patterns = preset["exclude_folders"]
        for path in required:
            if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns):
                problems.append(f"{name}: must retain required simulation/presentation resource {path}")
        for path in protected:
            if not any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns):
                problems.append(f"{name}: must exclude private/test resource {path}")
    return problems


def check_gdignore_files(project_root: Path) -> dict:
    return {f"{folder}/.gdignore": (project_root / folder / ".gdignore").exists() for folder in ("core", "client")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=Path("."))
    args = parser.parse_args()
    root = args.project.resolve()
    problems = check_folder_isolation(root) + verify_export_presets(root)
    if problems:
        print("EXPORT_ISOLATION_FAIL")
        for problem in problems:
            print("-", problem)
        return 2
    print("EXPORT_ISOLATION_PASS: gameplay resources retained; private/test paths excluded (static configuration only)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
