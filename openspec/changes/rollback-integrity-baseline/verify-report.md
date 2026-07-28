# Verify Report: Rollback Integrity Baseline

Date: 2026-07-28
Mode: Standard (strict_tdd: false)
Branch under test: `feature/rollback-integrity-etapa1` (stacked on `feature/rollback-integrity-baseline`)
Artifacts: proposal.md + design.md + tasks.md + baseline.md (full set — all dimensions verified)

## Executive Summary

Implementation matches design and tasks on every statically checkable dimension, and all automated runtime evidence was independently re-executed and passes: `verify_export_isolation.py` PASS, `verify_headless_server.py --quick` PASS, GUT unit 7/7, GUT integration 9/9. The double-tick fix, feature tag + editor guard, spawn ID strategy, and replication configs are all verified in source. One core verification task (5.1 manual interactive check) remains unchecked — it is the only runtime evidence for the change's central success criterion ("one input → exactly one movement/attack per rollback tick"), so it is CRITICAL and blocks archive.

## Completeness (tasks.md vs repo state)

| Task | Checkbox | Verified state | Status |
|------|----------|----------------|--------|
| 1.1 Branch + inventory | [x] | Branches exist; preservation commit `c7226ff` | OK |
| 1.2 Pre-change baseline | [x] | Recorded in baseline.md (isolation PASS, headless FAIL) | OK |
| 2.1 `dedicated_server` feature tag | [x] | `project.godot:15` `PackedStringArray("4.7", "Mobile", "dedicated_server")` | OK |
| 2.2 Editor guard `_is_headless_environment()` | [x] | `common/game_manager.gd:18-21` — editor → headless display only | OK |
| 2.3 GUT 9.7.1 vendored, plugin not enabled | [x] | `addons/gut/` present; suites run via `gut_cmdln.gd` | OK |
| 2.4 export preset excludes gut/tests | [x] | `export_presets.cfg:10` exclude_filter includes both | OK |
| 2.5 test_netfox_sync.gd fixed | [x] | Suite executes: 9/9 passing | OK |
| 2.6 `runner_installed: true` + suites run | [x] | `openspec/config.yaml:20`; re-executed below | OK |
| 3.1 BaseEntity forwarding deleted (isolated) | [x] | Commit `dd0de46` touches only BaseEntity/EnemyEntity/PetEntity; no `_rollback_tick` remains in BaseEntity.gd | OK |
| 3.2 EnemyEntity super call dropped | [x] | `EnemyEntity.gd:129-140` — grace guard kept, explicit no-super comment | OK |
| 3.3 PetEntity super call dropped + randf comment | [x] | `PetEntity.gd:163-189` — skill block server-gated, Stage 2 TODO documented | OK |
| 3.4 Input sampling moved to `_gather_input()` | [x] | `LogicComponent.gd:58,63-72,153,171` — `before_tick_loop` connected, `_start_dash()` extracted, rollback tick reads properties only | OK |
| 4.1 Spawn ID strategy | [x] | `match_manager.gd:29-36` + all spawn sites (`MOB_` :72, `SOUL_` :230, `ELITE_` :244, `TOTEM_` :289, `PET_` :314); no `randi()` names remain | OK |
| 4.2 `process_settings()` after authority changes | [x] | `match_manager.gd:342-343` (`_setup_pet_logic`), `EnemyEntity.gd:125` (`setup_enemy`) | OK |
| 4.3 SceneReplicationConfig spawn props | [x] | Enemy +`enemy_type`/`difficulty` (spawn=true, mode=1); Soul +`original_mob_scene_path`; Totem +`totem_type`/`stored_souls`; Pet props already present (verified deviation) | OK |
| 5.1 Re-run smoke + GUT + manual 2-client check | [ ] | Automated layers re-executed and PASS; **interactive check NOT done** | CRITICAL |
| 5.2 Determinism grep clean | [x] | Re-grepped: only documented server-gated exceptions (`PetEntity` randf, `match_manager` randf/randf_range, `_shutdown_timer`) | OK |
| 5.3 baseline.md written | [x] | Present, accurate vs. verified state | OK |

