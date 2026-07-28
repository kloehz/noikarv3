# Verify Report: Rollback Integrity Baseline

Date: 2026-07-28 (re-verification, v2 — supersedes v1 FAIL)
Mode: Standard (strict_tdd: false)
Branch under test: `feature/rollback-integrity-etapa1` (stacked on `feature/rollback-integrity-baseline`), HEAD `83b1734`
Artifacts: proposal.md + design.md + tasks.md + baseline.md (full set — all dimensions verified)

## Executive Summary

Re-verification after v1 FAIL. The single CRITICAL (task 5.1, runtime evidence for "one input → exactly one movement per tick") is resolved: commit `83b1734` adds scripted A/B runtime evidence (`tests/manual/runtime_movement_test.gd`), checks 5.1, and records results in baseline.md. The verifier independently re-executed the post-fix runtime test against a live headless server and reproduced the documented numbers exactly: p50=p75=p90=4.000 m/s at negotiated tickrate 30, ratio 0.40, `PASS: single-tick movement`. All 17/17 tasks are checked; all automated layers re-executed and pass. A new pre-existing finding (tickrate negotiation 30 vs configured 60; speed 4.0 vs designed 10.0; `NetworkTime.physics_factor` unused) is correctly scoped as a follow-up change — it predates this change, does not affect the per-tick duplication criterion, and is documented in baseline.md. It does NOT block archive. Verdict: PASS.

## Completeness (tasks.md vs repo state)

| Task | Checkbox | Verified state | Status |
|------|----------|----------------|--------|
| 1.1 Branch + inventory | [x] | Branches exist; preservation commit `c7226ff` | OK |
| 1.2 Pre-change baseline | [x] | Recorded in baseline.md | OK |
| 2.1 `dedicated_server` feature tag | [x] | `project.godot:15` | OK |
| 2.2 Editor guard `_is_headless_environment()` | [x] | `common/game_manager.gd:18-21` | OK |
| 2.3 GUT 9.7.1 vendored, plugin not enabled | [x] | `addons/gut/` present; suites run | OK |
| 2.4 export preset excludes gut/tests | [x] | `export_presets.cfg:10` | OK |
| 2.5 test_netfox_sync.gd fixed | [x] | Suite executes: 9/9 passing | OK |
| 2.6 `runner_installed: true` + suites run | [x] | `openspec/config.yaml:20`; re-executed | OK |
| 3.1 BaseEntity forwarding deleted (isolated) | [x] | Commit `dd0de46` isolated | OK |
| 3.2 EnemyEntity super call dropped | [x] | `EnemyEntity.gd:129-140` | OK |
| 3.3 PetEntity super call dropped + randf comment | [x] | `PetEntity.gd:163-189` | OK |
| 3.4 Input sampling moved to `_gather_input()` | [x] | `LogicComponent.gd` — `before_tick_loop` connected | OK |
| 4.1 Spawn ID strategy | [x] | `match_manager.gd` + all spawn sites; no `randi()` names | OK |
| 4.2 `process_settings()` after authority changes | [x] | Both call sites present | OK |
| 4.3 SceneReplicationConfig spawn props | [x] | Enemy/Soul/Totem extended; Pet already present (verified deviation) | OK |
| 5.1 Smoke + GUT + runtime single-tick check | [x] | **RESOLVED (was CRITICAL in v1).** `tests/manual/runtime_movement_test.gd` present (`83b1734`); A/B recorded in baseline.md (8.0 pre-fix vs 4.0 post-fix = exactly 2x); post-fix independently reproduced by verifier | OK |
| 5.2 Determinism grep clean | [x] | Only documented server-gated exceptions | OK |
| 5.3 baseline.md written | [x] | Present, updated with runtime evidence + new finding | OK |

Completed: 17/17.

## Build / Tests / Coverage Evidence (executed by verifier, 2026-07-28, HEAD `83b1734`)

| Command | Result |
|---------|--------|
| `python3 tests/verify_export_isolation.py` | PASS — 0 violations, presets OK, 2/2 .gdignore |
| `python3 tests/verify_headless_server.py --quick` | PASS — all quick checks |
| `Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/unit -gexit` | 7/7 passed (1 warning: unfreed children) |
| `Godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://tests/integration -gexit` | 9/9 passed, 25 asserts (10 orphans; 12 ObjectDB leaks at exit) |
| Live A/B runtime test (post-fix): headless server + `tests/manual/runtime_movement_test.gd -- --server-port=59038` | `[RT-TEST] PASS: single-tick movement (ratio 0.40)` — p50=p75=p90=4.000 m/s, 90 ticks sampled at tickrate=30 |

