#!/usr/bin/env python3
"""Remote installer restricted to the approved isolated F5 test instance."""
import ipaddress
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import subprocess
import time
import urllib.request

ROOT = Path("/opt/noikar-f5-playtest")
OWNER = "noikar-f5-playtest-v1"


def private_database_endpoint(address):
    ip = ipaddress.ip_address(address)
    if ip.version != 4 or not ip.is_private or ip.is_unspecified or ip.is_loopback or ip.is_link_local:
        raise ValueError("Expected the isolated container's private IPv4 address")
    return str(ip) + ":5432"


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def service(name, command, environment=""):
    return f"""[Unit]
Description=Noikar isolated F5 {name}
After=network-online.target docker.service
[Service]
User=noikar-f5
Group=noikar-f5
WorkingDirectory={ROOT}
{environment}
Environment=HOME={ROOT}/runtime
ExecStart={command}
Restart=on-failure
RestartSec=2
KillMode=control-group
TimeoutStopSec=10
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths={ROOT}/runtime
UMask=0077
[Install]
WantedBy=multi-user.target
"""


def main():
    if not (ROOT / ".owner").is_file() or (ROOT / ".owner").read_text() != OWNER:
        raise SystemExit("Refusing a directory not owned by the isolated test installer")
    before = os.path.realpath("/root/noikar/world/current")
    version = run(str(ROOT / "world/noikar-f5-server.x86_64"), "--version")
    if version != "4.8.beta1.official.4d10419ca":
        raise SystemExit("Wrong isolated runtime version")
    try:
        user = pwd.getpwnam("noikar-f5")
        if user.pw_dir != str(ROOT / "runtime"):
            raise SystemExit("Existing system user is not owned by this test instance")
    except KeyError:
        run("useradd", "--system", "--home-dir", str(ROOT / "runtime"), "--shell", "/usr/sbin/nologin", "noikar-f5")
        user = pwd.getpwnam("noikar-f5")
    ROOT.chmod(0o755)
    for folder in ["runtime", "config"]:
        (ROOT / folder).mkdir(exist_ok=True)
        (ROOT / folder).chmod(0o700)
    os.chown(ROOT / "runtime", user.pw_uid, user.pw_gid)
    pg_env = ROOT / "config/postgres.env"
    api_env = ROOT / "config/backend.env"
    if not pg_env.exists() and not api_env.exists():
        password = secrets.token_hex(32)
        pg_env.write_text(f"POSTGRES_DB=noikar_f5\nPOSTGRES_USER=noikar_f5\nPOSTGRES_PASSWORD={password}\n")
        api_env.write_text(f"PORT=18493\nBIND_HOST=127.0.0.1\nDATABASE_URL=postgres://noikar_f5:{password}@127.0.0.1:18492/noikar_f5?sslmode=disable\nJWT_SECRET={secrets.token_hex(48)}\nPROVISIONER_CREDENTIAL={secrets.token_hex(48)}\n")
        pg_env.chmod(0o600)
        api_env.chmod(0o600)
    elif not pg_env.exists() or not api_env.exists():
        raise SystemExit("Incomplete isolated database configuration; refusing to replace secrets")
    # Existing production containers, databases and networks are never inspected for secrets.
    if subprocess.run(["docker", "network", "inspect", "noikar-f5-playtest"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        run("docker", "network", "create", "--internal", "noikar-f5-playtest")
    exists = subprocess.run(["docker", "container", "inspect", "noikar-f5-postgres"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not exists:
        run("docker", "run", "-d", "--name", "noikar-f5-postgres", "--label", f"noikar.owner={OWNER}", "--restart", "unless-stopped", "--network", "noikar-f5-playtest", "--env-file", str(pg_env), "-v", "noikar-f5-playtest-db:/var/lib/postgresql/data", "postgres:16-alpine")
    else:
        label = run("docker", "inspect", "--format", '{{index .Config.Labels "noikar.owner"}}', "noikar-f5-postgres")
        if label != OWNER:
            raise SystemExit("Refusing an unowned PostgreSQL container")
        run("docker", "start", "noikar-f5-postgres")
    for _ in range(50):
        check = subprocess.run(["docker", "exec", "noikar-f5-postgres", "pg_isready", "-U", "noikar_f5"], capture_output=True)
        if check.returncode == 0:
            break
        time.sleep(0.2)
    else:
        raise SystemExit("Isolated PostgreSQL did not become ready")
    # Docker's internal network intentionally does not publish host ports. The
    # host API reaches only this owned container over its private bridge address.
    private_ip = run("docker", "inspect", "--format", '{{(index .NetworkSettings.Networks "noikar-f5-playtest").IPAddress}}', "noikar-f5-postgres")
    endpoint = private_database_endpoint(private_ip)
    rows = api_env.read_text().splitlines()
    rows = [line.replace("@" + line.split("@", 1)[1].split("/", 1)[0] + "/", "@" + endpoint + "/", 1) if line.startswith("DATABASE_URL=") else line for line in rows]
    api_env.write_text("\n".join(rows) + "\n")
    units = {
        "noikar-f5-api": service("account API", str(ROOT / "bin/noikar-f5-api"), f"EnvironmentFile={api_env}"),
        "noikar-f5-proxy": service("room proxy", f"/usr/bin/python3 {ROOT}/vps_playtest_proxy.py --root {ROOT}"),
    }
    for name, content in units.items():
        path = Path("/etc/systemd/system") / (name + ".service")
        if path.exists() and "Noikar isolated F5" not in path.read_text():
            raise SystemExit("Refusing to replace an unrelated service")
        path.write_text(content)
    run("systemctl", "daemon-reload")
    for name in units:
        run("systemctl", "enable", name + ".service")
        run("systemctl", "restart", name + ".service")
    for _ in range(50):
        try:
            with urllib.request.urlopen("http://127.0.0.1:18491/api/v1/health", timeout=1) as response:
                health = json.load(response)
            break
        except (OSError, ValueError):
            time.sleep(0.2)
    else:
        raise SystemExit("Isolated API/proxy did not become healthy")
    client = str(ipaddress.ip_address(os.environ["SSH_CONNECTION"].split()[0]))
    run("ufw", "allow", "proto", "udp", "from", client, "to", "any", "port", "24580", "comment", "noikar-f5-playtest")
    after = os.path.realpath("/root/noikar/world/current")
    if before != after:
        raise SystemExit("Production release changed during preparation; investigate")
    print(json.dumps({"ok": True, "runtime": version, "api_build": health.get("version"), "production_release_unchanged": before == after, "root": str(ROOT), "account_transport": "SSH loopback only", "game_port": 24580, "allowed_client_ip": client}))


if __name__ == "__main__":
    main()
