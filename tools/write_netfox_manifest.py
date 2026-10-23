#!/usr/bin/env python3
"""Capture exact Netfox source content for compatibility checks in exported packs."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    entries = []
    for folder in ["netfox", "netfox.internals", "netfox.extras", "netfox.noray"]:
        for path in (ROOT / "addons" / folder).rglob("*"):
            if path.is_file() and path.suffix in (".gd", ".cfg", ".gdextension"):
                entries.append("res://" + path.relative_to(ROOT).as_posix() + ":" + hashlib.sha256(path.read_bytes()).hexdigest())
    if not entries:
        raise SystemExit("No Netfox sources found; refusing an empty manifest")
    digest = hashlib.sha256("\n".join(sorted(entries)).encode()).hexdigest()
    output = ROOT / "common/net/netfox_build_manifest.tres"
    content = '[gd_resource type="Resource" format=3]\n\n[resource]\nmetadata/source_fingerprint = "' + digest + '"\n'
    if not output.exists() or output.read_text() != content:
        output.write_text(content)
    print("NETFOX_SOURCE_FINGERPRINT", digest)


if __name__ == "__main__":
    main()