Runtime test gotcha (verifier note): the scripted client must run WITHOUT `--headless`; with `--headless`, `GameManager` self-detects as server, the instance binds as peer id 1, and no player spawns. The script header's usage line is correct as written.

## Spec / Success-Criteria Compliance (proposal.md)

| Criterion | Evidence | Status |
|-----------|----------|--------|
| Both smoke scripts pass | Re-executed, PASS | COMPLIANT |
| GDScript suites execute | GUT unit 7/7 + integration 9/9 re-executed | COMPLIANT |
| One input → exactly one movement/attack per tick | Runtime A/B: 8.0 m/s pre-fix (`dd0de46~1`) vs 4.0 m/s post-fix — exactly 2x delta proves double-tick existed and is removed; uniform percentiles (p50=p75=p90) confirm no duplication bursts; post-fix independently reproduced by verifier | COMPLIANT |
| No nondeterminism in rollback paths | Grepped; only documented server-gated exceptions | COMPLIANT |
| Spawn ID strategy documented + replication metadata | baseline.md + match_manager.gd + .tscn configs verified | COMPLIANT |
| Baseline record committed | `4214a8e` + runtime evidence `83b1734` | COMPLIANT |

## Design Coherence

Unchanged from v1 — all decisions verified (forwarding removal isolated in `dd0de46`, `process_settings()` rule, determinism dispositions, spawn ID format, replication configs additive, feature tag + editor guard, GUT vendored without plugin). `83b1734` touches only docs + the new manual test script; no design deviation introduced.

## Issues

### CRITICAL

None. (v1 CRITICAL — task 5.1 runtime evidence — resolved by `83b1734` and independently reproduced.)

### WARNING

1. **Tickrate negotiation + speed calibration (new, pre-existing, follow-up scoped).** Netfox handshake negotiates tickrate 30 despite `tickrate=60` in `project.godot`; steady-state speed measures 4.0 m/s vs designed `max_speed = 10.0` (`LogicComponent.gd:7`); `NetworkTime.physics_factor` is unused in `core/`/`common/`. Confirmed by verifier's own run (tickrate=30, 4.000 m/s). **Scope assessment: does NOT block archive of this change** — (a) it predates the fix (pre-fix measured 8.0 = 2x of the same wrong baseline, so the A/B comparison is valid on equal footing); (b) this change's success criterion is per-tick duplication removal, which is proven independent of absolute speed calibration; (c) it is documented in baseline.md as a separate follow-up change. It MUST be tracked as its own change before any gameplay tuning or rollback-timing work depends on absolute speed or tick timing.
2. **Stacked branches are local-only; no PRs exist (carried from v1).** `feature/rollback-integrity-baseline` and `feature/rollback-integrity-etapa1` are not pushed; `gh pr list` is empty. The PR 1 / PR 2 chain is not realized for review.
3. **GUT runs report resource leaks (carried from v1; re-observed).** Integration: 10 orphans, 12 ObjectDB instances leaked at exit, 1 resource still in use. Tests pass; likely netfox/autoload lifecycle noise.

### SUGGESTION

1. Client export preset excludes `res://addons/netfox/` — latent risk for Stage 8; confirm intent (carried).
2. `BaseEntity.tscn` has no `MultiplayerSynchronizer` — consider minimal `SceneReplicationConfig` (position) in Stage 2 (carried).
3. Consider documenting the `--headless` gotcha for `runtime_movement_test.gd` more prominently (scripted client must not run headless) to save future verifiers a failed run.

## Verdict

**PASS** — archive-ready. 17/17 tasks complete, all success criteria COMPLIANT with independently reproduced runtime evidence, design coherence intact. The tickrate/speed-calibration finding is correctly scoped as a follow-up change and does not block. Before/at archive: consider pushing branches and opening the PR chain (WARNING 2), and create the follow-up change for tickrate negotiation + `physics_factor` (WARNING 1).
