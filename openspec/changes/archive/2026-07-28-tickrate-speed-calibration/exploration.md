# Exploration: Tickrate Negotiation, Speed Calibration, and `physics_factor`

Change: `tickrate-speed-calibration`
Date: 2026-07-28
Context: follow-up to archived `rollback-integrity-baseline` (WARNING 1 in its verify-report). Post-fix runtime A/B evidence surfaced three discrepancies: negotiated tickrate 30 vs configured 60, measured speed 4.0 m/s vs `max_speed = 10.0`, and `NetworkTime.physics_factor` unused.

## Executive Summary

All three symptoms have a single mechanical story, now engine-verified:

1. **Tickrate 30 is not a negotiation — it is a silent fallback.** `project.godot` uses a hand-edited section `[netfox.time]`, which Godot parses as the setting `netfox.time/tickrate` — NOT `netfox/time/tickrate`. Netfox reads `netfox/time/tickrate`, finds nothing, and falls back to its default **30** (`addons/netfox/network-time.gd:368`). Verified empirically with Godot 4.7.stable headless probes on both section syntaxes.
2. **Speed 4.0 m/s is framerate-dependent integration error, not a clamp.** `LogicComponent._apply_movement` (core/LogicComponent.gd:234-235) calls `move_and_slide()` from netfox's `_process`-driven tick loop (`sync_to_physics=false`), so Godot integrates velocity over the **render frame delta**, not the network tick delta. Effective speed = `max_speed × frame_delta × tickrate` = 10 × (1/75) × 30 = **4.0 m/s** on the ~75 Hz measurement client. On a 60 Hz client it would read 5.0; on 120 Hz, 2.5. Nothing "limits" speed to 4.0 — the design speed IS applied, over the wrong time quantum.
3. **`physics_factor` is exactly the missing piece.** Its own docstring (addons/netfox/network-time.gd:231-245) describes this precise bug. Wrapping `move_and_slide()` with it (`velocity *= NetworkTime.physics_factor` / `/=`) makes per-tick displacement framerate-independent on clients AND on the uncapped-FPS headless server.

Recommended fix: **correct the `project.godot` section syntax (`[netfox]` + `time/tickrate=60`) AND add the `physics_factor` wrap in `_apply_movement`.** Two orthogonal root causes, ~15–20 changed lines total, low risk. Must land before Match Foundation tuning.

## Current State

### Q1 — Where the "negotiation" happens, and why 30 wins

- The tickrate handshake is `NetworkTickrateHandshake` (addons/netfox/time/network-tickrate-handshake.gd). On `NetworkTime.start()` (network-time.gd:459) each peer broadcasts its configured tickrate (`_submit_tickrate`, lines 44-51). On receipt (line 93-98) it compares and, on mismatch, acts per `netfox/time/tickrate_mismatch_action` — default **WARN** (line 28). There is NO negotiation/min-max logic: it never changes the local tickrate except in the opt-in ADJUST mode, which only runs client-side and is flagged unreliable (`# TODO: Make tickrate mutable at user's digression`, line 87).
- Since both peers logged/used 30 with no mismatch warning, both independently computed tickrate 30. The log line seen in testing (`Received tickrate 30 from peer 1`, line 95) is informational, not a mismatch.
- The local tickrate is fixed at autoload init: `var _tickrate: int = ProjectSettings.get_setting(&"netfox/time/tickrate", 30)` (network-time.gd:368); read-only thereafter (network-time.gd:11-18).
- **Root cause (engine-verified):** project.godot:80-82 reads:
  ```
  [netfox.time]
  tickrate=60
  ```
  Godot does NOT map dotted section names to slash-separated setting paths. Probe on Godot 4.7.stable: this file produces `netfox.time/tickrate = 60` and `has_setting("netfox/time/tickrate") == false`. Netfox therefore takes its default 30. Counter-probe with the correct syntax:
  ```
  [netfox]
  time/tickrate=60
  ```
  produces `netfox/time/tickrate = 60`. This is also the syntax the editor itself uses when saving (section = text before the first `/`).
- Contributing confusion: in the EDITOR, the netfox plugin (addons/netfox/netfox.gd:16-20, 199-210) registers `netfox/time/tickrate` with default 30, so Project Settings has always *shown* 30; the hand-written 60 was dead text nobody noticed because the editor UI and the runtime agreed on 30.

### Q2 — What limits speed to 4.0 m/s

Nothing clamps it. The chain in `LogicComponent._apply_movement` (core/LogicComponent.gd:199-243):

