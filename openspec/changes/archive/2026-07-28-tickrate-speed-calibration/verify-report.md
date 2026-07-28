# Verify Report: tickrate-speed-calibration

- **Change**: `tickrate-speed-calibration`
- **Mode**: Standard (strict_tdd: false)
- **Branch**: `feature/tickrate-speed-calibration` (3df78af, 3d663c9, eb446e6) off `feature/rollback-integrity-etapa1`
- **Verifier**: sdd-verify phase agent (independent re-execution, 2026-07-28)
- **Godot**: 4.7.stable.official (`/Applications/Godot.app/Contents/MacOS/Godot`)
- **Verdict**: **PASS WITH WARNINGS**

## 1. Completeness (tasks.md — 11/11 checked)

| Task | Claim | Verified | Evidence |
|------|-------|----------|----------|
| 1.1 `[netfox.time]` → `[netfox]`, `time/tickrate=60` | [x] | PASS | project.godot:80-82 |
| 1.2 Remove dead rendering keys, no `[rendering]` section | [x] | PASS | `renderer/rendering_method` and `rendering_device/driver.windows` deleted (not commented — task allowed either); no `[rendering]` section exists |
| 1.3 Headless boot probe | [x] | PASS | Re-executed probe: `netfox/time/tickrate = 60`, no `netfox.time/*` leaks, `rendering_method = forward_plus` |
| 2.1 Wrap in `LogicComponent._apply_movement` | [x] | PASS | core/LogicComponent.gd:239 (multiply), :248 (divide after read-back) |
| 2.2 Wrap in `ProjectileEntity._rollback_tick` | [x] | PASS | common/ProjectileEntity.gd:51 (multiply), :53 (divide) |
| 2.3 Ratio band [0.9, 1.1] replaces p75 band | [x] | PASS | tests/manual/runtime_movement_test.gd:21-22, :192-193 (aggregate ratio) |
| 2.4 Desynced-FPS coverage (40/144) | [x] | PASS | `FPS_MATRIX = [40, 60, 75, 144]` with vsync disabled; assert per pass |
| 3.1 Runtime matrix 40/60/75/144 | [x] | PASS | Re-executed: ratio 1.00 in all four runs |
| 3.2 Handshake tickrate 60 both peers | [x] | PASS | Client log `Received tickrate 60 from peer 1`; server log `Received tickrate 60 from peer 198028899`; no mismatch warning |
| 3.3 GUT 7/7 + 9/9 + headless boot + server full speed | [x] | PASS (with WARNING-2) | GUT unit 7/7, integration 9/9, `verify_headless_server.py --quick` PASS |
| 3.4 Behavioral jump documented in PR body | [x] | PARTIAL (WARNING-1) | Documented in commit 3d663c9 body, but no PR exists yet |

## 2. Diff Scope (re-executed)

`git diff --stat feature/rollback-integrity-etapa1...HEAD`:

