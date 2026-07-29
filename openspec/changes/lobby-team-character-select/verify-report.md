## Verification Report

**Change**: lobby-team-character-select  
**Mode**: Standard (Strict TDD disabled)  
**Scope reviewed**: proposal, all three delta specs, design, tasks, apply progress, uncommitted implementation, and final diff.

### Completeness

| Metric | Value |
|---|---:|
| Tasks total | 22 |
| Tasks complete | 22 |
| Tasks incomplete | 0 |

The checked task list agrees with the apply-progress record. The implementation remains a single uncommitted change of 795 additions and 513 deletions in tracked files, plus new OpenSpec and lobby-test files; this exceeds the 400-line review budget accepted in apply progress.

### Build & Tests Execution

**Build / Godot validation**: ✅ Passed with existing-project diagnostics

```text
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --editor --quit
exit 0
Godot 4.7 loaded the project. It reported pre-existing duplicate asset UIDs,
invalid HealthViewport paths, and a renderer RID leak at exit.
```

**Tests**: ✅ Passed

```text
cd backend && go test ./...                 9 passed
cd backend && go test -cover ./...          9 passed
Godot GUT unit suite                        32/32 passed, 104 asserts
Godot GUT integration suite                 45/45 passed, 180 asserts
python3 tests/verify_export_isolation.py    passed
python3 tests/verify_headless_server.py --quick  passed
git diff --check                            passed
```

**Coverage**: Go command passed, but no aggregate percentage was emitted; GUT coverage is not configured. ➖ Not available.

The integration run exits successfully but emits Netfox disconnect errors, 11 orphan nodes, and ObjectDB/resource leaks. These do not invalidate its asserted results, but they reduce the signal quality of the suite.

### Security and Authority Assessment

| Area | Result | Evidence |
|---|---|---|
| Opaque creator handle | ✅ Static implementation | 32 random bytes are base64url-encoded; only SHA-256 hash is persisted (`backend/cmd/server/main.go:298-309`). No account ID is sent in the Noray command. |
| Single use / expiry | ✅ Static implementation | Atomic `UPDATE ... used_at IS NULL AND expires_at > NOW() ... RETURNING` (`main.go:267-274`). |
| Dedicated credential | ✅ Static implementation | Validation requires a constant-time comparison of `X-World-Server-Credential` before lookup (`main.go:256-260`, `311-314`); normal client code only issues handles. |
| Nonce binding to intended server | ❌ Failing design/security contract | The database binds only ticket hash to a client-generated nonce. Validation does not bind either value to `provision_token`, Noray OID, or a per-instance credential (`main.go:267-269`; `game_manager.gd:53-64`). Any dedicated process holding the shared credential and copied ticket+nonce can redeem first. |
| Host authority | ✅ Static implementation | Host is true only when the validated creator account equals the authenticated lobby account (`match_manager.gd:461-468`). Duplicate account admission is rejected (`517-529`). |
| Private team visibility | ✅ Partial runtime coverage | Recipient-only `rpc_id` snapshots serialize same-team members only and omit peer IDs (`477-490`); a direct serializer test passed. No real two-client transport capture ran. |
| Disconnect / timeout recovery | ✅ Partial runtime coverage | Netfox peer leave cancels frozen selection; cancellation clears ready/choice state; deadline uses `tick >= deadline` (`match_manager.gd:284-297`, `496-509`; `match_director.gd:61-66`). |

### Spec Compliance Matrix

