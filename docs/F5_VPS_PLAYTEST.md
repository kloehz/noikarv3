# Play solo against the isolated VPS from Godot

This Mac's migration checkout is configured for **F5 → login → create a VPS test
room → play solo**. It uses a separate Godot 4.8 instance, account database and
services. The existing production Godot 4.7 deployment is not replaced. This is
an ENet playtest, **not a Steam test**.

## Start playing

1. Open `project.godot` from
   `/Users/guidocotelesso/Documents/godot/projects/noikar-player-host` in the installed
   Godot `4.8.beta1.official.4d10419ca`.
2. Press **F5** and wait for the secure VPS connection message.
3. Use **CREATE ACCOUNT** once to create a separate test account, then **SIGN IN**
   on subsequent runs. Production accounts are not copied to this database.
4. Select **CREATE VPS TEST ROOM**. Choose **JOIN RED** or **JOIN BLUE**, enable
   **READY**, then select **START CHARACTER SELECTION**.
5. Choose a character and confirm readiness. The normal countdown starts the game;
   one human is sufficient. Use the existing controls to fight the mobs.

Use the existing mouse-menu toggle to reach **Leave room**. Leaving preserves the
test login, so another room can be created without signing in again.
Stopping the game also tears down its SSH tunnel; a parent-lifetime guardian covers
an abrupt editor stop or game crash. A world that receives no authenticated player
is retired after 30 seconds, so an interrupted creation does not reserve the only
test slot for hours.

## What is configured

| Component | Scope |
| --- | --- |
| Local profile | `.godot/noikar_vps_playtest.cfg`, ignored and never exported |
| Account connection | Owned host-key-verified SSH tunnel, local `127.0.0.1:19091` |
| Isolated VPS files | `/opt/noikar-f5-playtest` |
| Services | `noikar-f5-api`, `noikar-f5-proxy`; separate unprivileged system user |
| Database | Own PostgreSQL container/volume on an internal Docker network; no public database port |
| Game connection | ENet UDP `24580`, firewall restricted to this Mac's public IP at setup |

The editor checks the expected API build before enabling account requests. Passwords
and account bearers cross the Internet only inside SSH. The game server receives
scoped admission proofs, not reusable account tokens. Steam initialization is skipped
for this isolated profile.

## If startup fails

- **SSH unavailable:** existing SSH authentication must work on this Mac. There is
  no embedded password and no insecure remote-HTTP fallback.
- **API unavailable:** stop/restart the editor run after restoring the isolated
  services; do not change the profile to the old production HTTP endpoint.
- **Connection times out after changing networks:** the UDP rule is scoped to the
  preparation client's public IP (redacted in committed evidence); rerun preparation
  from the new network rather than opening a broad firewall rule.
- **Disable this profile:** change `enabled=true` to `enabled=false` in the ignored
  local config. Normal LAN/Steam menu behavior returns on the next run.
- **Explicit backend override:** `NOIKAR_BACKEND_URL` takes precedence over this
  default profile, including the existing isolated integration-test environment.

## Reproduction and evidence

`tools/prepare_vps_playtest.py` validates artifacts, hashes and the fixed isolated
root before deployment. It never switches `/root/noikar/world/current`. Its
`--execute` flag is explicit; rerunning it may restart only the owned test services.

Regenerate the Netfox source manifest with `python3 tools/write_netfox_manifest.py`
before rebuilding the server PCK. Editor sources are still hashed directly;
tokenized exported scripts use the packaged source manifest. An unknown or stale
build is not accepted by weakening the compatibility handshake.

The isolated server uses the official exact-version Linux editor binary headlessly
with an exported dedicated PCK because Linux export templates were not installed.
This is supported by Godot but is not a production CPU-budget certification.

`tests/manual/editor_vps_probe.gd` exercised real isolated registration/login and
two consecutive native client/VPS sessions, including creator admission, team and
character selection, one player spawn, movement, attacks, replicated mobs/camera,
leave, retained login and inactive clock. See `docs/evidence/f5-vps-playtest.json`
and `.png`. It does not certify a full match, damage outcomes, six players, Steam,
or host/server performance.

Additional actual-runtime checks: forcibly terminating the local game releases the
SSH listener, and an unclaimed remote world expires and permits a new room after
the 30-second admission lease. See `f5-vps-abrupt-stop.json` and
`f5-vps-unclaimed-lease.json` in the same evidence directory.

Known deferred minor: if a world exits immediately before the proxy's one-second
reaper and a new creation wins that race, the old backend room record may remain
until normal expiry. No old world process remains, and this does not block the new
room. Response-failure cleanup is ownership-checked and cannot close the newer room.