| File | Change | In scope |
|------|--------|----------|
| project.godot | +2/-4 | Yes (spec'd) |
| core/LogicComponent.gd | +9/-4 | Yes (spec'd) |
| common/ProjectileEntity.gd | +5/-1 | Yes (spec'd) |
| tests/manual/runtime_movement_test.gd | +98/-38 | Yes (spec'd) |
| openspec/changes/tickrate-speed-calibration/* (exploration, proposal, spec, tasks) | new | Yes (SDD artifacts) |

No out-of-scope files changed. No `[rendering]` section created. Exclusion scenario holds: no `sync_to_physics`, `tickrate_mismatch_action`, or renderer keys added.

## 3. Runtime Evidence (independently re-executed)

### 3.1 Boot probe
```
[PROBE] netfox/time/tickrate = 60
[PROBE] no netfox.time/* leaks
[PROBE] rendering_method = forward_plus
```
(`has_setting` returns true only because Godot registers the built-in default; project.godot contains no renderer key — grep-verified.)

### 3.2 Runtime fps matrix vs live headless server (fresh server, port 57153)
```
[RT-TEST] tickrate=60
[RT-TEST] fps= 40 speed=10.000 ratio=1.00 (frame p50=20.000 p75=20.000 p90=20.000) PASS
[RT-TEST] fps= 60 speed=10.000 ratio=1.00 (frame p50=10.000 p75=10.000 p90=10.000) PASS
[RT-TEST] fps= 75 speed=10.000 ratio=1.00 (frame p50=10.000 p75=10.000 p90=10.000) PASS
[RT-TEST] fps=144 speed=10.000 ratio=1.00 (frame p50=10.000 p75=10.000 p90=10.000) PASS
[RT-TEST] PASS: framerate-independent movement at tickrate 60
```
Handshake: `Received tickrate 60 from peer 1` (client) / `Received tickrate 60 from peer 198028899` (server). No mismatch warning.

Note: fps=40 frame-level percentiles read 20.0 m/s — the documented per-frame attribution lag at fps < tickrate (multi-tick frames, transform sync lag). The aggregate-over-window assertion (the spec'd PASS criterion) is exact. Accepted deviation per spec/task notes.

### 3.3 GUT suites
- Unit (`tests/unit`): **7/7 passed** (1 orphan warning, pre-existing)
- Integration (`tests/integration`): **9/9 passed**, 25 asserts (10 orphans + ObjectDB leaks at exit, pre-existing cleanup noise)

### 3.4 Python checks
- `tests/verify_headless_server.py --quick`: **PASS** (all quick checks)
- `tests/verify_export_isolation.py`: **PASS** (0 violations, 2/2 .gdignore)

## 4. Spec Compliance Matrix

| Requirement / Scenario | Covering evidence | Status |
|---|---|---|
| Tickrate Configuration / resolves to 60 at runtime | Boot probe + handshake logs (both peers) | PASS |
| Tickrate Configuration / dead rendering key does not leak | project.godot grep + probe (`forward_plus`) | PASS |
| Framerate-Independent Movement / speed = max_speed at native framerate | fps=60/75 runs, ratio 1.00 | PASS |
| Framerate-Independent Movement / framerate-independent (40, 144) | fps=40/144 runs, ratio 1.00 | PASS |
| Framerate-Independent Movement / headless server full speed | Indirect: identical wrap in shared code path + fps-agnostic `physics_factor` math; no direct server-entity speed measurement | WARNING-2 |
| Runtime Verification / ratio band at desynced framerates | Re-executed matrix, exit success path | PASS |
| Runtime Verification / regression suites stay green | GUT 7/7 + 9/9 + headless quick check | PASS |
| Runtime Verification / behavioral jump is correction | Commit 3d663c9 body documents it; PR body pending | WARNING-1 |
| Explicit Exclusions / out-of-scope settings untouched | project.godot diff: only netfox section touched | PASS |

## 5. Correctness: wrap pattern

Both edit sites follow the netfox-canonical pattern (netfox `network-time.gd:240-242`: *"multiply any velocities with this variable... Don't forget to then divide by this value if it's a persistent variable"*):

- `core/LogicComponent.gd:239`: `entity.velocity = current_velocity * NetworkTime.physics_factor` → `move_and_slide()` → `:248` `current_velocity = entity.velocity / NetworkTime.physics_factor` (divide after read-back; persistent velocity correctly normalized).
- `common/ProjectileEntity.gd:51`: `velocity = _direction * speed * NetworkTime.physics_factor` → `move_and_slide()` → `:53` `velocity /= NetworkTime.physics_factor`.

`physics_factor` is read-only (`ticktime / _process_delta` outside physics frames) — matches the `_process`-driven tick loop (`sync_to_physics=false`). Sub-1e-6 float drift from the wrap is accepted per spec.

## 6. Findings

### CRITICAL
- None.

### WARNING
1. **Task 3.4 evidence lives in a commit body, not a PR body.** The 4.0 → 10.0 m/s correction (players, dash, knockback, server AI) is documented in commit `3d663c9`'s message, but the PR against `feature/rollback-integrity-etapa1` has not been opened. When the PR is created, its body must carry the same callout; do not treat 3.4 as fully closed until then.
2. **"Headless server moves at full speed" scenario lacks a direct measurement test.** Server-side (mob) speed is verified only indirectly: the same wrapped `_apply_movement`/`_rollback_tick` code paths run on the server, and `physics_factor = ticktime / _process_delta` is fps-agnostic by construction (covers uncapped fps). A future runtime test asserting mob aggregate speed on the headless server would close this gap. Not blocking: the fps=144 run already exercises physics_factor > 1 conditions client-side.

### SUGGESTION
1. Orchestrator prompt referenced `tools/verify_*.py`; the scripts live at `tests/verify_*.py`. Cosmetic path drift only.
2. At fps=40 the per-frame p50/p75/p90 print 20.0 m/s (2×). Correct per the documented attribution lag, but the printed percentiles could confuse future readers — consider labeling them "frame-attributed (informational)".
3. Pre-existing GUT hygiene noise (unfreed children, ObjectDB leaks at exit) persists; out of scope here, worth a cleanup task eventually.

## 7. Final Verdict

**PASS WITH WARNINGS** — All four ADDED requirements and their scenarios are satisfied by independently re-executed runtime evidence. The two warnings are documentation-carryover (PR body pending) and an indirect-coverage gap on the server-speed scenario; neither blocks archive readiness once the PR body carries the commit-message callout.
