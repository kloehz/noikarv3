#!/usr/bin/env python3
"""Prepare only the user-approved isolated VPS instance and local F5 profile."""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REMOTE_ROOT = "/opt/noikar-f5-playtest"
OWNER = "noikar-f5-playtest-v1"
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8"]


def validate_payload(directory, remote_root):
    if remote_root != REMOTE_ROOT:
        raise ValueError("Only the isolated test root is allowed")
    payload = {}
    for name in ["noikar-f5-server.x86_64", "noikar-f5-server.pck", "noikar-f5-api"]:
        path = directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise ValueError("Missing or unsafe payload artifact: " + name)
        payload[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--api-build", required=True)
    parser.add_argument("--target", default="root@72.60.58.24")
    parser.add_argument("--game-host", default="72.60.58.24")
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+", args.target) or not re.fullmatch(r"noikar-f5-[a-z0-9-]+", args.api_build):
        parser.error("Invalid SSH target or API build identity")
    ipaddress.ip_address(args.game_host)
    manifest = validate_payload(args.payload, REMOTE_ROOT)
    if not args.execute:
        print(json.dumps({"execute": False, "isolated_root": REMOTE_ROOT, "payload_sha256": manifest}, indent=2))
        return

    def remote(code):
        result = subprocess.run(["ssh", *SSH_OPTIONS, args.target, "python3 -"], input=code, text=True, capture_output=True, check=True, timeout=90)
        return result.stdout

    # No access to SSH config/key contents is required. OpenSSH uses existing authentication.
    remote(f'''from pathlib import Path
root=Path({REMOTE_ROOT!r})
owner={OWNER!r}
if root.exists() and (not (root/'.owner').is_file() or (root/'.owner').read_text()!=owner): raise SystemExit('Unowned test directory')
root.mkdir(mode=0o700,exist_ok=True)
(root/'.owner').write_text(owner)
for name in ['world','bin','staging']: (root/name).mkdir(exist_ok=True)
''')
    files = [args.payload / name for name in manifest] + [ROOT / "tools/vps_playtest_proxy.py", ROOT / "tools/vps_playtest_install.py"]
    subprocess.run(["scp", *SSH_OPTIONS, *map(str, files), args.target + ":" + REMOTE_ROOT + "/staging/"], check=True, timeout=180)
    install = remote(f'''import hashlib,json,os,shutil,subprocess
from pathlib import Path
root=Path({REMOTE_ROOT!r})
manifest=json.loads({json.dumps(manifest)!r})
for name,digest in manifest.items():
 if hashlib.sha256((root/'staging'/name).read_bytes()).hexdigest()!=digest: raise SystemExit('Payload checksum mismatch')
for unit in ['noikar-f5-proxy.service','noikar-f5-api.service']:
 p=Path('/etc/systemd/system')/unit
 if p.exists():
  if 'Noikar isolated F5' not in p.read_text(): raise SystemExit('Unowned service')
  subprocess.run(['systemctl','stop',unit],check=True)
for name in manifest:
 dest=root/('bin' if name=='noikar-f5-api' else 'world')/name
 shutil.copy2(root/'staging'/name,dest)
 if not name.endswith('.pck'): dest.chmod(0o755)
for name in ['vps_playtest_proxy.py','vps_playtest_install.py']: shutil.copy2(root/'staging'/name,root/name)
subprocess.run(['python3',str(root/'vps_playtest_install.py')],check=True)
''')
    result = json.loads(install.strip().splitlines()[-1])
    if not result.get("ok") or result.get("api_build") != args.api_build:
        raise SystemExit("Unexpected isolated API build; editor profile not enabled")
    profile = ROOT / ".godot/noikar_vps_playtest.cfg"
    profile.write_text(f'[playtest]\nenabled=true\nssh_target="{args.target}"\ngame_host="{args.game_host}"\nlocal_port=19091\nremote_port=18491\napi_build="{args.api_build}"\n')
    profile.chmod(0o600)
    report = {**result, "payload_sha256": manifest, "local_profile": ".godot/noikar_vps_playtest.cfg"}
    (ROOT / "docs/evidence/f5-vps-deployment.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
