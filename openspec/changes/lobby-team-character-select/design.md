# Design: Server-Authoritative Team Lobby and Character Selection

## Technical Approach

`MatchManager` owns authenticated lobby records and recipient-specific snapshots. `MatchDirector` owns deterministic phase/deadline transitions. `MatchState` replicates only phase and the non-sensitive deadline. No player spawns until every frozen member is selection-ready.

## Architecture Decisions

| Decision | Alternatives considered | Rationale |
|---|---|---|
| Keep lobby records only in `MatchManager` | Replicate roster through `MatchState`/entity state | Private records cannot leak through global Netfox snapshots or pre-launch entities. |
| Bind opaque creator handle to provisioner-issued server instance | Player JWT; client nonce; shared credential | The trusted provisioner assigns an instance ID and per-instance credential, backend persists their binding, and only that launched process can atomically redeem the handle. |
| Use reliable `rpc_id()` team snapshots | Broadcast RPC; Netfox visibility filtering | Recipient routing makes enemy roster serialization impossible in this slice. |
| Tick deadline in `MatchDirector` | `SceneTreeTimer`; client clock | `rules.seconds_to_ticks(30.0)` is deterministic (1,800 ticks at 60 Hz) and testable headlessly. |

## State and Data Flow

Server record, never synchronized:

```gdscript
var _lobby: Dictionary[int, Dictionary] # peer_id -> {
    "account_id": String, "name": String, "team": int, "lobby_ready": bool,
    "character_id": String, "selection_ready": bool, "is_host": bool
}
var _frozen_peer_ids: Array[int]
```

After authenticated creation, the client requests an opaque backend room-creator handle and passes it through Noray. The trusted provisioner calls the protected bind endpoint with the handle, a concrete instance ID, and a unique per-instance world credential, then starts that dedicated process with `--room-creator-ticket`, `--provision-instance-id`, and the runtime-only credential. `GameManager` uses all three to redeem the handle at the backend before opening ENet. After JWT validation, the server adds the record. In `LOBBY`, it sorts IDs, rejects admission at `2 * max_players_per_team`, alternates RED/BLUE, marks host only when the validated handle account matches, clears readiness on churn, and sends each member its team only.

```
UI action -> MatchManager RPC -> server validation/mutation -> rpc_id(snapshot)
                                                 |                     |
                                           MatchDirector          EventBus client signal
                                                 |                     v
                                          MatchState phase    ConnectionManager renders
```

`MatchDirector` adds `CHARACTER_SELECT`; at entry it sets `selection_deadline_tick = entered_tick + rules.seconds_to_ticks(rules.character_select_sec)` in `MatchState`. On every server `tick_update`, `tick >= deadline` cancels selection exactly at the deadline. Before that tick, only a complete valid frozen roster may advance to `COUNTDOWN`. Cancellation clears frozen IDs, readiness, and choices; it returns to `LOBBY` and sends fresh snapshots. A frozen-member disconnect follows the identical cancellation path. Lobby disconnects recompute membership/host and clear readiness. Neither path spawns players.

## Interfaces / Contracts

| Direction | Reliable boundary | Server rule |
|---|---|---|
| Client -> server | `_submit_auth_token_to_server(token)` | Existing JWT admission; create record only after acceptance. |
| Client -> backend | `POST /api/v1/rooms/creator-ticket` | Protected access JWT issues a short-lived signed ticket. |
| Dedicated server -> backend | `POST /api/v1/rooms/creator-ticket/validate` | Requires `X-World-Server-Credential`, matching provision nonce, then atomically consumes a valid handle and returns its bound account ID. |
| Client -> server | `request_lobby_ready(ready)` | Sender must be authenticated, in `LOBBY`, and mutate only its record. |
| Client -> server | `request_character_select_start()` | Sender must be current authenticated host and every record lobby-ready. |
| Client -> server | `request_character_selection(character_id, ready)` | Sender must be frozen, in `CHARACTER_SELECT`; ID must be `warrior` or `ivern_ranger`; ready requires a valid choice. |
| Server -> client | `receive_lobby_snapshot(snapshot)` via `rpc_id(peer_id, ...)` | Payload contains `phase`, `deadline_tick`, recipient `team`/`is_host`, and same-team `{name, lobby_ready, character_id, selection_ready}` only—never enemy or self/enemy peer IDs. |

The receiving RPC emits client-local `EventBus.lobby_snapshot_received(snapshot)`; `ConnectionManager` renders it and never derives authority. `MatchState` adds `CHARACTER_SELECT` and `selection_deadline_tick` to `StateSynchronizer`, with no roster data. After launch, `MatchManager` initializes `ServerState` from frozen team and character values.

## UI Scene Composition

Keep `ConnectionMenu` as a `CanvasLayer`. Remove login `CharacterSelect`; retain login then room controls. Add Inspector-composed `LobbyPanel` team roster, ready/start/status controls, and `CharacterSelectPanel` deadline, Aatrox/Ivern button grid, ready control, and roster. Use containers, scene-wired signals, and explicit focus neighbors; scripts bind snapshots and dynamic rows only.

## File Changes

| File | Action | Description |
|---|---|---|
| `common/match_manager.gd` | Modify | Authenticated lobby authority, private RPCs/snapshots, deferred spawn. |
| `common/match_director.gd`, `common/match_state.gd` | Modify | Selection transition, deadline, launch/cancel seams. |
| `common/resources/match_rules.gd`, `default_match_rules.tres` | Modify | `character_select_sec = 30.0`. |
| `common/event_bus.gd` | Modify | Client-local snapshot signal. |
| `client/connection_manager.gd`, `scenes/connection_menu.tscn` | Modify | Four-step, focusable lobby/selection presentation. |
| `tests/unit/test_match_rules.gd`, `test_match_state.gd`; `tests/integration/test_match_director_phases.gd`, new lobby tests | Modify/Create | Timer, validation, privacy, churn, and spawn-gate coverage. |

## Testing Strategy

| Layer | What to test | Approach |
|---|---|---|
| Unit | Tick conversion, phase enum/deadline, snapshot serializer | GUT synthetic ticks and direct records. |
| Integration | Host/auth/phase/choice validation; capacity; disconnect/timeout; zero pre-launch players | Offline peers and manager/director harness. |
| Smoke | Export isolation and headless startup | Existing Python commands; run GUT when Godot is available. |

## Rollout and Chained Delivery

**Slice 1 — server contract (target: <=400 changed lines):** lifecycle/rules/state, manager records/RPC privacy, and focused tests. Roll back by reverting this slice; old immediate authenticated spawn returns intact.

**Slice 2 — client composition (target: <=400 changed lines):** scene/UI controller and snapshot wiring tests, targeting slice 1. Roll back independently by reverting slice 2; server remains safe but its lobby is non-presentational. Retarget/rebase child diffs so each PR exposes only its slice.

No migration or feature flag is required.

## Open Questions

None.