- `target_vel = move_dir * max_speed` (line 229) → 10.0 m/s. No scene overrides `max_speed` (grep of all `.tscn`: zero hits), so the exported default 10.0 (line 7) is live.
- `move_toward(target_vel, acceleration * 10.0 * delta)` (line 230) reaches 10.0 in ~4 ticks — delta-scaled, tickrate-safe.
- `entity.velocity = current_velocity; entity.move_and_slide()` (lines 234-235): netfox runs its tick loop from `_process` because `sync_to_physics` defaults to false (network-time.gd:369, 572-576). `move_and_slide()` called outside a physics frame integrates velocity over `get_process_delta_time()` — the **render frame time**.
- Effective real speed = `max_speed × frame_delta × tickrate`. Measured 4.000 m/s with tickrate 30 implies frame_delta = 1/75 s (~75 Hz render clock on the verifier's machine — uniform p50=p75=p90 is consistent with vsync). The archived pre-fix 8.0 = exactly 2× the same wrong baseline (double-tick), confirming the same mechanism.
- Corollary (worse): the headless server runs uncapped FPS, so its `_process_delta` is tiny and server-side `move_and_slide()` displacement per tick is far below design — AI/mob movement on the server crawls by the same mechanism.

### Q3 — `physics_factor`: needed or not, and the idiomatic pattern

Needed. Netfox's own docstring for `physics_factor` (network-time.gd:231-245) describes this exact failure mode ("the network ticks run at 30 fps, while the game is running at 60fps, thus move_and_slide will also assume that it's running on 60fps, resulting in slower than expected movement"). Its value is `ticktime / _process_delta` in process frames (line 253), i.e. exactly the correction factor to convert per-frame integration into per-tick integration. Idiomatic usage in `_apply_movement` (core/LogicComponent.gd:233-243):

```gdscript
entity.velocity = current_velocity * NetworkTime.physics_factor
entity.move_and_slide()
current_velocity = entity.velocity / NetworkTime.physics_factor
```

Without it, after fixing tickrate to 60: a 60 Hz client coincidentally gets the right speed (factor = 1.0), but a 120/144 Hz client moves at 5.0/4.17 m/s and the headless server still crawls. The bug is only *masked* at tickrate == fps. `ProjectileEntity._rollback_tick` (common/ProjectileEntity.gd:48-49) has the same unwrapped `move_and_slide()` and needs the same treatment.

## Affected Areas

- `project.godot:80-84` — malformed `[netfox.time]` section; fix to `[netfox]` + `time/tickrate=60`. Lines 83-84 (`rendering_device/driver.windows`, `renderer/rendering_method`) are also dead settings (`netfox.time/rendering_device/...`); they belong under `[rendering]` and should be relocated or removed (see Risks — renderer intent never applied).
- `core/LogicComponent.gd:233-243` — wrap `move_and_slide()` with `NetworkTime.physics_factor` (including the velocity read-back at line 243).
- `common/ProjectileEntity.gd:48-49` — same wrap for projectile movement.
- `tests/manual/runtime_movement_test.gd` — expectations still pass post-fix (PASS band is p75 ∈ [3.0, 15.0] and ratio ≤ 1.5; post-fix ratio ≈ 1.0), but see test-impact notes below.
- GUT suites (`tests/unit`, `tests/integration`) — grep shows zero references to tickrate/physics_factor/max_speed/NetworkTime; unaffected.

## Approaches

### Tickrate (Q1)

1. **Fix the project.godot section syntax → 60 Hz as designed** — `[netfox]` + `time/tickrate=60`; delete/relocate the dead rendering keys.
   - Pros: root cause, one line, engine-verified fix; honors the original design intent; editor and runtime finally agree.
   - Cons: doubles tick frequency vs the de-facto 30 Hz — CPU/bandwidth increase; any habit built around 30 Hz timing must be revisited (nothing is tuned yet, per roadmap).
   - Effort: Low

2. **Accept 30 Hz — write it correctly and move on** — `[netfox]` + `time/tickrate=30`, delete the dead 60.
   - Pros: zero runtime behavior change; lower CPU/bandwidth; matches all existing runtime evidence.
   - Cons: contradicts the documented 60 Hz intent; coarser input sampling and rollback granularity; must be a conscious gameplay decision, not a default by accident.
   - Effort: Low

3. **Runtime override / handshake ADJUST mode** — rejected: `_tickrate` is read-only and cached at autoload init (network-time.gd:368); ADJUST only fires client-side after connect and is TODO'd unreliable (network-tickrate-handshake.gd:84-88). Not a viable configuration path.

### Speed integration (Q2/Q3)

1. **`physics_factor` wrap in `move_and_slide()` callsites** (netfox-idiomatic).
   - Pros: documented pattern endorsed by the docstring that describes this exact bug; framerate-independent at any client refresh rate AND on the uncapped headless server; tiny diff; orthogonal to the tickrate decision (works at 30 or 60).
   - Cons: must be applied at every `move_and_slide()` in rollback contexts (LogicComponent + ProjectileEntity today); per-tick float multiply/divide adds negligible rounding noise to rollback state.
   - Effort: Low

2. **`sync_to_physics=true`** — run netfox ticks inside physics frames.
   - Pros: `move_and_slide()` then uses the physics delta natively (no wrap needed); tickrate becomes `Engine.physics_ticks_per_second` (60) by construction, sidestepping the broken setting; deterministic fixed-step timing on the headless server.
   - Cons: project-wide timing-model change — `before_tick_loop`/`on_tick` (input sampling, `LogicComponent._gather_input`) move into physics context; TickInterpolator semantics shift; blast radius across every rollback-aware node; hides rather than fixes the config bug. Better as a later architectural decision than as this change.
   - Effort: Medium

3. **Manual fixed-tick integration** (`position += v * delta`, drop `move_and_slide()`) — rejected: loses slide/collision response that a PvPvE arena game needs.

## Recommendation

**Approach 1 + 1: fix `project.godot` to `[netfox] time/tickrate=60` AND add the `physics_factor` wrap.** They are orthogonal root causes sharing one symptom cluster; fixing only one leaves the other latent (e.g. 60 Hz + no wrap passes tests on 60 Hz displays by coincidence and still breaks 144 Hz players and the server).

Scope sketch (~15–20 changed lines, well under the 400-line review budget):

| File | Change | Size |
|------|--------|------|
| `project.godot` | `[netfox.time]` → `[netfox]`, `tickrate=60` → `time/tickrate=60`; relocate/remove the two dead rendering keys | ~4 lines |
| `core/LogicComponent.gd` | `physics_factor` wrap around `move_and_slide()` + velocity read-back in `_apply_movement` | ~6 lines |
| `common/ProjectileEntity.gd` | same wrap in `_rollback_tick` | ~4 lines |
| `tests/manual/runtime_movement_test.gd` | (optional, recommended) tighten PASS band around 10.0 (e.g. ratio ∈ [0.9, 1.1]) and add a desynced-FPS run note | ~4 lines |

Verification approach: re-run the A/B runtime test — expect p50/p75/p90 ≈ 10.0 at tickrate 60; then re-run with a capped frame rate (e.g. `Engine.max_fps` 40 or 144) to prove speed stays 10.0 (framerate independence), which the current test cannot detect at tickrate == fps. GUT suites need no changes.

## Risks

- **Behavioral jump**: absolute player speed goes 4.0 → 10.0 m/s and dash/knockback scale with it (they were equally wrong; this is a correction, but anything tuned against 4.0 must be redone — per the roadmap nothing is yet).
- **Hidden fourth discrepancy (same root cause)**: the misplaced `renderer/rendering_method="mobile"` under `[netfox.time]` is dead — probe shows the project actually runs `rendering/renderer/rendering_method = forward_plus` (default) on desktop. Deciding whether the mobile renderer was intended is out of scope here but should be flagged; relocating the key changes visuals.
- **Server-side movement magnitude**: on the uncapped headless server, entities currently move far below design speed; after the fix server-side speed jumps by a large factor. Expect visible AI/mob behavior change — validate with the runtime test's mob-facing scenario.
- **Rollback float noise**: multiply/divide by `physics_factor` on persistent velocity is mathematically identity at steady state but can introduce sub-1e-6 drift into recorded rollback state; netfox documents this pattern as canonical, so risk is accepted but should be watched in determinism checks.
- **Test masking**: after the tickrate fix alone, `runtime_movement_test.gd` PASSES on a 60 Hz client even without the `physics_factor` wrap (factor == 1.0 coincidence). Verification MUST include a desynced-FPS run or the wrap can be silently omitted.

## Ready for Proposal

Yes. Root causes are engine-verified with file:line evidence, the fix surface is ~15–20 lines across 3 files, and the verification path is concrete. The orchestrator should tell the user: this is a config-syntax bug plus a missing netfox idiom — small diff, big behavioral correction, and it must land before Match Foundation tuning depends on absolute speed or tick timing.
