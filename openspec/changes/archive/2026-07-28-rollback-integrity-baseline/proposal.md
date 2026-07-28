# Proposal: Rollback Integrity Baseline

## Intent

First change of the PvPvE Action roadmap. Before any gameplay feature, the project needs a verified baseline (Stage 0) and a fix for a confirmed rollback integrity bug (Stage 1): `BaseEntity._rollback_tick()` manually forwards to `LogicComponent._rollback_tick()`, but Netfox's `RollbackSynchronizer` already auto-discovers and ticks every node with `_rollback_tick` under its root — so `LogicComponent` executes **twice per tick**. Additionally, `verify_headless_server.py --quick` fails because `project.godot` lacks the `dedicated_server` feature tag, and the GUT test suite cannot run (`addons/gut/` missing).

## Scope

### In Scope
- Add `dedicated_server` to `config/features` in `project.godot`; get `verify_headless_server.py --quick` passing.
- Inventory and preserve uncommitted local changes (`scenes/main.tscn`, `scenes/connection_menu.tscn`, `.import` files, `.atl/`) on a dedicated initiative branch; record baseline state (what runs, what errors).
- Decide and execute the test-harness strategy: install GUT (preferred — suites already extend `GutTest`) or formally document the Python-smoke alternative in `openspec/config.yaml`.
- Fix the `LogicComponent` double-tick: remove the manual forwarding in `BaseEntity.gd` (and any subclass override in `EnemyEntity.gd`/`PetEntity.gd`); ensure ownership is set before `RollbackSynchronizer.process_settings()`.
- Determinism audit of rollback paths: no `randi`/`randf`, `SceneTreeTimer`, wall-clock time, or random node names inside `_rollback_tick` code paths; replace with tick-seeded RNG.
- Define a stable spawn ID strategy (server-assigned, deterministic per match) and document it.
- Audit and extend `MultiplayerSpawner` replication configs (`SceneReplicationConfig_*`) to include team/ownership/reward metadata needed by later stages.

### Out of Scope
- Match phases, teams, boss, souls/minions/totems gameplay (roadmap Stages 2–9).
- Migrating any `noikar-old` netcode (read-only reference per roadmap).
- GUT test coverage expansion beyond making existing suites runnable.

## Capabilities

### New Capabilities
- `rollback-determinism`: single-tick execution guarantees, rollback-aware node ownership, deterministic RNG/timer rules, stable spawn IDs.
- `project-baseline`: export isolation, headless dedicated-server verification, project feature tags, baseline health record.
- `test-harness`: runnable GDScript test suite (GUT or documented alternative) plus Python smoke scripts.
- `entity-replication`: `MultiplayerSpawner`/`SceneReplicationConfig` coverage of spawn metadata (position, team, ownership, reward origin).

### Modified Capabilities
- None (no existing `openspec/specs/` entries).

## Approach

Two sequential slices (Etapa 0 → Etapa 1). Etapa 0 is config + documentation only: create branch, inventory uncommitted changes, fix feature tag, install GUT, run both smoke scripts and record the baseline. Etapa 1 removes the manual rollback forwarding (netfox's `_nodes` discovery from `root.find_children("*")` makes it redundant and harmful), then audits all `_rollback_tick` implementations for nondeterminism and updates replication configs.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `project.godot` | Modified | Add `dedicated_server` feature tag |
| `addons/gut/` | New | GUT installation (pending decision) |
| `common/BaseEntity.gd` | Modified | Remove manual `_rollback_tick` forwarding |
| `common/EnemyEntity.gd`, `common/PetEntity.gd` | Modified | Remove any duplicate forwarding overrides |
| `scenes/BaseEntity.tscn` + `*Entity.tscn` | Modified | Ownership-before-`process_settings()`, replication configs |
| `core/LogicComponent.gd`, `core/CombatComponent.gd` | Modified | Determinism fixes if audit finds any |
| `openspec/`, `tests/` | Modified | Baseline record, harness decision |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Removing forwarding breaks an entity that relied on tick order | Med | Test each entity type headless + 2 clients before/after |
| GUT install conflicts with export isolation rules | Med | Re-run `verify_export_isolation.py` after install |
| Uncommitted local changes lost during branching | Low | Inventory + commit/stash before any edit |

## Rollback Plan

Etapa 0 changes are additive config/docs — revert via git. Etapa 1: keep the manual-forwarding removal in an isolated commit; restoring it reverts the behavior change. No data or persisted state affected.

## Dependencies

- GUT addon (download if decision is install).
- Roadmap guard: `noikar-old/noikar` stays read-only.

## Success Criteria

- [ ] `verify_export_isolation.py` and `verify_headless_server.py --quick` both pass.
- [ ] GDScript test suites execute (or documented alternative is formalized).
- [ ] One input produces exactly one movement/attack per rollback tick (no double-tick).
- [ ] No `randi`/`randf`/`SceneTreeTimer`/wall-clock in rollback paths.
- [ ] Stable spawn ID strategy documented; replication configs carry required metadata.
- [ ] Baseline state record committed to the initiative branch.

## Proposal question round

Auto mode — questions deferred for user review:
1. GUT install vs. formalize Python-only harness — acceptable to install GUT from the official asset library?
2. Should the baseline branch fork from `feature/pets` (current) or `main`?
3. Is `SceneReplicationConfig` on entity scenes the intended long-term sync path, or should everything move into `ServerState`/`StateSynchronizer`?