Completed: 16/17.

## Build / Tests / Coverage Evidence

| Command | Result (executed by verifier, 2026-07-28) |
|---------|------------------------------------------|
| `python3 tests/verify_export_isolation.py` | PASS — 0 violations, presets OK, 2/2 .gdignore |
| `python3 tests/verify_headless_server.py --quick` | PASS — all quick checks |
| `Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit` | 7/7 passed (1 warning: 8 unfreed children) |
| `Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/integration -gexit` | 9/9 passed, 25 asserts (10 orphans; ObjectDB leak warnings at exit) |

No coverage threshold configured. strict_tdd false — no RED-GREEN-REFACTOR evidence required.

## Spec / Success-Criteria Compliance (proposal.md)

| Criterion | Evidence | Status |
|-----------|----------|--------|
| Both smoke scripts pass | Re-executed, PASS | COMPLIANT |
| GDScript suites execute | GUT unit 7/7 + integration 9/9 re-executed | COMPLIANT |
| One input → exactly one movement/attack per tick | Static fix verified (no forwarding anywhere; netfox auto-discovery confirmed by design analysis); **no runtime evidence** — manual check pending | UNTESTED (CRITICAL) |
| No nondeterminism in rollback paths | Re-grepped; only documented server-gated exceptions | COMPLIANT |
| Spawn ID strategy documented + replication metadata | baseline.md + match_manager.gd + .tscn configs verified | COMPLIANT |
| Baseline record committed | `4214a8e` on `feature/rollback-integrity-etapa1` | COMPLIANT |

## Design Coherence

| Decision | Verified |
|----------|----------|
| Remove manual forwarding (option a) | Yes — exact edits from design present; `dd0de46` is isolated (3 files, revert boundary intact) |
| Ownership ordering + `process_settings()` rule | Yes — both call sites present |
| Determinism dispositions | Yes — all match baseline.md table |
| Spawn ID format `{PREFIX}_{match_seed_hex}_{seq:04d}` | Yes — `trim_suffix("_")` normalization produces `MOB_00_0007` per design example (documented deviation) |
| Replication configs additive | Yes — spawn=true, mode=1 on all added props; Pet needed no change (already had props) |
| Feature tag + editor guard | Yes — `OS.has_feature("editor")` → headless display check |
| GUT install approach | Yes — vendored, plugin not enabled, preset excludes |

## Issues

### CRITICAL
1. **Task 5.1 manual interactive check incomplete.** The headless-server + 2-clients check ("one input → exactly one movement/attack per tick") is the only runtime evidence for the change's central success criterion. Automated tests pass but do not assert single-tick movement behavior. Per verify gates, an unchecked core verification task blocks archive. Follow-up: run the interactive session before archive; no code change expected.

### WARNING
1. **Stacked branches are local-only; no PRs exist.** `gh pr list` returns none; `feature/rollback-integrity-baseline` and `feature/rollback-integrity-etapa1` are not pushed to any remote. The "PR 1 / PR 2" chain described in tasks/apply-progress is not yet realized for review.
2. **GUT runs report resource leaks.** Unit: 8 unfreed children; integration: 10 orphans, 12 ObjectDB instances leaked at exit, 1 resource still in use. Tests pass; likely netfox/autoload lifecycle noise, but worth tracking before suites grow.

### SUGGESTION
1. Client export preset excludes `res://addons/netfox/` (baseline.md open question) — latent risk for Stage 8; confirm intent soon.
2. `BaseEntity.tscn` has no `MultiplayerSynchronizer` — consider minimal `SceneReplicationConfig` (position) in Stage 2.

## Verdict

**FAIL** (archive readiness) — one CRITICAL: task 5.1's interactive runtime check is pending. All implementation work is verified correct; the gap is verification evidence only, not code. Expected path to PASS: execute the 2-client manual check, tick 5.1, re-verify.
