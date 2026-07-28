# Exploration: Match Foundation (Roadmap Stage 2)

## Current State

### How match lifecycle works today

- **Autoloads** (`project.godot:18-30`): `EventBus`, `GameManager`, plus netfox autoloads (`NetworkTime`, `NetworkRollback`, `Noray`, …). There is **no match autoload**.
- **`common/game_manager.gd`** (autoload): environment detection (`_is_headless_environment()`, lines 18-21), Noray registration and ENet server creation (lines 23-88). Emits `EventBus.server_started`. Knows nothing about matches/phases/teams.
- **`common/match_manager.gd`** (Node3D, root script of `scenes/main.tscn`, group `match_manager`): the de-facto god object today. It owns:
  - Player spawn/despawn on peer connect/disconnect (lines 115-129, `_spawn_player` 395-416). Players spawn at `randf_range` positions immediately on connect — **no lobby/phase concept**.
  - Test mob spawning on server start (lines 54-66) and mob respawn after death (lines 207-218, `SceneTreeTimer`-based).
  - Soul drop on mob death (lines 196-197, 228-235), elite-mob chance on soul expiry (lines 237-270, `randf`).
  - Totem request/validation + pet summon chain (lines 272-367), RPC entry `spawn_totem_rpc` (369-393).
  - Server auto-shutdown on empty room (134-165).
  - **Stable spawn IDs already exist**: `_next_spawn_id(prefix)` (lines 34-36), format `{PREFIX}_{seed_hex}_{seq}`, with `match_seed: int = 0` explicitly deferred to Stage 2 (line 28 comment). This is a ready-made insertion point.
- **Scene wiring** (`scenes/main.tscn`): single `Players` Node3D container; `MultiplayerSpawner` (spawn_path → `Players`) replicates BaseEntity/Soul/Totem/Pet/Enemy; separate `ProjectileSpawner` → `Projectiles`. No Boss/Mobs/Minions/Souls/Totems split — everything except projectiles lands in `Players`.
- **Entity authority pattern**: `BaseEntity._ready()` (common/BaseEntity.gd:42-89) sets player authority from numeric node name, forces `ServerState` to authority 1, then `RollbackSynchronizer.process_settings()`. Groups assigned by name prefix (`players`/`mobs`/`pets`, lines 47-52) — AI faction detection depends on this.
- **Server-dictated state pattern**: `common/components/ServerState.gd` (server-owned, `_ready` registers props on sibling `StateSynchronizer`, lines 63-85). This is the established project pattern for "server owns data, clients read": **the pattern `MatchState` should mirror at match scope**.
- **Rollback contract** (post archived change `rollback-integrity-baseline`): no manual `_rollback_tick` forwarding; live input sampled in `NetworkTime.before_tick_loop` (`core/LogicComponent.gd:58,63-72`); rollback ticks read recorded properties only. Movement wrapped in `NetworkTime.physics_factor` (LogicComponent.gd:238-248).
- **Lobby/connection flow**: `client/connection_manager.gd` — UI states LOGIN→LOBBY→CONNECTING→IN_GAME; Noray NAT/relay; name submit RPC → `match_manager.peer_data`. **No team select, no ready, no countdown.** `EventBus` already declares unused `match_started`/`match_ended(winner_id)` signals (event_bus.gd:21-23).
- **Souls today are personal**: `SoulEntity._collect` increments `player.server_state.sync_souls` directly (SoulEntity.gd:54-56). Roadmap changes this to team bank — **Stage 5/6, not Stage 2**.
- **netfox.extras available**: `RewindableStateMachine`, `RewindableState`, `RewindableRandomNumberGenerator` all present in `addons/netfox.extras/`.
- **Tests**: GUT 9.7.1 vendored; suites `tests/unit/test_game_manager.gd` and `tests/integration/test_netfox_sync.gd` green via headless `gut_cmdln.gd`. `strict_tdd: false`.

### Natural insertion points

| Concern | Insertion point |
|---|---|
| Phase machine / match orchestration | New sibling nodes under `Main` (main.tscn): `MatchDirector` (server logic) + `MatchState` (server-owned sync node) — mirrors `ServerState`/`StateSynchronizer` pattern |
| Team identity per entity | `ServerState.team_id` (new `@export` + `add_state`) — server-dictated, replicated, survives respawn |
| Match seed | `match_manager.match_seed` field already reserved; `MatchDirector` assigns it at `ROUND_SETUP` |
| Spawn containers | New Node3D containers in main.tscn + one `MultiplayerSpawner` per container (existing `ProjectileSpawner` is the template) |
| Match lifecycle events | `EventBus.match_started`/`match_ended` already declared; add `phase_changed(phase)` |
| Rules config | `common/resources/` already holds `attack_definition.gd` (Resource) — `MatchRules` follows that exact pattern |

