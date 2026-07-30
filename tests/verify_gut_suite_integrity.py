#!/usr/bin/env python3
"""Reject committed GUT focus and skip mechanisms in the full test suite."""

from pathlib import Path
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOTS = (ROOT / "tests" / "unit", ROOT / "tests" / "integration")
FORBIDDEN_TEST_PATTERNS = (
    (r"\bvar\s+skip_script\b", "skip_script"),
    (r"\bfunc\s+should_skip_script\s*\(", "should_skip_script"),
    (r"\bpending\s*\(", "pending()"),
    (r"\bskip_if_\w+\s*\(", "skip_if_*()"),
)
FOCUS_FLAGS = ("-gselect", "-gtest", "-gunit_test_name")


def uncommented_source(path: Path) -> str:
    return "\n".join(line.split("#", 1)[0] for line in path.read_text().splitlines())


def scan_test_roots(test_roots: tuple[Path, ...]) -> list[str]:
    failures: list[str] = []
    for test_root in test_roots:
        for path in sorted(test_root.rglob("*.gd")):
            source = uncommented_source(path)
            for pattern, label in FORBIDDEN_TEST_PATTERNS:
                if re.search(pattern, source):
                    failures.append(f"{path}: forbidden GUT skip mechanism {label}")
    return failures


def verify_skip_script_fixture() -> None:
    """Prove the deprecated GUT skip_script variable is rejected without a committed test."""
    with tempfile.TemporaryDirectory() as temp_dir:
        fixture = Path(temp_dir) / "test_skip_script_fixture.gd"
        fixture.write_text("extends GutTest\nvar skip_script = true\n")
        failures = scan_test_roots((Path(temp_dir),))
        if not any("skip_script" in failure for failure in failures):
            raise AssertionError("skip_script fixture was not detected")


def main() -> int:
    try:
        verify_skip_script_fixture()
    except AssertionError as error:
        print(f"GUT suite integrity self-check failed: {error}")
        return 1

    failures = [
        failure.replace(str(ROOT) + "/", "")
        for failure in scan_test_roots(TEST_ROOTS)
    ]

    config = (ROOT / "openspec" / "config.yaml").read_text()
    for line in config.splitlines():
        if "command:" not in line:
            continue
        if any(flag in line for flag in FOCUS_FLAGS):
            failures.append(f"openspec/config.yaml: focused GUT runner flag in {line.strip()}")

    if failures:
        print("GUT suite integrity check failed:")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1

    print("GUT suite integrity check passed: no focused or skipped committed tests.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