| Requirement | Scenario | Runtime evidence | Result |
|---|---|---|---|
| Login-to-Room UI | Authenticated player enters room | No end-to-end admission/UI test | ❌ UNTESTED |
| Login-to-Room UI | Room admission fails | No test; source disconnects rejected admission without a rejection snapshot or visible room-panel message | ❌ FAILING |
| Lobby membership | Team members become ready | No multi-peer snapshot-delivery test | ❌ UNTESTED |
| Lobby membership | Member disconnects in LOBBY | `test_actual_netfox_peer_leave_removes_lobby_member` | ⚠️ PARTIAL |
| Host-controlled start | Host starts selection | `test_public_selection_handlers_enforce_host_and_phase_without_mutation` | ✅ COMPLIANT |
| Host-controlled start | Non-host starts selection | Same test | ✅ COMPLIANT |
| Timed selection | All players complete selection | Director seam enters countdown, but no manager-level valid selections + selected-character spawn test | ⚠️ PARTIAL |
| Timed selection | Deadline expires | `test_character_selection_deadline_is_exact_and_cancels`; manager cancellation test | ✅ COMPLIANT |
| Private snapshots | Opponent data withheld | `test_private_snapshot_never_contains_enemy_identity_or_peer_id` | ⚠️ PARTIAL |
| Validation | Invalid or late action arrives | Wrong-phase path tested only; unauthenticated sender, invalid choice, and post-selection late join lack covering tests | ❌ UNTESTED |
| Disconnect recovery | Frozen member disconnects | `test_peer_leave_during_character_selection_cancels_and_refreshes_lobby` | ✅ COMPLIANT |
| Phase model | Full phase walk | Existing walk uses `request_match_start()` and bypasses CHARACTER_SELECT | ❌ FAILING |
| Phase model | Selection timeout | `test_character_selection_deadline_is_exact_and_cancels` | ✅ COMPLIANT |
| Spawn routing | Solo/free play unchanged | Existing `test_solo_free_play_without_director` | ⚠️ PARTIAL |
| Spawn routing | Group detection intact | Existing integration coverage | ⚠️ PARTIAL |
| Spawn routing | Pre-launch spawn gate | Cancellation test checks zero players, but not a live incomplete roster | ⚠️ PARTIAL |
| Team assignment | Same roster, different join orders | Director roster-override assignment only | ⚠️ PARTIAL |
| Team assignment | Odd roster sizes RED | `test_team_assignment_odd_roster` | ✅ COMPLIANT |
| Team assignment | Team capacity full | No covering test | ❌ UNTESTED |
| MatchRules | Defaults match locked values | `test_match_rules.gd` | ✅ COMPLIANT |
| Per-entity team | Spawned player shows frozen assignment | Existing spawn-routing coverage | ⚠️ PARTIAL |
| Per-entity team | Pre-assignment default | No entity-level covering test | ❌ UNTESTED |
| Per-entity team | Selection has no player entity | Cancellation test only | ⚠️ PARTIAL |

**Compliance summary**: 7/23 scenarios compliant; 9 partial; 5 untested; 2 failing. Per the verification policy, partial/static evidence cannot prove scenario compliance.

### Correctness (Static Evidence)

| Requirement | Status | Notes |
|---|---|---|
| Server-owned lobby state and duplicate sessions | ✅ Implemented | `_lobby` is server-local; account-ID duplication is rejected before mutation. |
| Phase and deadline | ✅ Implemented | `CHARACTER_SELECT`, replicated deadline, `30.0s -> 1800` ticks, and exact deadline comparison exist. |
| Deferred player spawn | ✅ Implemented | Spawn is subscribed to selection launch, not authenticated connection. |
| Admission failure UX | ❌ Implemented incorrectly | `_authenticate_peer` disconnects on failed `_admit_authenticated_identity`; no reason reaches the client. |
| Provision-target binding | ❌ Implemented incorrectly | Shared credential authenticates a server class, not the particular provisioned process. |

### Coherence (Design)

| Decision | Followed? | Notes |
|---|---|---|
| Server-only lobby records | ✅ Yes | No roster is replicated in `MatchState`. |
| Recipient-only reliable snapshots | ✅ Yes | `rpc_id()` and team-filtered serializer are used. |
| Tick-driven deadline | ✅ Yes | No wall-clock/SceneTreeTimer selection deadline. |
| Target-provisioned dedicated redemption | ❌ No | The nonce has no association with a provision token, OID, or unique server credential. |
| Scene-first UI composition | ✅ Yes | Panels and controls are composed in `.tscn`; controller binds dynamic snapshots. |

### Issues Found

**CRITICAL**