## Affected Areas

- `common/match_manager.gd` — extract match/phase awareness; route spawns to typed containers; keep spawn API
- `common/components/ServerState.gd` — add `team_id` (+`add_state`)
- `scenes/main.tscn` — new containers, spawners, `MatchDirector`/`MatchState` nodes
- `common/event_bus.gd` — add `phase_changed`, `team_assigned` signals
- `common/resources/` — new `match_rules.gd` + `default_match_rules.tres`
- New: `common/team_id.gd`, `common/match_state.gd`, `common/match_director.gd`
- `tests/unit/` + `tests/integration/` — new GUT suites

## Key Design Answers

### Rollback-safe architecture

**MatchDirector NEVER enters a rollback tick.** It is not an entity and owns no `_rollback_tick`. Phase transitions are low-frequency, server-authoritative, and must not be rewound. Consequences:

- Phase timing uses **tick-counted server-side timers**: `NetworkTime.on_tick` (or `NetworkTime.ticks_passed` deltas) with durations converted from `MatchRules` seconds → ticks at tickrate 60. Never `SceneTreeTimer`, never wall-clock, never `randi/randf` inside the director. Match-seeded randomness (when needed in later stages) uses `RewindableRandomNumberGenerator` or `match_seed + sequence`.
- **MatchState replication via `StateSynchronizer` on a server-owned node** (authority 1), exactly like `ServerState`: `@export` props registered with `add_state()` (`phase`, `phase_entered_tick`, `match_seed`, `team_red_score`/`team_blue_score` stubs, `winner`). Late joiners get full-state broadcast for free — RPCs would need a manual catch-up path and are lossy by comparison. Client-side presentation hooks (UI) subscribe to a local `phase_changed` signal emitted from the property setter.
- `MatchState` is a **dumb replicated snapshot**; `MatchDirector` is the **sole writer** (server-only). This preserves the project's authority split and config rule ("Server-dictated state goes in ServerState.gd and StateSynchronizer property list" — generalized to match scope).

### TeamId model

`common/team_id.gd` — `class_name TeamId` with `enum Value { NONE, RED, BLUE }` plus pure helpers (`opposite()`, `display_name()`, `color()`). Enum-as-int wins over Resource or raw int: serializes natively through `StateSynchronizer`, type-hints as `TeamId.Value`, zero runtime allocation. Roadmap explicitly targets this path (`common/team_id.gd`, migrating OLD `scripts/constants.gd` concept).

**Assignment point (Stage 2)**: server-side in `MatchDirector` during `LOBBY`, deterministic by sorted peer-id order (alternate RED/BLUE). UI team-select is Stage 3 — Stage 2 only needs the assignment *mechanism* and persistence. Storage: `MatchState` roster dictionary (peer_id → team, server-only authoritative) **and** `ServerState.team_id` on each spawned player entity (replicated, so entities/HUD/AI can query team locally). Mobs/totems/souls get a `team_id` export on their server-side state too (mobs = `NONE`), wired but unused by gameplay until later stages.

### MatchRules schema (Resource, `common/resources/match_rules.gd`)

```gdscript
class_name MatchRules extends Resource
# Boss
@export var boss_max_hp: int = 10000
@export var boss_damage_threshold: int = 6000
# Teams
@export var max_players_per_team: int = 3
# Souls / reward choice
@export var souls_per_mob_drop: int = 2
@export var reward_choice_window_sec: float = 1.5
# Minions
@export var minion_cap_per_team: int = 3
@export var minion_cap_per_type: int = 1
# Totems
@export var totem_soul_cost: int = 4
@export var totem_cap_per_team: int = 2
@export var totem_cap_per_player: int = 1
@export var totem_cooldown_sec: float = 8.0
@export var totem_lifetime_sec: float = 30.0
@export var totem_min_separation_m: float = 6.0
# Phase timings (Stage 2 subset used; rest reserved)
@export var countdown_sec: float = 3.0
@export var boss_deploy_countdown_sec: float = 3.0
@export var result_display_sec: float = 10.0
@export var forfeit_disconnect_sec: float = 30.0
```

Ship `default_match_rules.tres`. Stage 2 consumes only the phase timings + team caps; the rest is schema-complete per the locked roadmap so later stages don't reshape the resource.

### Entity containers

