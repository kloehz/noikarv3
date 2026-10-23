# F5 isolated VPS playtest implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open this Godot project, press F5, sign in, create a VPS test room and play solo against the existing mobs.

**Architecture:** An editor/debug-only ignored local profile starts an owned SSH loopback tunnel to an isolated VPS account API. A test-only local-to-VPS proxy starts one matching dedicated room using backend-validated room identity and scoped credentials; the client joins over ENet using a single-use ticket. Existing Noikar menu, roster, teams, gameplay and Netfox clocks remain authoritative.

**Tech Stack:** Exact Godot `4.8.beta1.official.4d10419ca`, existing Go/PostgreSQL backend, Python stdlib sidecar, OpenSSH, separate systemd services and disposable-test database.

**Spec:** User-approved conversational contract: F5 → existing login → create isolated VPS room → team/ready/character → solo PvE, no production service replacement. The inline contract above is the bounded spec.

## Global Constraints

- Preserve all prior Task5/7 WIP and the original checkout; no push/merge/shared release switch.
- New VPS paths, database, services and ports only; current production world is 4.7 and must remain untouched.
- Account passwords/bearers cross the Internet only through host-key-verified SSH; public game traffic receives only scoped single-use admission tickets.
- No implicit HTTP fallback, credential logging, hardcoded passwords, authentication bypass or production-export editor mode.
- Six humans maximum, three per team; dedicated peer1 is not a human player. Real joining creator controls the existing lobby.
- Do not call this Steam testing or change game rules, VFX scope, population or clock rate.

## Review Focus

- An exported/release runtime must ignore the local editor profile.
- An occupied local tunnel port or failed SSH login must fail closed, never use an unrelated endpoint.
- Concurrent room creation must not leak backend rooms or spawn multiple worlds.
- Cancellation during room startup and stale completions must not inherit a newer room or leak processes.
- Stopping F5 or leaving a room must stop owned room work without touching other services.

### Task 1: Scoped dedicated session and isolated room proxy

**Files:** `common/net/session_service.gd`, `common/game_manager.gd`, `common/auth_service.gd`, `tools/vps_playtest_proxy.py`, focused GUT and Python tests.

**Interfaces:** `attach_dedicated(peer: MultiplayerPeer) -> Error`; server bootstrap accepts validated scoped room/creator data from private environment only. Proxy forwards the existing account API and adds validated `game_port` to successful room creation; only fixed executable/port can be launched.

- [ ] Write/run RED tests for dedicated role, no peer1 human, creator admission, concurrent creation, startup failure cleanup and secret-free child environment.
- [ ] Implement minimal dedicated attachment/bootstrap and bounded proxy process ownership.
- [ ] Run focused tests GREEN and full existing regression tests.

### Task 2: Editor-only F5 tunnel/profile and existing menu integration

**Files:** `common/net/editor_vps_playtest.gd`, existing manager/auth/menu files, ignored `.godot/noikar_vps_playtest.cfg`, editor profile and UI tests.

**Interfaces:** Profile is loaded only by editor debug runtime outside isolated test bootstrap. `ready_for_login()` attests an owned tunnel and expected API build. `host_editor_vps() -> Dictionary` creates room, obtains ticket and attaches existing client session; no second peer/clock.

- [ ] Write/run RED tests for release/test isolation, invalid profile/occupied port, failed readiness, creator room flow and cancellation.
- [ ] Implement owned SSH tunnel, loopback account policy and existing menu intents/status.
- [ ] Run focused tests GREEN and whole GUT/Python suites.

### Task 3: Isolated deployment and native acceptance

**Files:** `tools/prepare_vps_playtest.py`, reproducible setup instructions and sanitized evidence.

**Interfaces:** Fixed isolated root `/opt/noikar-f5-playtest`; loopback proxy/API ports `18491/18493`; own PostgreSQL on an internal Docker network with no published ports. Dedicated game UDP `24580`, local tunnel `19091`. Strict host-key checks; no secret output or production path mutations.

- [ ] Test deployment manifest/path/port guards before implementation.
- [ ] Export exact matching debug dedicated build; build Linux API; verify hashes and upload isolated payload only.
- [ ] Provision separate test database/API/proxy services and restricted test game port. Install ignored local editor profile.
- [ ] Verify production symlink/version/service identities unchanged.
- [ ] Run actual native client over the secure tunnel/public ENet to VPS: real registration/login, create, creator/team/ready/character, spawn/movement/attack/mob replication and leave/repeat. Full damage/outcome parity remains the migration's separate full-match gate; see the ledger ruling.
- [ ] Run full regressions, review scoped change and report exact F5 steps/remaining limits. Do not claim whole-migration completion.
