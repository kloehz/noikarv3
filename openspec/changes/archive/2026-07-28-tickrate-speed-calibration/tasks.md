# Tasks: Tickrate and Speed Calibration

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~20–35 (config + 2 wraps + test updates) |
| 400-line budget risk | Low |
| Chained PRs recommended | No |
| Suggested split | Single PR (`feature/tickrate-speed-calibration`, stacked on `feature/rollback-integrity-etapa1`) |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: No
Chain strategy: stacked-to-main
400-line budget risk: Low

### Suggested Work Units

| Unit | Goal | Likely PR | Notes |
|------|------|-----------|-------|
| 1 | Fix `project.godot` netfox section syntax | PR 1 | Commit 1; config-only, independently revertible |
| 2 | `physics_factor` wraps + runtime test tightening/desynced-FPS coverage | PR 1 | Commit 2; tests ship with the code they verify |
| 3 | Verification runs (no code) | PR 1 | Evidence for PR body; no commit |

## Phase 1: Configuration Fix (Work Unit 1)

- [x] 1.1 In `project.godot:80-84`, replace `[netfox.time]` with `[netfox]` and `tickrate=60` with `time/tickrate=60`.
- [x] 1.2 Comment out (with note: dead key, project stays forward_plus) or remove the `renderer/rendering_method="mobile"` line; do NOT create a `[rendering]` section; remove `rendering_device/driver.windows` dead key with it.
- [x] 1.3 Headless boot probe: `ProjectSettings.get_setting("netfox/time/tickrate")` returns 60; no `renderer/rendering_method` setting exists anywhere.

## Phase 2: Movement Wrap + Test Update (Work Unit 2)

- [x] 2.1 In `core/LogicComponent.gd:229-235` (`_apply_movement`): multiply velocity by `NetworkTime.physics_factor` before `move_and_slide()`, divide the read-back velocity after it.
- [x] 2.2 In `common/ProjectileEntity.gd:48-49` (`_rollback_tick`): apply the identical multiply/divide wrap.
- [x] 2.3 In `tests/manual/runtime_movement_test.gd`: replace PASS band p75 ∈ [3.0, 15.0] with measured/max_speed ratio ∈ [0.9, 1.1].
- [x] 2.4 Add desynced-FPS coverage to the runtime test: runs at `Engine.max_fps` 40 and 144 asserting the same ratio band (MANDATORY — defeats the tickrate==fps masking coincidence).

## Phase 3: Verification (Work Unit 3)

- [x] 3.1 Run runtime test at 40/60/75/144 fps: ratio ≈ 1.0 (band [0.9, 1.1]) in all runs; record p50/p75/p90 as PR evidence.
- [x] 3.2 Run two peers; confirm handshake log shows tickrate 60 on both with no mismatch warning.
- [x] 3.3 Run GUT suites: unit 7/7 and integration 9/9 green; headless server boot check green; server-side entities move at full design speed.
- [x] 3.4 Confirm the 4.0 → 10.0 m/s jump (players, dash, knockback, server AI) is documented in the PR body as the expected correction per spec.