New Node3D containers in `main.tscn`: `Players`, `Mobs`, `Minions`, `Souls`, `Totems`, `Boss` (+ existing `Projectiles`), each with its own `MultiplayerSpawner` (the existing two-spawner pattern proves this works). `MatchManager` spawn functions route to the typed container. **Team-scoped registries** (needed Stage 5+ for caps: minions ≤3/team, totems ≤2/team): server-only `Dictionary` in `MatchDirector`/`MatchState`, `TeamId.Value → Array[StringName]` of stable spawn IDs, maintained in spawn-sequence order (deterministic — insertion order from `_next_spawn_id`, never dictionary iteration). Stage 2 creates the registry structure + register/unregister API; cap enforcement arrives with the stages that need it.

## Approaches

1. **A — Scene-instanced `MatchDirector` + server-owned `MatchState` node with `StateSynchronizer`** (recommended)
   - Pros: mirrors the established `ServerState`/`StateSynchronizer` pattern (config.yaml rules endorse it); late-join full-state sync free; server-only logic testable headless without network; no rollback involvement; clients react via property setters/signals
   - Cons: new scene wiring in main.tscn; one more node pair to reason about
   - Effort: Medium

2. **B — `MatchDirector` autoload + RPC phase broadcast**
   - Pros: no scene edits; globally addressable
   - Cons: diverges from project authority pattern; late joiners need manual full-state catch-up RPC; autoload persists across matches (state leakage risk on rematch); RPC loss/ordering handling by hand
   - Effort: Medium (higher tail risk)

3. **C — `RewindableStateMachine` (netfox.extras) under a `RollbackSynchronizer`**
   - Pros: off-the-shelf FSM; rollback-consistent state
   - Cons: wrong tool — match phases must NOT rewind with player rollback; netfox docs caveat that state changes are not guaranteed emitted on all peers (would need StateSynchronizer anyway); adds prediction/resimulation complexity to server-only flow
   - Effort: Medium-High

## Recommendation

**Approach A.** It extends the pattern the codebase already proves per-entity to match scope, keeps determinism (tick-counted transitions, seeded spawn IDs), and keeps Stage 2 demonstrable headless: a simulated match walks LOBBY→COUNTDOWN→ROUND_SETUP→PVE_RACE→BOSS_LOCK→BOSS_DEPLOY→BOSS_A1→RESULT→POST_MATCH→LOBBY with stub hooks (no gameplay), asserting transition order, tick timing, and replication props.

## Stage 2 Scope Boundary (proposed)

**IN:**
- `TeamId`, `MatchRules` + `.tres`, `MatchState` (+`StateSynchronizer`), `MatchDirector` with tick-counted phase machine, `phase_changed`/`team_assigned` EventBus signals
- `ServerState.team_id` on entities; deterministic team assignment in LOBBY (sorted peer order)
- Typed containers + spawners in main.tscn; `MatchManager` spawn routing refactor; team registry structure
- `match_seed` real assignment at ROUND_SETUP (seed flows into existing `_next_spawn_id` format)
- GUT: unit (TeamId helpers, MatchRules defaults, spawn-ID determinism) + integration (simulated full phase walk headless; team assignment; state replication props registered)

**OUT (explicit):** soul pickup/team bank logic, totem planting validation/costs, minion spawning, reward choice window, boss entity/combat/meters, team-select UI, late-join policy, gate logic. Existing soul/totem/mob behavior stays functionally untouched (only spawn routing moves).

**Size forecast:** ~850–950 changed lines total (new files ~520, modifications ~180, tests ~200) → **exceeds the 400-line review budget; chained PRs recommended**: PR1 TeamId+MatchRules+ServerState.team_id (~220), PR2 MatchState+MatchDirector+scene wiring+signals (~380), PR3 containers+MatchManager refactor+tests (~350).

## Risks

- **Branch stack**: tip is `feature/tickrate-speed-calibration` with 3 open unmerged PRs (#3 ← #4 ← #6). Stage 2 must chain on top or wait for merge — rebase cost if the stack shifts.
- `MatchManager` god-object refactor touches spawn paths used by Soul/Totem/Pet flows; routing mistakes break existing green suites — keep behavior identical, move only containers.
- Group assignment in `BaseEntity._ready()` keys off node-name prefixes; new containers must not change naming, or AI faction detection silently breaks.
- `MultiplayerSpawner` per-container means new spawner configs — spawn-property replication configs (added in Stage 1) must be re-verified per new spawner.
- StateSynchronizer on `MatchState` on clients must not emit phase signals during full-state catch-up replays (guard setters by actual value change).

## Ready for Proposal

Yes. Scope is bounded, the architecture follows an in-repo proven pattern, and the deliverable is headless-demonstrable. Orchestrator should flag the chained-PR recommendation and the open-PR stack dependency to the user.