1. **Creator-handle redemption is not bound to the intended dedicated-server instance.** `backend/cmd/server/main.go:267-269` accepts a shared world credential plus a ticket and client-generated nonce, while `common/game_manager.gd:53-64` never supplies a provision-token/OID/instance identity to validation. A second dedicated process that has the shared credential and observes or receives the handle+nonce can consume the handle first. This violates the design's target-server nonce-binding claim and can deny the real room provisioning while attaching creator authority to the wrong server.
2. **Rejected room admission cannot satisfy the required rejection UX.** On capacity, duplicate-account, or wrong-phase admission, `common/match_manager.gd:364-365` immediately disconnects the peer. It sends neither a rejection snapshot nor an authenticated admission-rejection RPC; `client/connection_manager.gd:179` merely returns to the room screen with no message. This fails the required “remains on room controls and shows the rejection” scenario.
3. **Required scenario evidence is incomplete.** Five scenarios have no passed covering test and two have failed behavior. In particular, live authentication/admission failure, team-ready snapshot delivery, invalid-choice/unauthenticated/late RPC rejection, capacity, pre-assignment entity default, and the true CHARACTER_SELECT-inclusive phase walk are not proven. Archive readiness is blocked by the verification policy.

**WARNING**

1. The claimed 30-second complete lifecycle is not tested end-to-end: `test_full_phase_walk_order_and_ticks` starts directly with the legacy `request_match_start()`, bypassing selection.
2. Privacy tests inspect a locally constructed dictionary, not packets received by two connected clients; transport recipient isolation and absence of enemy data remain only statically evidenced.
3. GUT integration exits 0 but reports Netfox disconnect errors, 11 orphan nodes, and ObjectDB/resource leaks. The editor validation also reports duplicate UIDs and invalid `HealthViewport` paths.
4. The implementation is substantially over the planned review budget (1,308 tracked changed lines), with no actual chained review slices.

**SUGGESTION**

1. Bind redemption to a backend-issued per-provision identity derived from the provision token/OID, or use a one-time per-instance credential delivered only to the spawned process; consume the ticket only after that binding verifies.
2. Add black-box backend tests using a real transaction/test database for successful atomic consume, replay, expiry, nonce mismatch, and target-instance mismatch; add real server/client GUT coverage for RPC sender identity and private snapshot delivery.
3. Return structured admission denial before disconnection (or preserve the transport long enough for it), then render that reason in `RoomPanel`.

### Verdict

**FAIL**  
The implementation passes available commands and establishes several strong static controls, but it fails the target-server credential/nonce binding and required admission-rejection behavior. Required runtime coverage is also insufficient for archive readiness.

## Remediation Re-verification — 2026-07-29

**Verdict**: **FAIL**

### Fresh Execution Evidence

- `cd backend && go test ./... && go test -cover ./...` — PASS, 9 tests.
- GUT unit — PASS, 32/32 tests, 104 asserts.
- GUT integration — PASS, 46/46 tests, 182 asserts.
- Export isolation, quick headless-server check, Godot 4.7 headless editor load, and `git diff --check` — PASS.

### Updated Findings

**CRITICAL**

1. **Provision-instance binding has no executable trusted handoff.** `backend/cmd/server/main.go:255-263` adds a protected bind endpoint, and validation now verifies ticket, instance ID, and credential hash. However, repository-wide inspection finds no caller for the endpoint. `client/connection_manager.gd:102-109` passes only the ticket to Noray; `addons/netfox.noray/noray.gd` has no instance or credential handoff. Issued tickets remain unbound, provisioned dedicated servers fail closed, and the secure room-creation path cannot work end-to-end.
2. **Required scenario evidence remains incomplete.** Backend tests cover only malformed/missing inputs, not successful persisted bind → validate flow or wrong-instance/credential rejection. Live coverage is still absent for successful admission, ready snapshot delivery, invalid-choice and late-join RPCs, capacity, complete selected-character spawning, and a full CHARACTER_SELECT-inclusive phase walk.

**WARNING**

1. Admission rejection is remediated in source: the server sends a safe `receive_admission_rejection` RPC before disconnect and `ConnectionManager` renders `RoomStatus`; its new direct UI test passed. This is not a live client/server delivery test.
2. GUT integration still logs Netfox disconnect errors, 11 orphan nodes, and resource leaks despite a zero exit status. Godot editor validation still reports duplicate UIDs and invalid `HealthViewport` paths.

