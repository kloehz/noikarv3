# Design: Rollback Integrity Baseline

## Technical Approach

Two slices per proposal. **Etapa 0** (config/docs): baseline branch from `feature/pets`, add `dedicated_server` feature tag with an editor-safe headless check, install GUT, fix the broken GUT suite file, record baseline. **Etapa 1** (behavior): delete the manual `_rollback_tick` forwarding (netfox already ticks every rollback-aware node), move live `Input` sampling out of the rollback tick into netfox's input-recording pattern, assign stable spawn IDs, and extend `SceneReplicationConfig` spawn properties additively.

## Architecture Decisions

### Decision: Double-tick fix — remove manual forwarding (option a)

**Choice**: Delete `BaseEntity._rollback_tick()`; in `EnemyEntity`/`PetEntity` drop the `super._rollback_tick(...)` call, keep their own guards/skills.
**Alternatives**: (b) keep forwarding + exclude LogicComponent from discovery — rejected: netfox discovery (`rollback-synchronizer.gd:113-116`) has no exclusion API; filtering would require monkey-patching.
**Rationale**: `RollbackSynchronizer.process_settings()` collects `root.find_children("*")` + root, filtered by `has_method("_rollback_tick")`. `BaseEntity` (root) and `LogicComponent` both match, so `LogicComponent` ticks via netfox AND via forwarding. `_nodes` order is root-first (`push_front`), so after the fix tick order stays: `EnemyEntity/PetEntity` (guards, zero inputs) → `LogicComponent` → `CombatComponent` (scene-tree order in BaseEntity.tscn: Logic line 81 before Combat line 85). Removing the method from `BaseEntity` also removes the root from `_nodes` — harmless: state recording is property-based, not awareness-based.

Exact edits:
- `common/BaseEntity.gd`: delete lines 248-250 (`_rollback_tick`).
- `common/EnemyEntity.gd`: delete line 133 (`super._rollback_tick(...)`); grace guard unchanged.
- `common/PetEntity.gd`: delete line 173 (`super._rollback_tick(...)`); skill block unchanged.

### Decision: Ownership ordering — verified, plus one rule

**Choice**: Keep current `BaseEntity._ready()` order; add a project rule.
**Rationale**: `_ready()` already does `set_multiplayer_authority(peer_id, true)` (recursive, line 63) → `server_state.set_multiplayer_authority(1, true)` (line 71) → `RollbackSynchronizer.process_settings()` (lines 82-85). Rule: **any authority change after `_ready()` MUST be followed by `process_settings()`** (netfox rebuilds property configs per authority). Apply to `match_manager.gd:_setup_pet_logic` (line 324) and `EnemyEntity.setup_enemy` (line 120).

### Decision: Determinism audit dispositions

| Path | Verdict | Action |
|------|---------|--------|
| `BaseEntity._rollback_tick` forwarding | Double-tick bug | Delete (above) |
| `LogicComponent` samples `Input.*` inside `_rollback_tick` | Non-deterministic: `RollbackSynchronizer` restores recorded `input_axis/is_shooting/look_yaw` before resim ticks, then live sampling overwrites them | Move sampling to `_gather_input()` on `NetworkTime.before_tick_loop` (authority-only, humans only); `_rollback_tick` only reads properties. Mouse-look via `_input` stays (netfox-sanctioned out-of-band gathering) |
| `CombatComponent._rollback_tick` | OK (`is_fresh` gate, reads recorded inputs, no RNG) | None |
| `PetEntity` skills `randf()` in rollback path, gated `is_fresh && is_server` | Acceptable: outcomes replicate via `ServerState`/HealthComponent/StateSynchronizer | Add comment; Stage 2: seed `RewindableRandomNumberGenerator` (netfox.extras, present) with spawn_id for pet prediction |
| `EnemyEntity/PetEntity` grace via `SceneTreeTimer` | Server-only visual/collision outcome; clients don't simulate server-owned entities | Document; Stage 2: tick-counted grace |
| `match_manager.gd` `randi` names | Breaks stable identity | Replace with stable spawn IDs (below) |
| `match_manager.gd` `randf`/`randf_range` (elite chance, respawn pos) | Server-only, outside rollback ticks, results replicate via spawner/respawn RPC | Keep — rule: authoritative randomness lives on server only |
| `SoulEntity`/`TotemEntity` `_process` + timers | Non-rollback server lifecycle; outcomes replicate (`sync_souls`, totem spawn config) | Document as non-rollback |
| `HealthComponent.gd:69` invincibility `SceneTreeTimer` | Server-only gameplay timing | Flag for Stage 2 (tick-based), not blocking |

