# Delta for match-lifecycle

New capability: server-authoritative match phase machine with replicated state, deterministic tick-counted timing, and behavior-preserving spawn routing. Server owns transitions; clients observe replicated state.

## ADDED Requirements

### Requirement: Phase Model and Transition Map

The match MUST have exactly the phases LOBBY, COUNTDOWN, ROUND_SETUP, PVE_RACE, BOSS_LOCK, BOSS_DEPLOY, BOSS_A1, RESULT, POST_MATCH, with only these transitions:

| From → To | Driver |
|---|---|
| LOBBY → COUNTDOWN | event: minimum roster reached (stub) |
| COUNTDOWN → ROUND_SETUP | timer: `countdown_sec` |
| ROUND_SETUP → PVE_RACE | event: match_seed assigned + initial spawns done |
| PVE_RACE → BOSS_LOCK | event: stub condition |
| BOSS_LOCK → BOSS_DEPLOY | event: stub condition |
| BOSS_DEPLOY → BOSS_A1 | timer: `boss_deploy_countdown_sec` |
| BOSS_A1 → RESULT | event: stub condition |
| RESULT → POST_MATCH | timer: `result_display_sec` |
| POST_MATCH → LOBBY | event: reset complete |

Timer durations MUST come from MatchRules.

#### Scenario: Full phase walk

- GIVEN a headless 2-team server with stub hooks
- WHEN a match runs to completion
- THEN phases occur in exactly the mapped order

### Requirement: Server-Authoritative Director Outside Rollback

The phase machine MUST be a server-driven scene node; clients MUST NOT run transition logic. It MUST NOT participate in rollback — no rollback tick handling, and no director code reachable from any entity `_rollback_tick` path. All timing MUST be tick-counted via NetworkTime at tickrate 60 (seconds → ticks); it MUST NOT use SceneTreeTimer, wall-clock, or `randi`/`randf`.

#### Scenario: Rollback purity

- GIVEN any entity rollback resimulation
- WHEN `_rollback_tick` call chains are traced
- THEN no match phase code executes

### Requirement: Replicated MatchState

Match state MUST live on a server-owned node (authority 1) replicating via StateSynchronizer (pattern: common/components/ServerState.gd:63-85): phase, phase_entered_tick, match_seed, team score stubs, winner. The director MUST be the sole writer. Client `phase_changed` signals MUST fire only on real value change — late-join catch-up emits none.

#### Scenario: Late-join catch-up is silent

- GIVEN a match in PVE_RACE
- WHEN a client joins and receives full state
- THEN it observes PVE_RACE with no `phase_changed` burst for replayed values

### Requirement: Deterministic Match Seed

The server MUST assign a real `match_seed` at ROUND_SETUP (replacing the reserved placeholder, match_manager.gd:28) and replicate it to all peers. Same seed + same peer roster MUST produce identical transition order and tick timings.

#### Scenario: Same seed, same timings

- GIVEN two headless runs with the same roster and seed
- WHEN both walk LOBBY → POST_MATCH
- THEN every transition occurs on the same tick in both runs

### Requirement: Match Lifecycle Events

`match_started` MUST fire once on entry into PVE_RACE; `match_ended(winner_id)` once on entry into RESULT (declared: common/event_bus.gd:21-23). `phase_changed(phase)` MUST fire on every effective phase entry; `team_assigned` MUST fire when LOBBY assignment completes.

#### Scenario: Event timing

- GIVEN a running match
- WHEN it enters PVE_RACE and later RESULT
- THEN `match_started` and `match_ended` each fire exactly once

### Requirement: Behavior-Preserving Spawn Routing

Entities MUST spawn under typed containers (Players, Mobs, Minions, Souls, Totems, Boss, plus existing Projectiles), each with its own MultiplayerSpawner (pattern: scenes/main.tscn:21-29). Existing solo/free-play flows MUST work unchanged, and entity name-prefix conventions MUST be preserved — group detection keys off them (BaseEntity.gd:47-52).

#### Scenario: Solo/free play unchanged

- GIVEN a single client connecting as today
- WHEN they spawn and play
- THEN spawning, soul, totem, and mob flows behave identically to pre-change

#### Scenario: Group detection intact

- GIVEN entities spawned under the new containers
- WHEN BaseEntity assigns groups
- THEN group names match pre-change values

### Requirement: Explicit Exclusions

This capability MUST NOT implement boss combat, gate logic, late-join policy, or gameplay effects of phases — stubs only from BOSS_LOCK onward.

#### Scenario: Stub-only post-race phases

- GIVEN a match reaches BOSS_LOCK with no boss content
- WHEN stub conditions are met
- THEN phases transition without any boss entity existing
