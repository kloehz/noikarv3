# Tasks: Rollback Integrity Baseline

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~250-350 hand-written; +vendored `addons/gut/` (thousands, generated) |
| 400-line budget risk | High (driven by vendored GUT addon; hand-written diff alone is Low) |
| Chained PRs recommended | Yes |
| Suggested split | PR 1: Etapa 0 (config + vendored GUT + test fix + baseline docs, vendor-dominated) → PR 2: Etapa 1 (rollback fix + determinism + replication, ~250 lines) |
| Delivery strategy | ask-on-risk (received `auto-forecast`; chain strategy unresolved) |
| Chain strategy | pending — PR 1 is a `size:exception` candidate (vendored addon); PR 2 stacks on PR 1 |

Decision needed before apply: Yes
Chained PRs recommended: Yes
Chain strategy: pending
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Etapa 0: baseline branch, feature tag, GUT install, test fix, smoke pass | PR 1 | Base = new initiative branch off `feature/pets`; vendor-heavy, size:exception candidate |
| 2 | Etapa 1: double-tick fix, input sampling, spawn IDs, replication configs | PR 2 | Base = PR 1 branch; isolated forwarding-removal commit for revert |

## Phase 1: Baseline Branch & Inventory

- [x] 1.1 Create initiative branch from `feature/pets`; inventory uncommitted changes (`scenes/main.tscn`, `scenes/connection_menu.tscn`, `.import`, `.atl/`) and commit/stash before edits.
- [x] 1.2 Record pre-change state: run `python3 tests/verify_export_isolation.py` and `python3 tests/verify_headless_server.py --quick`; capture results.

## Phase 2: Config & Test Harness (Etapa 0)

- [x] 2.1 Add `"dedicated_server"` to `config/features` in `project.godot`.
- [x] 2.2 Harden `GameManager._is_headless_environment()` in `common/game_manager.gd`: editor runs check `DisplayServer.get_name() == "headless"` only.
- [x] 2.3 Install pinned GUT 9.x (GitHub `bitwes/Gut` release, Godot 4.7 support) into `addons/gut/`; do NOT enable editor plugin; record version.
- [x] 2.4 Append `res://addons/gut/,res://addons/gut/*,res://tests/,res://tests/*` to client preset `exclude_filter` in `export_presets.cfg`.
- [x] 2.5 Fix `tests/integration/test_netfox_sync.gd`: tabs not spaces (lines 76-78, 82-87); retarget assertions to `RollbackSynchronizer`/`StateSynchronizer`.
- [x] 2.6 Set `testing.runner_installed: true` in `openspec/config.yaml`; verify both smoke scripts + GUT unit/integration suites run.

## Phase 3: Rollback Integrity Fix (Etapa 1)

- [ ] 3.1 Delete `_rollback_tick` (lines 248-250) from `common/BaseEntity.gd` — isolated commit.
- [ ] 3.2 Delete `super._rollback_tick(...)` at `common/EnemyEntity.gd:133`; keep grace guard.
- [ ] 3.3 Delete `super._rollback_tick(...)` at `common/PetEntity.gd:173`; keep skill block; add comment that `randf()` skills are server-gated and replicate via ServerState (Stage 2: seed `RewindableRandomNumberGenerator`).
- [ ] 3.4 Move live `Input` sampling out of `core/LogicComponent.gd` `_rollback_tick` into `_gather_input()` connected to `NetworkTime.before_tick_loop` (authority-only, humans only); extract dash trigger; rollback tick reads properties only.

## Phase 4: Spawn IDs & Replication Metadata (Etapa 1)

- [ ] 4.1 Add `match_seed` (0), `_spawn_counters`, `_next_spawn_id(prefix)` to `common/match_manager.gd` per design contract; replace `randi()` names at all spawn sites (MOB_/ELITE_/PET_/SOUL_/TOTEM_ prefixes).
- [ ] 4.2 Add `process_settings()` calls after post-`_ready` authority changes: `match_manager.gd:_setup_pet_logic` (line 324), `EnemyEntity.setup_enemy` (line 120).
- [ ] 4.3 Extend `SceneReplicationConfig` spawn props (spawn=true, mode=1): Enemy +`enemy_type`,`difficulty`; Pet +`owner_id`,`pet_type`,`power_level`; Soul +`original_mob_scene_path`; Totem +`totem_type`,`stored_souls`.

## Phase 5: Verification & Baseline Record

- [ ] 5.1 Re-run both smoke scripts and GUT suites; verify one input → exactly one movement/attack per tick (headless server + 2 clients, before/after).
- [ ] 5.2 Grep rollback paths for `randi|randf|SceneTreeTimer|Time\.` — confirm only documented server-gated exceptions remain.
- [ ] 5.3 Write `openspec/changes/rollback-integrity-baseline/baseline.md`: branch, smoke results, GUT version, netfox client-exclusion open question, spawn ID strategy.
