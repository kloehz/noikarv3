# Proposal: Tickrate and Speed Calibration

## Intent

Two engine-verified root causes make absolute speed and tick timing untrustworthy:
(1) a malformed `[netfox.time]` section in `project.godot` silently drops the configured
tickrate 60, so netfox falls back to 30 (`network-time.gd:368`); (2) `move_and_slide()`
runs from netfox's `_process`-driven tick loop, integrating over the render frame delta —
effective speed = `max_speed × frame_delta × tickrate` (4.0 m/s measured instead of 10.0).
This is a **prerequisite for roadmap Stage 2 (Match Foundation)**: gameplay tuning cannot
start until speed and tick timing are deterministic across client framerates and on the
uncapped-FPS headless server.

## Scope

### In Scope
- Fix `project.godot:80-84`: `[netfox.time]` → `[netfox]`, `tickrate=60` → `time/tickrate=60`; remove/comment the dead `renderer/rendering_method="mobile"` line with a note (deliberate non-goal: do NOT create a `[rendering]` entry — project has always run forward_plus).
- Add `NetworkTime.physics_factor` wrap (multiply before `move_and_slide()`, divide on read-back) in `core/LogicComponent.gd:229-243` (`_apply_movement`).
- Same wrap in `common/ProjectileEntity.gd:48-49` (`_rollback_tick`).
- Update `tests/manual/runtime_movement_test.gd`: PASS band asserts measured/max_speed ratio ≈ 1.0 (e.g. [0.9, 1.1]); add desynced-FPS coverage via `Engine.max_fps` (40 and 144) to defeat the tickrate==fps masking coincidence.

### Out of Scope
- Relocating `rendering/rendering_method` (visuals-changing decision; keep forward_plus).
- `sync_to_physics=true` (project-wide timing-model change, Medium risk — deferred).
- Tickrate handshake hardening (WARN-only today; ADJUST mode is TODO'd unreliable in netfox).
- Changing the target tickrate (stays 60, the original intent).

## Capabilities

### New Capabilities
- `network-timing-calibration`: tickrate configuration correctness and framerate-independent movement integration in rollback contexts.

### Modified Capabilities
- None (no existing specs under `openspec/specs/`).

## Approach

Both fixes land in ONE change because they interact: after the tickrate fix alone, the
runtime test passes on 60 Hz displays even WITHOUT `physics_factor` (factor == 1.0
coincidence). ~15–20 changed lines total, well under the 400-line review budget —
single PR, no chaining needed.

## Affected Areas

| Area | Impact | Description |
|------|--------|-------------|
| `project.godot` | Modified | Section syntax fix; dead rendering key removed/commented |
| `core/LogicComponent.gd` | Modified | `physics_factor` wrap around `move_and_slide()` |
| `common/ProjectileEntity.gd` | Modified | Same wrap in `_rollback_tick` |
| `tests/manual/runtime_movement_test.gd` | Modified | Ratio≈1.0 PASS band; desynced-FPS runs |

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Behavioral jump 4.0 → 10.0 m/s (players, dash, knockback) | High (certain) | Correction, not regression — nothing tuned yet per roadmap; call out in PR |
| Server uncapped-FPS crawl fixed → AI/mob speed jumps | High (certain) | Validate via runtime test mob-facing scenario |
| Rollback float drift from multiply/divide wrap | Low | Netfox-canonical pattern; watch determinism checks |
| Test masking at tickrate == fps | Medium | Mandatory desynced-FPS runs (40/144) in verification |

## Rollback Plan

All edits are small and independent: revert the single commit/PR. `project.godot` restores
to de-facto 30 Hz; the two wraps revert to unwrapped `move_and_slide()`. No data or API
migration involved.

## Dependencies

- Archived `rollback-integrity-baseline` (PRs #3/#4 open, unmerged) — stack on top; no code conflict expected (different files).

## Success Criteria

- [ ] Runtime test: measured/max_speed ratio ≈ 1.0 (band [0.9, 1.1]) at 40/60/75/144 fps
- [ ] Handshake log shows tickrate 60 on both peers
- [ ] Server-side (headless) movement matches design speed
- [ ] GUT suites stay green (7/7 unit, 9/9 integration)