### Decision: Stable spawn ID strategy

**Format**: `{PREFIX}_{match_seed_hex}_{seq:04d}` — e.g. `MOB_00_0007`, `PET_00_0002`. Prefixes preserved (`MOB_`, `ELITE_`, `PET_`, plus new `SOUL_`, `TOTEM_`) so `BaseEntity._ready()` group assignment (lines 47-52) keeps working.
**Generated**: server-only in `MatchManager._next_spawn_id(prefix)` with per-prefix counters. `match_seed`: int field on MatchManager, `0` for this change (real seeding is Stage 2); included in the format now so the scheme is forward-compatible.
**Stored**: `node.name` — replicated automatically by `MultiplayerSpawner` (names must match across peers; deterministic unique names also kill the `randi()%1000` collision risk).
**Replicated**: no custom `spawn_function` yet — current flow (spawner + `SceneReplicationConfig` spawn properties) stays. Stage 2 MAY introduce a spawn Dictionary `{spawn_id, type, position, team, owner}`.

### Decision: Spawner replication configs (additive only)

Spawners in `scenes/main.tscn`: `MultiplayerSpawner` → `Players` (BaseEntity uid `bvbjvutgbeanf`, Soul, Totem, Pet, Enemy uid `dg7xnmokokkvl`); `ProjectileSpawner` → `Projectiles` (Projectile). Replication happens via each scene's embedded `MultiplayerSynchronizer` + `SceneReplicationConfig` (BaseEntity/Projectile have none — noted gap).

| Scene | Current spawn props | Add (spawn=true, replication_mode=1) |
|-------|--------------------|--------------------------------------|
| Enemy | `global_position`, `spawn_grace_duration` | `enemy_type`, `difficulty` |
| Pet | `global_position` | `owner_id`, `pet_type`, `power_level` |
| Soul | `global_position` | `original_mob_scene_path` |
| Totem | `global_position` | `totem_type`, `stored_souls` |
| Projectile | none | none (Stage 2: direction/owner via custom spawn) |

### Decision: `dedicated_server` feature tag + editor guard

**Choice**: `config/features=PackedStringArray("4.7", "Mobile", "dedicated_server")` AND harden `GameManager._is_headless_environment()`.
**Rationale**: project features apply to editor runs too — without a guard, every editor run would self-detect as server (`OS.has_feature("dedicated_server")` true) and call `_start_as_server()`. New logic: `if OS.has_feature("editor"): return DisplayServer.get_name() == "headless"` else current behavior. Satisfies `verify_headless_server.py --quick` (greps project.godot for the string) without breaking the client workflow.

### Decision: GUT installation

