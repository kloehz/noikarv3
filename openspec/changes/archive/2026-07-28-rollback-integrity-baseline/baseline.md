# Baseline Record: Rollback Integrity Baseline

Date: 2026-07-28
Initiative branch: `feature/rollback-integrity-baseline` (forked from `feature/pets`)
Etapa 1 branch: `feature/rollback-integrity-etapa1` (stacked on Etapa 0)

## Pre-change state (captured on `feature/pets`)

| Check | Result |
|-------|--------|
| `python3 tests/verify_export_isolation.py` | PASS |
| `python3 tests/verify_headless_server.py --quick` | FAIL — `dedicated_server` feature tag missing |
| GUT suites | Could not run — `addons/gut/` missing |
| `tests/integration/test_netfox_sync.gd` | Broken — mixed tabs/spaces (parse error); asserted `MultiplayerSynchronizer` not present in `BaseEntity.tscn` |

Preserved local changes from `feature/pets` (committed, not overwritten):
`scenes/main.tscn`, `scenes/connection_menu.tscn`, model `.import` files, `.atl/`.

## Post-change state

| Check | Result |
|-------|--------|
| `python3 tests/verify_export_isolation.py` | PASS |
| `python3 tests/verify_headless_server.py --quick` | PASS |
| GUT unit (`-gdir=res://tests/unit`) | 7/7 passing |
| GUT integration (`-gdir=res://tests/integration`) | 9/9 passing |

## Test harness

- GUT **9.7.1** (GitHub `bitwes/Gut` release zip, declares Godot 4.7 compatibility) vendored in `addons/gut/`.
- Editor plugin NOT enabled (`gut_cmdln.gd` does not need it; `project.godot` plugin list untouched).
- Client export preset excludes `res://addons/gut/` and `res://tests/`; `verify_export_isolation.py` still passes.
- Commands:
  - Unit: `godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit`
  - Integration: `godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/integration -gexit`
- Note: `GameManager` autoload boots the server path during headless GUT runs (headless = server). Harmless for the current suites; revisit if tests need a client environment.

## Feature tag

`config/features` now includes `dedicated_server`. `GameManager._is_headless_environment()` guards editor runs (`OS.has_feature("editor")` → headless display only) so editor runs never self-detect as server.

## Double-tick fix

Removed manual `LogicComponent._rollback_tick()` forwarding from `BaseEntity.gd`, `EnemyEntity.gd`, `PetEntity.gd`. Netfox's `RollbackSynchronizer.process_settings()` auto-discovers every rollback-aware node under its root (`root.find_children("*")`, root-first) — the forwarding made `LogicComponent` execute twice per tick. Revert commit `dd0de46` to restore old behavior.

## Determinism audit dispositions

| Path | Verdict |
|------|---------|
| `BaseEntity._rollback_tick` forwarding | Removed (double-tick bug) |
| `LogicComponent` live `Input.*` sampling in rollback tick | Moved to `_gather_input()` on `NetworkTime.before_tick_loop` (authority-only, humans only); rollback tick reads recorded properties only |
| `CombatComponent._rollback_tick` | OK (is_fresh gate, no RNG) |
| `PetEntity` skill `randf()` | Server-gated (`is_fresh && is_server`), outcomes replicate via ServerState — documented in code. Stage 2: seed `RewindableRandomNumberGenerator` with spawn_id |
| `EnemyEntity`/`PetEntity` grace via `SceneTreeTimer` | Server-only visual/collision outcome — documented. Stage 2: tick-counted grace |
| `match_manager.gd` `randi()` node names | Replaced with stable spawn IDs |
| `match_manager.gd` `randf`/`randf_range` (elite chance, respawn/spawn pos) | Server-only, outside rollback ticks, results replicate — kept. Rule: authoritative randomness lives on server only |
| `SoulEntity`/`TotemEntity` `_process` + timers | Non-rollback server lifecycle; outcomes replicate — documented |
| `HealthComponent.gd` invincibility `SceneTreeTimer` | Server-only gameplay timing — flagged for Stage 2 (tick-based), not blocking |

## Stable spawn ID strategy

- Format: `{PREFIX}_{match_seed_hex}_{seq:04d}` — e.g. `MOB_00_0007`, `PET_00_0002`.
- Prefixes: `MOB_`, `ELITE_`, `PET_`, `SOUL_`, `TOTEM_` (group detection in `BaseEntity._ready()` keeps working).
- Generated server-only by `MatchManager._next_spawn_id(prefix)` with per-prefix counters.
- `match_seed`: int on MatchManager, `0` until Stage 2 introduces real seeding; format is forward-compatible.
- Stored in `node.name`, replicated automatically by `MultiplayerSpawner`; deterministic unique names also remove the old `randi() % 1000` collision risk.
- Project rule: any authority change after `_ready()` MUST be followed by `RollbackSynchronizer.process_settings()` (applied at `match_manager.gd:_setup_pet_logic` and `EnemyEntity.setup_enemy`).

## Replication spawn properties (SceneReplicationConfig, spawn=true, mode=1)

| Scene | Spawn props |
|-------|-------------|
| Enemy | `global_position`, `spawn_grace_duration`, +`enemy_type`, +`difficulty` |
| Pet | `global_position`, `owner_id`, `pet_type`, `power_level` (already present on branch — design assumed only `global_position`; verified, no change needed) |
| Soul | `global_position`, +`original_mob_scene_path` |
| Totem | `global_position`, +`totem_type`, +`stored_souls` |
| Projectile | none (Stage 2: direction/owner via custom spawn) |

## Runtime verification (task 5.1) — DONE

Scripted A/B test (`tests/manual/runtime_movement_test.gd`): headless server + scripted ENet client, constant forward input facing away from mob spawn, per-tick displacement sampling (p75).

| Version | Measured speed |
|-------|----------------|
| `dd0de46~1` (pre-fix, manual forwarding alive) | **8.0 m/s** |
| `4214a8e` (post-fix) | **4.0 m/s** |

Exactly 2x — the double-tick existed and the fix removes it. Uniform percentiles (p50=p75=p90) confirm clean per-tick movement with no duplication bursts.

## New finding: tickrate negotiation + speed calibration (follow-up change)

During the runtime test, the netfox tickrate handshake reported `Received tickrate 30 from peer 1` despite `tickrate=60` in `project.godot`, and steady-state player speed measures **4.0 m/s** instead of the designed `max_speed = 10.0` (`LogicComponent.gd:7`). `NetworkTime.physics_factor` is not used anywhere in `core/` or `common/`; the documented netfox pattern wraps `move_and_slide()` with it (`velocity *= NetworkTime.physics_factor` / `/=`), and `_apply_movement` does not. Speed ratio 0.4 ≈ tickrate mismatch/physics-factor territory. This predates the double-tick fix (pre-fix measured 8.0 = 2x of the same wrong baseline) and is out of scope for this change — needs its own change: why tickrate negotiates to 30, and whether `_apply_movement` must use `physics_factor`.

## Open questions (carried from design)

- Client export preset excludes `res://addons/netfox/` (`export_presets.cfg:10`) — that strips rollback/prediction code from clients. Likely a latent bug; out of scope here. Confirm intent before Stage 8 headless export work.
- `BaseEntity.tscn` has no `MultiplayerSynchronizer` — player spawn data relies on `StateSynchronizer` deltas only. Acceptable now; consider a minimal `SceneReplicationConfig` (position) in Stage 2.
