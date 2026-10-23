#!/usr/bin/env python3
"""Install the pinned optional upstream GDExtension without replacing Godot."""
import argparse
import hashlib
import io
from pathlib import Path, PurePosixPath
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
URL = "https://codeberg.org/godotsteam/godotsteam/releases/download/v4.23.1/godotsteam-4.23.1-gdextension-plugin-4.4.zip.tar.xz"
SHA256 = "37d53ede5eda11d2247d70c1af91f95a4777ad2a419fc8a24de1cc816d21cc0a"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Use an already downloaded official archive")
    args = parser.parse_args()
    if args.archive:
        data = args.archive.read_bytes()
    else:
        with urllib.request.urlopen(URL, timeout=90) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("Archive checksum mismatch; nothing installed")
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        files = {member.name: archive.extractfile(member).read() for member in archive.getmembers() if member.isfile()}
    for name, blob in list(files.items()):
        if name.endswith(".zip"):
            with zipfile.ZipFile(io.BytesIO(blob)) as archive:
                files.update({name: archive.read(name) for name in archive.namelist() if not name.endswith("/")})
    selected = {}
    for name, blob in files.items():
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or path.parts[:2] != ("addons", "godotsteam"):
            continue
        selected[ROOT.joinpath(*path.parts)] = blob
    if not selected:
        raise SystemExit("Expected addon was not found; nothing installed")
    for path, blob in selected.items():
        if path.exists() and path.read_bytes() != blob:
            raise SystemExit(f"Refusing to overwrite modified dependency: {path}")
    for path, blob in selected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(blob)
    print(f"Installed GodotSteam 4.23.1: {len(selected)} upstream files; SHA256 verified")
    print("Reopen Godot or run its headless editor once to register the GDExtension.")


if __name__ == "__main__":
    main()