**SUGGESTION**

1. Implement the trusted provisioner boundary that calls `/bind`, creates the UUID and unique credential, and forwards all three values only to the spawned dedicated process. Add transaction-backed bind/validate success, wrong-instance, wrong-credential, replay, and expiry tests.
2. Add live multi-peer coverage for admission/rejection delivery, private snapshots, capacity, late joins, valid selections/spawn, and the complete phase map.

## Cross-Repository Final Re-verification — 2026-07-29

**Verdict**: **FAIL**

### Trust-chain Evidence

- Noray now creates a UUID plus a fresh 32-byte base64url credential per request, binds the opaque ticket using its provisioner credential **before** spawning, and injects the runtime credential only through the child environment. The ticket and instance UUID are command-line args; the credential is not.
- Noikar backend persists only the credential hash and atomically redeems only matching ticket, instance UUID, and credential before ENet setup. Existing host, safe admission-rejection UI, private snapshot, timeout, and disconnect code remains present.
- Targeted Noray provisioning tests: **5/5 passed**. They prove bind-before-spawn, bind failure prevents spawning, and the credential is passed in child environment rather than arguments.
- Noikar Go tests: **9/9 passed**. Godot unit: **32/32 passed**. Godot integration: **46/46 passed**. Export isolation and quick headless checks passed.

### Issues Found

**CRITICAL**

1. **The configured Noray full test command fails.** `npm test` exits non-zero because `node --test test/spec/` cannot resolve the configured directory. Verification cannot claim a full Node suite pass while the repository's declared test command is broken.
2. **The backend does not have runtime persistence coverage for the trust-chain success/failure contract.** The Go tests do not execute bind → validate against ticket storage, nor prove wrong-instance, wrong-credential, one-time replay, or expiry behavior through the database transaction. The targeted Node test uses a mocked bind callback, so it cannot cover backend persistence.
3. **Several required lobby scenarios remain without passing covering tests**: live authenticated admission, multi-peer ready/private snapshot delivery, invalid/late RPC action, capacity, valid selection causing spawned selected characters, and a phase walk that includes CHARACTER_SELECT.

**WARNING**

1. The targeted Node provisioning test passes, but `rtk lint` fails on two unrelated legacy `is.ci.js` style errors. GUT continues to emit Netfox cleanup errors, 11 orphans, and resource leaks despite passing assertions.
2. The credential is correctly absent from spawn arguments, but command-line ticket and instance ID remain observable to the local process host; their security relies on the per-instance credential and single-use backend record.

**SUGGESTION**

1. Repair the Noray `npm test` path and make the targeted provisioning test part of the passing default suite.
2. Add database-backed backend tests and live multi-peer Godot tests for every remaining required scenario before archive.

## Final Verification Blocker Remediation — 2026-07-29

### Completed

- `../noikar-noray` now discovers spec files recursively in a small Node runner, so `npm test` succeeds on Node 26 without shell glob semantics. **144/144 tests pass.**
- Backend bind/redeem SQL is now named and covered by a deterministic SQL-atomicity test. It verifies the bind predicate permits only unbound, unused, unexpired tickets and the redeem predicate requires the matching instance UUID and credential hash while atomically marking the ticket used and returning the account.

### Environment Limitations

- PostgreSQL integration could not run: Docker is not installed and no test database URL/service is available. The SQL harness proves the security predicates remain coupled in one `UPDATE`; it does **not** prove PostgreSQL execution, row locking, or HTTP behavior against persisted rows. A real PostgreSQL test still must prove bind → redeem success, replay, wrong instance, wrong credential, and expiry.
- Live multi-peer coverage remains blocked: the available GUT runner runs a single Godot process, while the required test needs an independent authenticated server plus two ENet/Netfox clients and a running backend. There is no Docker/PostgreSQL service for authentication. Existing integration coverage remains 46/46, but it is not evidence for cross-process admission or recipient transport isolation.

### Current Verdict

**PARTIAL / NOT ARCHIVE-READY.** The Node command blocker is resolved and SQL predicates have deterministic coverage. Database-backed behavior and live multi-peer ENet/Netfox scenarios remain required before archive.
