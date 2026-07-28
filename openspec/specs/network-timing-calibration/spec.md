# Delta for network-timing-calibration

New capability: tickrate configuration correctness and framerate-independent rollback movement. Ownership: shared — the configuration applies to both peers; the movement integration applies wherever rollback-aware entities run `move_and_slide()` (player-owned `LogicComponent` contexts and shared `ProjectileEntity`).

## ADDED Requirements

### Requirement: Tickrate Configuration

The project MUST configure the netfox tickrate via the correct Godot section syntax: a `[netfox]` section in `project.godot` containing `time/tickrate=60`. The project MUST NOT use a `[netfox.time]` section, which Godot parses as `netfox.time/tickrate` and netfox silently ignores (falling back to its default 30). The dead `renderer/rendering_method="mobile"` line under the old malformed section MUST be removed or commented with an explanatory note, and MUST NOT be relocated under a `[rendering]` section — the project stays on the default `forward_plus` renderer. The tickrate value MUST remain 60.

#### Scenario: Tickrate resolves to 60 at runtime

- GIVEN `project.godot` contains `[netfox]` with `time/tickrate=60`
- WHEN the `NetworkTime` autoload initializes on either peer
- THEN `ProjectSettings.get_setting("netfox/time/tickrate")` returns 60
- AND the tickrate handshake log shows tickrate 60 on both peers with no mismatch warning

#### Scenario: Dead rendering key does not leak

- GIVEN the malformed `[netfox.time]` section is removed
- WHEN the project boots
- THEN no `renderer/rendering_method` entry exists under any section
- AND the active rendering method remains `forward_plus` (default)

### Requirement: Framerate-Independent Rollback Movement

Rollback-aware movement using `move_and_slide()` MUST wrap the call with `NetworkTime.physics_factor`: multiply velocity by the factor before the call and divide the read-back velocity by the factor after it. This applies to `LogicComponent._apply_movement` (core/LogicComponent.gd) and `ProjectileEntity._rollback_tick` (common/ProjectileEntity.gd). Effective real-world speed MUST equal the configured `max_speed` regardless of render framerate, on clients and on the uncapped-FPS headless server. Rollback float drift introduced by the multiply/divide wrap (sub-1e-6) is acceptable per the netfox-canonical pattern.

#### Scenario: Speed equals max_speed at native framerate

- GIVEN a player entity with `max_speed = 10.0` under rollback
- WHEN movement is applied over network ticks
- THEN measured real-world speed approximates 10.0 m/s within ±10%

#### Scenario: Speed is framerate-independent

- GIVEN the same entity and tickrate 60
- WHEN the render framerate is capped at 40 or 144 FPS (`Engine.max_fps`)
- THEN measured real-world speed still approximates 10.0 m/s within ±10%

#### Scenario: Headless server moves at full speed

- GIVEN the headless server with uncapped FPS
- WHEN server-owned entities move under rollback ticks
- THEN their effective speed matches design speed, not a crawl

### Requirement: Runtime Verification of Speed Calibration

`tests/manual/runtime_movement_test.gd` MUST assert the measured-speed / `max_speed` ratio approximates 1.0 (band [0.9, 1.1]), replacing the old p75 ∈ [3.0, 15.0] band. The test MUST pass at desynced framerates (`Engine.max_fps` 40 and 144) to defeat the tickrate==FPS masking coincidence. GUT suites (unit 7/7, integration 9/9) and the headless server boot check MUST remain green.

#### Scenario: Ratio band passes at desynced framerates

- GIVEN the fixed configuration and movement wrap
- WHEN the runtime test runs at `Engine.max_fps` 40 and at 144
- THEN the measured/max_speed ratio stays within [0.9, 1.1] in both runs

#### Scenario: Regression suites stay green

- GIVEN the change is applied
- WHEN GUT unit and integration suites and the headless boot check run
- THEN unit 7/7 and integration 9/9 pass and the server boots cleanly

#### Scenario: Post-fix behavioral jump is expected

- GIVEN pre-fix baselines (players ~4.0 m/s, server crawl)
- WHEN verification compares post-fix behavior
- THEN players at ~10.0 m/s and full server speed are judged a CORRECTION, not a regression

### Requirement: Explicit Exclusions

This capability MUST NOT: change `sync_to_physics` from its default (false); harden the tickrate handshake ADJUST mode; change the tickrate value from 60; or change the rendering method from `forward_plus`.

#### Scenario: Out-of-scope settings untouched

- GIVEN the change is applied
- WHEN `project.godot` and netfox configuration are inspected
- THEN `sync_to_physics`, `tickrate_mismatch_action`, and renderer settings are unchanged from their pre-change effective values
