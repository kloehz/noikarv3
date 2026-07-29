# Tasks: Server-Authoritative Team Lobby and Character Selection

## Review Workload Forecast

| Field | Value |
|---|---|
| Estimated changed lines | 650–850 across server, UI, and GUT coverage |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 server contract → PR 2 client composition |
| Delivery strategy | auto-forecast → auto-chain |
| Chain strategy | feature-branch-chain |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: feature-branch-chain
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|---|---|---|---|
| 1 | Server-authoritative lobby lifecycle | PR 1 | Base: feature/tracker; start: baseline; finish: safe, private selection contract; verify GUT + smoke; rollback: revert PR 1. |
| 2 | Snapshot-driven client lobby and selection UI | PR 2 | Base: PR 1 branch; start: server snapshot contract; finish: focusable four-step UI; verify GUT + smoke; rollback: revert PR 2 only. |

## Phase 1: Server Contract and Lifecycle (PR 1)

- [x] 1.1 Extend `common/resources/match_rules.gd` and `common/resources/default_match_rules.tres` with `character_select_sec = 30.0`; validate headless defaults and 1,800-tick conversion in `tests/unit/test_match_rules.gd`.
- [x] 1.2 Add `CHARACTER_SELECT` and synchronized `selection_deadline_tick` to `common/match_state.gd`; validate phase/deadline serialization in `tests/unit/test_match_state.gd`.
- [x] 1.3 Update `common/match_director.gd` for frozen-roster start, exact-deadline/disconnect cancellation, and all-ready launch; validate mapped transitions and no spawn on cancellation in `tests/integration/test_match_director_phases.gd`.
- [x] 1.4 Implement authenticated records, deterministic capacity/team/host assignment, validated lobby RPCs, recipient-only snapshots, and deferred selected-character spawn in `common/match_manager.gd`; validate auth, sender, phase, host, choice, late-join, privacy, churn, and spawn gate in new `tests/integration/test_lobby_team_character_select.gd`.
- [x] 1.5 Run PR-1 validation: configured unit and integration GUT suites, `python3 tests/verify_export_isolation.py`, and `python3 tests/verify_headless_server.py --quick`; keep the diff at or below 400 lines or split its tests with their behavior.

## Phase 2: Client Composition and Wiring (PR 2)

- [x] 2.1 Add `lobby_snapshot_received(snapshot)` to `common/event_bus.gd` and route `receive_lobby_snapshot` through `client/connection_manager.gd`; validate the UI renders only the latest private snapshot and never derives authority.
- [x] 2.2 Recompose `scenes/connection_menu.tscn`: authentication, room controls, Inspector-configured `LobbyPanel`, and `CharacterSelectPanel` with roster, status, deadline, and Aatrox/Ivern grid; validate scene load and no procedural constant-node setup.
- [x] 2.3 Update `client/connection_manager.gd` to bind panel visibility, ready/start/select actions, rejection status, and explicit keyboard/gamepad focus neighbors; validate authenticated admission, rejected room entry, host-only start visibility, and selection navigation in `tests/integration/test_lobby_team_character_select.gd`.
- [x] 2.4 Run PR-2 validation: relevant GUT suites plus both Python smoke checks; inspect the child diff against the PR-1 branch, keep it at or below 400 lines, and roll back only UI wiring if presentation regresses.

## Phase 3: Review Blocker Remediation

- [x] 3.1 Restrict host authority to a provisioning-attested room-creator account; reject unprovisioned host claims and duplicate authenticated accounts.
- [x] 3.2 Subscribe roster cleanup to `NetworkEvents.on_peer_leave`; clear frozen state after launch and safely rebuild LOBBY state.
- [x] 3.3 Render server-confirmed ready state with `set_pressed_no_signal` and add authority, duplicate-account, peer-leave, wrong-phase, and UI-snapshot coverage.

## Phase 4: Provisioning and Lifecycle Review Remediation

- [x] 4.1 Superseded by 5.2: creator identity now travels only in a backend-attested ticket, never as a raw account ID.
- [x] 4.2 Add CHARACTER_SELECT peer-leave cancellation, public selection-handler authority/phase, and selection-ready snapshot rendering coverage.

## Phase 5: Backend-Attested Creator Ticket

- [x] 5.1 Superseded by 6.1: backend issue/validation uses opaque random handles, not signed ticket claims.
- [x] 5.2 Replace raw account-ID Noray provisioning with a creator ticket; fail closed before dedicated ENet admission on missing, invalid, expired, or replayed tickets.
- [x] 5.3 Bind host status to the JWT account matching the backend-validated ticket; cover ticket signing, forgery, expiry, missing authentication, missing ticket, and Godot ticket propagation.

## Phase 6: Opaque Creator Handle Remediation

- [x] 6.1 Replace creator-ticket JWT claims/signing with cryptographically random opaque handles and persistence-only hashes.
- [x] 6.2 Atomically validate hash, expiry, and one-time consumption before returning account identity only to the dedicated server.
- [x] 6.3 Cover opaque payload, tampering, missing ticket/authentication, expiry/replay query guards, and remove raw account data from Noray provisioning contracts.

## Phase 7: Dedicated Server Redemption Guard

- [x] 7.1 Require a dedicated-only world-server credential for creator-handle validation and keep it out of normal clients.
- [x] 7.2 Bind handle redemption to the provision nonce and fail closed on missing credential, nonce mismatch, expiry, use, or invalid handle.
- [x] 7.3 Add unauthenticated and wrong-server credential coverage; document the dedicated runtime credential and nonce contract.

## Phase 8: Verification Remediation

- [x] 8.1 Bind creator-handle redemption to a provisioner-attested concrete instance ID and per-instance world credential.
- [x] 8.2 Send safe admission rejection before disconnect and display it on room controls.
- [x] 8.3 Add focused runtime coverage and refresh available validation evidence.

### Cross-Repository Provisioner Evidence

- `../noikar-noray` now binds the opaque creator ticket before spawning, generates a UUID instance ID and per-instance credential, passes the ticket/ID as Godot arguments, and supplies the credential only through `NOIKAR_WORLD_SERVER_CREDENTIAL`. Its focused provisioning tests and complete spec suite pass.

## Phase 9: Final Verification Blockers

- [x] 9.1 Make the Noray `npm test` command portable on Node 26 and preserve the full spec suite.
- [x] 9.2 Add PostgreSQL-backed creator-ticket bind/redeem coverage, or a deterministic SQL-atomicity harness when PostgreSQL is unavailable; document the limitation.
- [ ] 9.3 Add live multi-peer ENet/Netfox lobby-flow coverage for admission, private snapshots, selection launch, timeout, and peer-leave cancellation.
