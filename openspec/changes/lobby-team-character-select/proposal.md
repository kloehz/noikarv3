# Proposal: Server-Authoritative Team Lobby and Character Selection

## Intent

Move character choice out of authentication and into a server-authoritative pre-match flow. Players can see and ready only their own team; the server must prevent enemy roster and selection data from being delivered before gameplay begins.

## Scope

### In Scope
- Authentication-only first screen, then create/join, lobby team presentation, ready controls, and a keyboard/gamepad-navigable Aatrox/Ivern selection grid.
- Server-owned authenticated lobby records, deterministic teams in `LOBBY`, host election, validation, roster churn, and team-scoped reliable snapshots.
- A tick-counted 30-second `CHARACTER_SELECT` phase; defer player/gameplay spawning until every frozen-roster member is selection-ready.

### Out of Scope
- Matchmaking, spectators, reconnect after selection starts, new characters, or boss/gameplay changes.
- Netfox visibility-filter architecture; this slice uses private RPC snapshots.

## Capabilities

### New Capabilities
- `lobby-team-character-select`: Private, server-authoritative lobby readiness and character-selection workflow.

### Modified Capabilities
- `match-lifecycle`: Add `CHARACTER_SELECT`, its deadline, and pre-launch spawn gating.
- `team-identity`: Apply deterministic lobby assignment and freeze the selected roster before launch.

## Approach

`MatchManager` holds a server-only record per authenticated peer: name, assigned team, lobby-ready, selection, selection-ready, and host. A protected auth endpoint issues a short-lived, single-use cryptographically random opaque room-creator handle; the backend persists only its hash. The trusted provisioner binds that handle to its concrete server-instance ID and per-instance world credential before process launch. Noray transports only the handle. The dedicated server redeems only with its runtime-only instance ID and credential before ENet admission.

Clients cannot assign host identity. A missing, invalid, expired, or replayed ticket prevents the dedicated server from accepting the provisioned room. In `LOBBY`, a disconnect clears readiness and recomputes teams without transferring host. In `CHARACTER_SELECT`, a frozen-roster disconnect or deadline expiry returns to `LOBBY`, clears readiness/selections, and spawns nothing. Late joins are rejected after selection starts.

## Affected Areas

| Area | Impact | Description |
|---|---|---|
| `common/match_manager.gd` | Modified | Private roster, RPC authority, snapshots, deferred spawn |
| `common/match_director.gd`, `common/match_state.gd` | Modified | Selection phase and deadline |
| `client/connection_manager.gd`, `scenes/connection_menu.tscn` | Modified | Composed lobby/selection UI and focus |
| `common/resources/match_rules.gd` | Modified | 30-second tick conversion |
| `tests/unit/`, `tests/integration/` | Modified | Authority, privacy, churn, timer, spawn tests |

## Validation Boundaries

- Server tests must prove unauthenticated, wrong-phase, non-host, invalid-choice, and late-join requests cannot mutate state.
- Snapshot tests must prove no enemy names, peer IDs, readiness, or selections are serialized; no player entity exists before launch.
- Phase tests must prove 30-second tick expiry and selection disconnect return to `LOBBY` without map/player spawn.

## Risks and Rollback Plan

| Risk | Mitigation / rollback |
|---|---|
| Private data leaks through global state or spawned entities | Keep records server-only; defer spawning; revert the change as one unit if payload tests fail. |
| Creator-ticket provisioning fails | Fail closed before ENet admission; provisioner must forward only `--room-creator-ticket`, never account IDs. |
| Lifecycle regression from new phase/spawn gate | Restore the prior transition/spawn path by reverting the feature slices; retain existing smoke checks. |

## Delivery Forecast

Two review slices are required: (1) server lifecycle, privacy boundaries, and tests; (2) scene-composed UI and end-to-end wiring.

Decision needed before apply: No
Chained PRs recommended: Yes
400-line budget risk: High

## Success Criteria

- [ ] Only the server can change lobby, host, team, readiness, or selection state.
- [ ] Each client receives and renders only its own team's private snapshot.
- [ ] All-ready launches with selected characters; expiry/disconnect returns safely to `LOBBY`.
