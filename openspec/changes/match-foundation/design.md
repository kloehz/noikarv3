# Design: Match Foundation (Roadmap Stage 2)

## Technical Approach

Architecture A: `MatchState` (authority 1) + child `StateSynchronizer` replicates the match snapshot; `MatchDirector` (server-only) is the sole writer — both scene children of `Main`, mirroring `ServerState.gd:63-85` at match scope. Timing is tick-counted via `NetworkTime.after_tick` @60Hz; no rollback, no `SceneTreeTimer`/`randi`/wall-clock.

## Architecture Decisions

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Late-join setter guard | (a) Every setter guards `if x == v: return` — `_PropertySnapshot.apply()` writes unconditionally every tick on clients; (b) `_signals_armed` on non-authority: setters skip emitting until a one-shot `NetworkTime.after_tick_loop` callback arms them. Catch-up lands in loop one, before arming → no `phase_changed` burst. | Guards alone can't suppress first applied value (LOBBY→PVE_RACE is a real change). |
| 2 | Seconds→ticks | `roundi(seconds * NetworkTime.tickrate)`, min 1 tick, computed once at phase entry via `MatchRules.seconds_to_ticks()`. | Rounding absorbs float error; one helper = one convention. |
| 3 | Director placement | Scene children of `Main` (siblings of `Players`); scene-lifetime (matches loop POST_MATCH→LOBBY in place). Discovery: group `match_director` (like `match_manager`); MatchManager uses group lookup + `has_method` guard. Roster from `multiplayer.get_peers()` + peer 1; clients skip tick hookup. | Existing group convention; no autoload state-leak on rematch. |
| 4 | MatchState shape | Replicated: `phase: int` (nested `enum Phase`, 9 phases, LOBBY=0), `phase_entered_tick`, `match_seed`, `team_red_score`/`team_blue_score` (stubs 0), `winner` (TeamId, NONE=0). Roster stays server-only on the director; clients derive entity team from `ServerState.team_id`. | Minimal surface; roster replication unneeded until Stage 3. |
| 5 | Containers/spawners | Real: `Players`, `Mobs`, `Souls`, `Totems` (spawnable: TotemEntity + PetEntity), `Projectiles` (existing). Stubs: `Minions`, `Boss` — empty Node3D + spawner with empty `_spawnable_scenes`. One spawner per container (main.tscn:21-29). Current spawners carry no spawn-property config → Stage 1 risk is verification-only. | Pets under `Totems` keeps `Players` human-only; stubs avoid future scene re-edits. |
| 6 | Team assignment | Server, LOBBY only: peer ids sorted ascending (host 1 included), even index→RED, odd→BLUE; odd roster → RED +1. **Full recompute** on any connect/disconnect during LOBBY, then update spawned players' `ServerState.team_id`, re-emit `team_assigned`. Roster freezes after LOBBY. | Full recompute guarantees same peer set → same assignment regardless of join order. |
| 7 | Transitions | Stub events are public server-only methods (`request_match_start()`, `request_boss_lock()`, `request_boss_a1_end()`); Stage 3+ wires real conditions. Seed at ROUND_SETUP: `match_seed = seed_base + match_index` (`@export seed_base: int = 0`) — deterministic, test-injectable, feeds `_next_spawn_id`. POST_MATCH→LOBBY = internal next-tick reset. | Stubs are explicit seams, not hidden timers. |
| 8 | Determinism proof | Timing core is pure `tick_update(tick: int)` (driven by `NetworkTime.after_tick` in game). GUT test runs the director with `OfflineMultiplayerPeer`, injects roster via seam, drives synthetic ticks, fires stubs in order, records `(phase, tick)` log; two runs with same roster+`seed_base` must yield identical logs. | Tests logic, not netfox scheduling. |

## Data Flow