**Choice**: GUT 9.x from GitHub `bitwes/Gut` release zip (pin the newest release declaring Godot 4.7 support; record exact version in baseline doc). Extract `addons/gut/`; do NOT enable the editor plugin (`gut_cmdln.gd` doesn't need it; keeps `project.godot` plugin list untouched). Append `res://addons/gut/,res://addons/gut/*,res://tests/,res://tests/*` to the client preset `exclude_filter` — `verify_export_isolation.py` only checks `core/`+`client/` presence, so it keeps passing.
**Also required**: `tests/integration/test_netfox_sync.gd` mixes tabs/spaces (lines 76-78, 82-87 — GDScript parse error) and asserts a `MultiplayerSynchronizer` that `BaseEntity.tscn` doesn't have. Fix indentation to tabs; retarget assertions to `RollbackSynchronizer`/`StateSynchronizer`.

## Data Flow

    Input (kbd/mouse) ──before_tick_loop──▶ LogicComponent.input_axis/is_shooting/look_yaw
                                                   │ recorded & broadcast by RollbackSynchronizer
    RollbackSynchronizer._run_rollback_tick ──▶ Pet/EnemyEntity (guards) ──▶ LogicComponent (movement)
                                             └─▶ CombatComponent (attacks, is_fresh gate)
    Server-only: MatchManager (spawn IDs, RNG) ──▶ MultiplayerSpawner ──▶ clients (name + spawn props)

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `project.godot` | Modify | Add `dedicated_server` feature |
| `common/game_manager.gd` | Modify | Editor guard in `_is_headless_environment()` |
| `common/BaseEntity.gd` | Modify | Delete `_rollback_tick` |
| `common/EnemyEntity.gd` / `common/PetEntity.gd` | Modify | Drop `super._rollback_tick`; RNG comment |
| `core/LogicComponent.gd` | Modify | `_gather_input()` via `before_tick_loop`; rollback tick reads only |
| `common/match_manager.gd` | Modify | `_next_spawn_id`; `process_settings()` after authority changes |
| `scenes/{Enemy,Pet,Soul,Totem}Entity.tscn` | Modify | Add spawn props to `SceneReplicationConfig` |
| `export_presets.cfg` | Modify | Exclude `addons/gut`, `tests` |
| `addons/gut/` | Create | GUT 9.x (pinned) |
| `tests/integration/test_netfox_sync.gd` | Modify | Tab indentation; netfox assertions |
| `openspec/config.yaml` | Modify | `testing.runner_installed: true` |
| `openspec/changes/rollback-integrity-baseline/baseline.md` | Create | Baseline record (branch, smoke results, GUT version) |

## Interfaces / Contracts

```gdscript
# LogicComponent.gd
func _ready() -> void:
    ...
    NetworkTime.before_tick_loop.connect(_gather_input)

func _gather_input() -> void:
    if Engine.is_editor_hint() or not entity: return
    if not entity.name.is_valid_int() or not _is_local_authority(): return
    input_axis = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
    is_shooting = Input.is_action_pressed("shoot")
    if Input.is_action_just_pressed("dash") and dash_cooldown <= 0 and not is_dashing:
        _start_dash()  # dash trigger logic extracted from _rollback_tick

# match_manager.gd
var match_seed: int = 0
var _spawn_counters: Dictionary = {}
func _next_spawn_id(prefix: String) -> String:
    _spawn_counters[prefix] = _spawn_counters.get(prefix, 0) + 1
    return "%s_%02X_%04d" % [prefix, match_seed, _spawn_counters[prefix]]
```

## Testing Strategy

| Layer | What | How |
|-------|------|-----|
| Smoke | Export isolation, headless config | `verify_export_isolation.py`, `verify_headless_server.py --quick` — both must pass after every slice |
| Unit (GUT) | game_manager suite | `godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit` |
| Integration (GUT) | netfox sync suite (fixed) | same with `-gdir=res://tests/integration` |
| Manual | One input → exactly one movement/attack per tick; grace still freezes pets/enemies | Headless server + 2 clients, before/after diff |

## Migration / Rollout

No migration. Etapa 0 is additive; Etapa 1 forwarding removal lands in one isolated commit (revert restores old behavior).

## Open Questions

- [ ] Client export preset excludes `res://addons/netfox/` (`export_presets.cfg:10`) — that strips rollback/prediction code from clients. Likely a latent bug; out of scope here, recorded in baseline. Confirm intent.
- [ ] `BaseEntity.tscn` has no `MultiplayerSynchronizer` — player spawn data relies on `StateSynchronizer` deltas only. Acceptable now, or add a minimal `SceneReplicationConfig` (position) in Stage 2?
