# Tasks: Match Foundation (Roadmap Stage 2)

## Review Workload Forecast

Estimated changed lines: ~850-950 (PR1 ~220, PR2 ~380, PR3 ~350)
Delivery strategy: auto-chain
Suggested split: PR1 team-rules-data → PR2 match-director → PR3 spawn-routing

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | PR / branch | Base |
|------|------|-------------|------|
| 1 | TeamId + MatchRules data | `feature/match-foundation-team-rules` | `feature/tickrate-speed-calibration`; additive, team_id stays NONE |
| 2 | MatchState + MatchDirector | `feature/match-foundation-director` | PR1 branch |
| 3 | Spawn routing + team wiring | `feature/match-foundation-spawn-routing` | PR2 branch; only behavioral refactor |

Standard mode (strict_tdd: false): tests ship with the code they verify.

## Phase 1: Team & Rules Data (PR1)

- [x] 1.1 Create `common/team_id.gd`: `class_name TeamId`, enum NONE/RED/BLUE (NONE=0), pure helpers (opposite, name, color).
- [x] 1.2 Create `common/resources/match_rules.gd` Resource, all locked fields + `seconds_to_ticks()` (`roundi(seconds * NetworkTime.tickrate)`, min 1 tick).
- [x] 1.3 Create `common/resources/default_match_rules.tres` with locked values (boss 10000/6000, souls 2, window 1.5, minions 3/1, totem 4/2/1 + 8.0/30.0/6.0, players 3, 3.0/3.0, 10.0/30.0).
- [x] 1.4 Add guarded `team_id` export (default NONE) + `add_state` in `common/components/ServerState.gd` (lines 63-85 pattern).
- [x] 1.5 GUT unit `tests/unit/test_team_id.gd` (purity, zero value) + `test_match_rules.gd` (locked defaults; tick rounding/min-1).
- [x] 1.6 Gate: GUT unit suite green; compiles standalone; team_id stays NONE.

## Phase 2: MatchState + MatchDirector (PR2)

- [x] 2.1 Create `common/match_state.gd`: authority 1, nested `enum Phase` (9, LOBBY=0); replicated `phase`, `phase_entered_tick`, `match_seed`, score stubs, `winner`; setter value-guards + `_signals_armed` (one-shot `NetworkTime.after_tick_loop` on non-authority).
- [x] 2.2 Create `common/match_director.gd`: pure `tick_update(tick)`; timers 180t/180t/600t via MatchRules; stubs `request_match_start()`/`request_boss_lock()`/`request_boss_a1_end()`; `match_seed = seed_base + match_index` at ROUND_SETUP; LOBBY assignment (sorted peers, alternate, full recompute); POST_MATCH→LOBBY reset.
- [x] 2.3 Add MatchState + StateSynchronizer + MatchDirector to `scenes/main.tscn` under Main; `match_director` group; server-only `NetworkTime.after_tick` hookup.
- [x] 2.4 Extend `common/event_bus.gd`: `phase_changed(phase: int)`, `team_assigned`; `match_started` once at PVE_RACE, `match_ended(NONE)` once at RESULT.
- [x] 2.5 GUT unit `tests/unit/test_match_state.gd`: setter guards; armed-signal suppresses catch-up burst (late-join silent).
- [x] 2.6 GUT integration `tests/integration/test_match_director_phases.gd`: `OfflineMultiplayerPeer` + synthetic ticks + injected roster; 2-team walk LOBBY→POST_MATCH in exact order; two runs → identical (phase, tick) logs; silent late-join (no spurious `phase_changed`).
- [x] 2.7 Gate: all GUT suites green; determinism proven; no director code reachable from `_rollback_tick`.

## Phase 3: Spawn Routing + Team Wiring (PR3)

- [ ] 3.1 `scenes/main.tscn`: containers Mobs/Souls/Totems (spawnable Totem+Pet) + stub Minions/Boss (empty Node3D + spawner, empty `_spawnable_scenes`); one MultiplayerSpawner each; verify spawn-property configs.
- [ ] 3.2 Refactor `common/match_manager.gd` spawn routing into typed containers — name prefixes identical (MOB_/ELITE_/PET_/SOUL_/TOTEM_, int peer names); behavior-preserving.
- [ ] 3.3 Add `set_match_seed` to MatchManager; wire ROUND_SETUP seed into `_next_spawn_id`; set `team_id` on `_spawn_player` from roster.
- [ ] 3.4 Add spawn-sequence-ordered team registry to `common/match_director.gd` (`register_to_team`/`unregister_from_team`, no caps); MatchManager uses group lookup + `has_method` guard.
- [ ] 3.5 GUT integration `tests/integration/test_spawn_routing.gd`: typed containers; BaseEntity name-prefix groups match pre-change; team_id replicates to clients; deterministic registry order; solo/free play unchanged.
- [ ] 3.6 Gate: all GUT suites green; `tests/verify_headless_server.py --quick` green.