```
NetworkTime.after_tick ─→ MatchDirector.tick_update(tick)   [server only]
                              │ timer expiry / stub event
                              ▼
                   _enter_phase(p): MatchState.phase / phase_entered_tick = tick
                                    EventBus.phase_changed.emit(p)
                              │ StateSynchronizer broadcast
                              ▼
            clients: snapshot apply → setter guard → (armed?) phase_changed

LOBBY ─stub→ COUNTDOWN ─180t (3.0s)→ ROUND_SETUP ─seed assigned→ PVE_RACE
(match_started) ─stub→ BOSS_LOCK ─stub→ BOSS_DEPLOY ─180t→ BOSS_A1 ─stub→
RESULT (match_ended(NONE)) ─600t (10.0s)→ POST_MATCH ─reset→ LOBBY
```

## File Changes

| File | Action | Slice | Description |
|------|--------|-------|-------------|
| `common/team_id.gd` | Create | PR1 | `class_name TeamId`, enum NONE/RED/BLUE, pure helpers |
| `common/resources/match_rules.gd` + `default_match_rules.tres` | Create | PR1 | Schema-complete Resource + `seconds_to_ticks()` |
| `common/components/ServerState.gd` | Modify | PR1 | Guarded `team_id` export + `add_state` |
| `common/match_state.gd` | Create | PR2 | Replicated props, armed-signal setters |
| `common/match_director.gd` | Create | PR2 | Phase machine, timers, team assignment, stubs |
| `scenes/main.tscn` | Modify | PR2 | `MatchState`+`StateSynchronizer`+`MatchDirector` nodes |
| `common/event_bus.gd` | Modify | PR2 | `phase_changed(phase: int)`, `team_assigned` |
| `scenes/main.tscn` | Modify | PR3 | Containers Mobs/Souls/Totems/Minions/Boss + 5 spawners |
| `common/match_manager.gd` | Modify | PR3 | Spawn routing (prefixes unchanged); `set_match_seed`; `team_id` on `_spawn_player` |
| `common/match_director.gd` | Modify | PR3 | Team registry in spawn order + register/unregister (no caps) |
| `tests/unit/test_team_id.gd`, `test_match_rules.gd` | Create | PR1 | Helper purity; locked defaults |
| `tests/unit/test_match_state.gd` | Create | PR2 | Setter guards; armed-signal behavior |
| `tests/integration/test_match_director_phases.gd` | Create | PR2 | Phase walk; determinism (identical logs) |
| `tests/integration/test_spawn_routing.gd` | Create | PR3 | Containers; group names; team_id replication; registry order |

## Interfaces / Contracts

```gdscript
# MatchDirector (server-only)
func tick_update(tick: int) -> void           # driven by NetworkTime.after_tick
func request_match_start() -> void            # stub: LOBBY→COUNTDOWN
func request_boss_lock() -> void              # stub: PVE_RACE→BOSS_LOCK→BOSS_DEPLOY
func request_boss_a1_end() -> void            # stub: BOSS_A1→RESULT
func get_team(peer_id: int) -> TeamId.Value
func register_to_team(team: TeamId.Value, spawn_id: StringName) -> void     # PR3
func unregister_from_team(team: TeamId.Value, spawn_id: StringName) -> void # PR3
```

`MatchState` is never reachable from any `_rollback_tick` path; the director is reachable only via group/EventBus.

## Testing Strategy

Unit (GUT headless, no network): TeamId purity, MatchRules locked values, MatchState setter guards. Integration (GUT + `OfflineMultiplayerPeer`, synthetic ticks): phase walk order/timings, determinism, solo play unchanged, group names, team_id replication, silent late-join.

## Migration / Rollout

No migration. **PR1** ships data only (team_id stays NONE). **PR2** adds scene nodes + phase machine; roster computed but not pushed to entities. **PR3** is the only behavioral refactor (routing + team_id + registry). Rollback: revert PR3→PR1.

## Open Questions

- None blocking. `forfeit_disconnect_sec` is schema-only in Stage 2.
