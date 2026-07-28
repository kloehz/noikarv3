# Proposal: Match Foundation (Roadmap Stage 2)

## Intent

Noikar currently has no match concept: players spawn on connect and mobs roam freely (`match_manager.gd:115-129`). Every later roadmap stage — soul team bank, totems, minions, boss A1 race — hangs off three primitives that don't exist yet: **TeamId**, **MatchState**, and a **MatchDirector** phase machine. This change builds exactly that foundation, nothing more, so Stages 3-6 land on stable, replicated, rollback-safe ground instead of reworking spawn/authority plumbing mid-feature.

## Scope

### In Scope
- `TeamId` (`class_name`, enum NONE/RED/BLUE) + pure helpers
- `MatchRules` Resource + `default_match_rules.tres` (schema-complete per locked roadmap values; Stage 2 consumes only phase timings + team caps)
- `MatchState` server-owned node with `StateSynchronizer` (phase, phase_entered_tick, match_seed, score stubs, winner) — mirrors `ServerState.gd:63-85` pattern
- `MatchDirector` scene node: tick-counted phase walk LOBBY→COUNTDOWN→ROUND_SETUP→PVE_RACE→BOSS_LOCK→BOSS_DEPLOY→BOSS_A1→RESULT→POST_MATCH with stub hooks; never enters rollback ticks
- Deterministic team assignment in LOBBY (sorted peer order, alternate RED/BLUE); `ServerState.team_id` replicated per entity
- Typed containers + per-container `MultiplayerSpawner` in `main.tscn` (Players/Mobs/Minions/Souls/Totems/Boss + existing Projectiles); `MatchManager` spawn routing refactor — behavior-preserving, name-prefix conventions kept
- Real `match_seed` assigned at ROUND_SETUP (flows into existing `_next_spawn_id`)
- Team registry structure + register/unregister API (no cap enforcement)
- Wire `EventBus.match_started`/`match_ended`; add `phase_changed`/`team_assigned`
- GUT unit + integration suites

### Out of Scope
Soul bank, totem planting/rules, minions, kill-reward choice, boss entity/combat, team-select UI, late-join policy, gate logic. Existing soul/totem/mob behavior functionally untouched.

## Capabilities

### New Capabilities
- `match-lifecycle`: phase machine, MatchState replication, tick-counted timing, match seed
- `team-identity`: TeamId, deterministic assignment, per-entity replicated team_id, team registries

### Modified Capabilities
- None (spawn routing is behavior-preserving; `network-timing-calibration` spec untouched)

## Approach

**Architecture A** (exploration ruling): scene-instanced `MatchDirector` + server-owned `MatchState` with `StateSynchronizer`. Late-join full-state sync free; director server-only, tick timing via `NetworkTime` at 60Hz — no `SceneTreeTimer`, `randi`, or wall-clock. Rejected: autoload+RPC (manual catch-up), RewindableStateMachine (phases must not rewind).

**Chained PR slices** (forecast ~850-950 lines > 400-line budget; delivery: auto-chain, stacked-to-main, branched off `feature/tickrate-speed-calibration`):
1. **PR1 — team-rules-data** (~220 lines): TeamId, MatchRules+.tres, `ServerState.team_id`
2. **PR2 — match-director** (~380 lines): MatchState, MatchDirector phase machine, scene nodes, EventBus signals, phase-walk tests
3. **PR3 — spawn-routing** (~350 lines): containers+spawners, MatchManager routing refactor, match_seed wiring, team registry, remaining tests

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `common/team_id.gd`, `common/resources/match_rules.gd` + `.tres` | New | Identity + rules data |
| `common/match_state.gd`, `common/match_director.gd` | New | Replicated state + phase machine |
| `common/components/ServerState.gd` | Modified | Add `team_id` (+`add_state`) |
| `scenes/main.tscn` | Modified | Containers, spawners, new nodes |
| `common/match_manager.gd` | Modified | Spawn routing only |
| `common/event_bus.gd` | Modified | New signals; wire match events |
| `tests/unit/`, `tests/integration/` | New suites | GUT |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| 4-deep unmerged stack (#3←#4←#6 + this) shifts | Med | Rebase slices in order; keep PR1-3 diffs orthogonal |
| Container refactor breaks name-prefix group detection (`BaseEntity.gd:47-52`) | Med | Keep prefixes identical; integration test asserts groups |
| Spawner spawn-property config regressions (Stage 1 configs) | Med | Re-verify replication config per new spawner |
| Phase signal storms on late-join full-state catch-up | Low | Guard setters by actual value change |

## Rollback Plan

Revert slice PRs in reverse order (PR3→PR1). Each slice is autonomous: PR1 is additive data, PR2 adds unused nodes, PR3 is the only behavioral refactor and restores single-container routing on revert.

## Dependencies

- Branch tip `feature/tickrate-speed-calibration` (open PRs #3←#4←#6) as base
- GUT vendored, `gut_cmdln` headless runner

## Success Criteria

- [ ] Headless simulated 2-team match walks LOBBY→POST_MATCH deterministically: same seed → same transition order and tick timings
- [ ] GUT unit + integration suites green (existing suites stay green)
- [ ] Existing behavior preserved: players spawn/play as today; soul/totem/mob flows unchanged
- [ ] Late-joiner receives full MatchState via StateSynchronizer without manual catch-up
