# Netfox Audit

This audit is based on the current project code, existing local benchmark artifacts, first production VPS evidence from deployment commit `50395c0`, and follow-up `c30bf6e` spawn/state handshake evidence. Local CPU percentages remain local-machine observations only; production VPS results below are evidence for that host and run shape, not capacity limits.

## Current Architecture

The project is already closer to a server-authoritative room architecture than the original hypothesis suggested.

- **Human players** are instantiated from `scenes/BaseEntity.tscn` and use Netfox rollback/prediction via `RollbackSynchronizer`.
- **Mobs/enemies** are instantiated from `scenes/EnemyEntity.tscn` and do **not** have a `RollbackSynchronizer`. They use authoritative state snapshots through `ServerState/StateSynchronizer`, with render interpolation through `TickInterpolator`.
- **Pets** follow the same NPC-style snapshot architecture as mobs in `scenes/PetEntity.tscn`.
- **Projectiles, souls, and totems** use Godot `MultiplayerSynchronizer` / spawning replication, not Netfox rollback.
- **Match state** uses a cadenced Netfox `StateSynchronizer` under `scenes/main.tscn`.

Important correction: the current code does **not** show mobs entering player rollback. The CPU cost from mobs is more likely from authoritative AI, movement/physics, combat checks, interest filtering, and snapshot/state replication than from rollback resimulation.

Documentation caveat: current runtime config is 30 Hz, but `openspec/config.yaml` and `openspec/specs/network-timing-calibration/spec.md` still describe/require 60 Hz rollback/timing. Treat those OpenSpec artifacts as stale or unresolved before using them as implementation truth.

## Rollback Scope

### Player entities

Source: `scenes/BaseEntity.tscn`.

`RollbackSynchronizer` exists on the player base scene with:

- `root = NodePath("..")`
- `enable_prediction = true`
- `state_properties`:
  - `:global_position`
  - `:quaternion`
  - `LogicComponent:current_velocity`
  - `CombatComponent:current_attack_state`
  - `CombatComponent:_state_timer`
  - `CombatComponent:sync_attack_count`
  - `CombatComponent:is_charging`
  - `CombatComponent:current_charge_time`
  - `CombatComponent:_projectile_direction`
  - `CombatComponent:_active_damage_multiplier`
  - `CombatComponent:_active_r_stun_token`
  - `CombatComponent:_active_attack_slot`
  - `CombatComponent:_primary_cooldown`
  - `CombatComponent:_secondary_cooldown`
  - `LogicComponent:is_dashing`
  - `LogicComponent:dash_direction`
- `input_properties`:
  - `LogicComponent:input_axis`
  - `LogicComponent:is_shooting`
  - `LogicComponent:ability_q_pressed`
  - `LogicComponent:ability_e_pressed`
  - `LogicComponent:ability_r_pressed`
  - `LogicComponent:look_yaw`
  - `LogicComponent:look_pitch`

Scripts participating in player rollback:

- `core/LogicComponent.gd`
  - `_rollback_tick(delta, tick, is_fresh)` calls `_simulate_tick(...)`.
  - Runs movement, dash state, ability server ticks, stun logic, and `move_and_slide()`.
- `core/CombatComponent.gd`
  - `_rollback_tick(delta, tick, is_fresh)` calls `_simulate_tick(...)`.
  - Runs attack state, charge/projectile state, cooldowns, attack activation, and server-side combat side effects guarded by an event ledger.

Approximate rollback state size per player per tick: at least 16 state properties plus 7 input properties. The expensive-looking entries are full transform state (`global_position`, `quaternion`), `Vector3` velocity/projectile/dash vectors, multiple combat floats, and attack/cooldown state.

`history_limit` is not overridden per player scene; global Netfox config in `project.godot` sets `rollback/history_limit=128`.

### Training dummy

Source: `scenes/TrainingDummy.tscn`.

Has a `RollbackSynchronizer` with:

- `enable_prediction = false`
- state: `:global_position`, `:quaternion`, `LogicComponent:current_velocity`, `CombatComponent:current_attack_state`, `CombatComponent:sync_attack_count`
- input: `LogicComponent:input_axis`, `LogicComponent:is_shooting`, `LogicComponent:look_yaw`

This is a rollback participant if the dummy scene is spawned in a test or runtime path.

### Mobs / enemies

Source: `scenes/EnemyEntity.tscn`.

No `RollbackSynchronizer` node exists. They are **not** in Netfox rollback according to the scene.

They do have:

- `ServerState/StateSynchronizer` using `common/net/NpcStateSynchronizer.gd`
- `TickInterpolator` using `common/net/NpcTickInterpolator.gd`
- `MultiplayerSynchronizer` for spawn-time replicated properties

The existing benchmark scenario F in `BENCHMARK_SERVER.md` also logged `npc_rollback_synchronizers=0`, `npc_snapshot_sync_observable=20`, and `synchronized_entities_observable=21`.

### Pets

Source: `scenes/PetEntity.tscn`.

Same pattern as mobs:

- no `RollbackSynchronizer`
- `ServerState/StateSynchronizer` using `NpcStateSynchronizer`
- `TickInterpolator` using `NpcTickInterpolator`
- `MultiplayerSynchronizer` for spawn data

### Projectiles

Source: `scenes/ProjectileEntity.tscn`, `common/ProjectileEntity.gd`.

The script explicitly says rollback is intentionally absent because prediction is disabled for projectiles. Server movement is driven by `NetworkTime.on_tick`; clients move cosmetically.

### Totems / souls

- `scenes/TotemEntity.tscn`: `StateSynchronizer` for health/death plus `MultiplayerSynchronizer` for spawn/replication.
- `scenes/SoulEntity.tscn`: `MultiplayerSynchronizer`.

No rollback participation found.

## Entity Synchronization Map

| Entity type | Rollback / prediction | Interpolation / history | Synchronization mechanism |
| --- | --- | --- | --- |
| Local player | `RollbackSynchronizer` with prediction enabled; local input sampled on `NetworkTime.before_tick_loop` | `TickInterpolator`; owned player removes quaternion interpolation for instant mouse look | Rollback state/input plus `ServerState/StateSynchronizer` |
| Remote players | Same base `RollbackSynchronizer` scene; remote peers do not gather local input due `_is_local_authority()` guards | `TickInterpolator` keeps position and quaternion for non-owned players | Same rollback/state/input schema as player scene |
| Mobs / enemies / boss / elites | No observed `RollbackSynchronizer`; server authoritative tick via `NetworkTime.on_tick` | `NpcStateSynchronizer`, `NpcTickInterpolator`, `NpcSnapshotBuffer` | Spawn `MultiplayerSynchronizer`; NPC state snapshots |
| Pets | No observed `RollbackSynchronizer`; no implemented pet prediction/reconciliation | Same NPC snapshot/interpolation stack | Spawn `MultiplayerSynchronizer`; NPC state snapshots |
| Projectiles | Explicitly no rollback/prediction; server owns collision/damage/lifetime | No tick interpolator; clients move cosmetically until authoritative despawn | Spawn `MultiplayerSynchronizer` for position/direction/speed |
| Skills / abilities | Ability inputs and combat state are player rollback input/state | Visual attack sync uses `sync_attack_count` | ServerState ability/stun outputs; rollback combat fields |
| Hitboxes / hurtboxes | No direct Netfox synchronizer found | None | Results replicate through health/damage/stun ServerState changes |
| Totems | No rollback; summon request is reliable RPC | None observed | Spawn `MultiplayerSynchronizer`; health/death StateSynchronizer |
| Souls / pickups | No rollback | None observed | Spawn `MultiplayerSynchronizer` |
| Match state | No rollback; server-only phase logic | Cadenced state history via `CadencedStateSynchronizer` | `MatchState/StateSynchronizer` with stride 6 |
| Training dummy | Has `RollbackSynchronizer`, prediction disabled | `TickInterpolator` for position/quaternion | StateSynchronizer plus rollback state/input |

## Synchronization Scope

### Player state snapshots

`scenes/BaseEntity.tscn` has `ServerState/StateSynchronizer` with initial properties:

- `:sync_health`
- `:sync_is_dead`
- `:player_name`
- `:character_id`
- `:knockback_velocity`
- `:knockback_remaining_time`
- `full_state_interval = 8`

`common/components/ServerState.gd` then dynamically adds additional state:

- common state: `max_health`, `sync_health`, `sync_is_dead`, `team_id`, heal/damage event fields, stun fields, ability R fields
- players also add `player_name`, `character_id`, `sync_souls`, `knockback_velocity`, `knockback_remaining_time`, `sync_is_dashing`

Potential duplication: player health/death/name/character/knockback are present in the scene config and also added dynamically in `ServerState.gd`. Netfox may de-duplicate internally, but this should be verified because repeated property registration can inflate snapshot/property work.

### NPC snapshots

`scenes/EnemyEntity.tscn` and `scenes/PetEntity.tscn` start with motion properties:

- `:global_position`
- `:quaternion`
- `full_state_interval = 12`

`ServerState.gd` dynamically adds NPC state:

- common state listed above
- `npc_snapshot_stride`
- presentation state from `_add_npc_presentation_state(...)`:
  - entity `global_position`
  - entity `quaternion`
  - `CombatComponent:sync_attack_count`
- mobs/boss/dummies also add `red_damage_taken`, `blue_damage_taken`
- pets add `pet_type_sync`, `power_level_sync`

`NpcStateSynchronizer.gd` can submit authoritative snapshots at a stride. At the default 30 Hz Netfox tickrate:

- `NOIKAR_NPC_SNAPSHOT_HZ=30` or unset -> stride 1 -> 30 Hz
- `NOIKAR_NPC_SNAPSHOT_HZ=15` -> stride 2 -> 15 Hz
- `NOIKAR_NPC_SNAPSHOT_HZ=10` -> stride 3 -> 10 Hz

The existing nine-run local comparison in `tests/manual/results/npc_snapshot_comparison.json` showed lower median CPU when reducing NPC snapshots from 30 Hz to 15/10 Hz, with authoritative stride proof passing.

### Match state

`scenes/main.tscn` has `MatchState/StateSynchronizer` using `CadencedStateSynchronizer` with `authority_snapshot_stride = 6`. At 30 Hz, that is roughly 5 Hz for authoritative match-state submissions.

### Spawn-time / Godot synchronizers

`MultiplayerSynchronizer` is used by:

- `EnemyEntity.tscn`: spawn properties include `global_position`, `spawn_grace_duration`, `enemy_type`, `actor_scale`, `difficulty`.
- `PetEntity.tscn`: spawn properties include `global_position`, `owner_id`, `pet_type`, `power_level`.
- `ProjectileEntity.tscn`: spawn properties include `position`, `direction`, `speed`.
- `TotemEntity.tscn`: spawn properties include `global_position`, `totem_type`, `stored_souls`.
- `SoulEntity.tscn`: spawn properties include `global_position`, `original_mob_scene_path`.

### RPC scope

Game-level RPCs found are not high-frequency movement RPCs:

- lobby/auth/selection RPCs in `common/match_manager.gd`
- event-driven lobby snapshots via `receive_lobby_snapshot.rpc_id(...)`
- totem summon request via `spawn_totem_rpc.rpc_id(1, preview_type)`

Netfox vendor RPCs exist under `addons/netfox/**` for time/state/rollback transport and should be measured separately from game-level RPC fanout.

## Current Tickrates

From `project.godot`:

- Netfox tickrate: `netfox/time/tickrate=30`
- Rollback history: `netfox/rollback/history_limit=128`
- Physics tickrate: `physics/common/physics_ticks_per_second=30`
- Physics engine: Jolt

Other cadences:

- Player rollback simulation: Netfox tick, 30 Hz.
- Player snapshots / Netfox state: tied to Netfox tick and synchronizer settings.
- NPC authoritative snapshots: default 30 Hz; optional 15 Hz or 10 Hz via `NOIKAR_NPC_SNAPSHOT_HZ` when Netfox tickrate is 30.
- Match state snapshots: `authority_snapshot_stride=6`, about 5 Hz at 30 Hz.
- AI target search: `_target_search_interval = 0.2`, about 5 Hz, in `core/AIComponent.gd`.
- AI decision tick: called from `LogicComponent._simulate_tick()` on authoritative Netfox ticks for non-human server entities; passive far mobs can skip/sleep via `PASSIVE_TICKS_SKIP = 3`, `STAGGER_RADIUS = 45`, `SLEEP_RADIUS = 60`.
- NPC movement/physics: `LogicComponent._apply_npc_movement()` runs from authoritative simulation, i.e. up to 30 Hz for active NPCs.
- Projectiles: server ticked from `NetworkTime.on_tick`, 30 Hz.
- Threat decay: `BaseEntity._on_authoritative_tick()` on `NetworkTime.after_tick`, 30 Hz on server.
- Interest management: `common/interest_manager.gd` uses a 90 m sync radius and `PeerVisibilityFilter.UpdateMode.PER_TICK_LOOP`, so mob visibility filtering can scale as mobs × peers × tick loops.
- Navigation/pathfinding: no project usage of `NavigationAgent`, `NavigationServer`, or pathfinding APIs was found; current mobs use direct steering plus ally avoidance.
- Periodic lobby RPCs: lobby snapshots are event-driven on auth/team/ready/selection changes, not a fixed high-frequency tick.

Impact of reducing rates:

- Reducing NPC snapshot rate should lower state submission/network/interpolation history work. Existing local data suggests median CPU dropped from 11.96% at 30 Hz to 11.30% at 15 Hz and 10.84% at 10 Hz in the 1-player/20-NPC workload.
- Reducing AI target search from 5 Hz could reduce group scans, but combat responsiveness and pet/mob target switching may degrade.
- Reducing server simulation/physics below 30 Hz is higher risk because player rollback, movement, dash, projectiles, cooldowns, and combat timing all currently share that clock.

## Production VPS Evidence and Current Blocker

Deployment commit `50395c0` completed successfully through Deploy World Runtime run `34666205456`; the VPS current symlink pointed to that commit for the first measurements below. Later deploy workflow run `34668695652` succeeded for commit `c30bf6e`, which restored full snapshots to `unreliable_ordered` while preserving the per-`StateSynchronizer` peer replica-ready ACK/visibility handshake introduced in `790c13a`. The VPS has 2 vCPU and 8,136,536 KiB RAM. Production rooms use 20 mobs; the tests deliberately did not mutate global Noray or service configuration to force zero mobs.

Valid production evidence so far:

| Players | Window | Mobs | Result | CPU avg | CPU interval peak | RSS max | Notes |
| ---: | --- | ---: | --- | ---: | ---: | ---: | --- |
| 1 | 5 s warmup, 65 s sample | 20 | client PASS; zero active client errors; 65 sample rows | 26.73% | 49.08% | 103,768 KiB | Artifact `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-1p-xyzc_tyd`; remote `/proc` utime+stime and resident pages sampled over one persistent SSH connection. Treat as one run, not capacity. |
| 2 | 2 s warmup, 10 s sample | 20 | both clients PASS; zero active errors | 36.50% | 41.61% | 104,680 KiB | Artifact `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-2p-a98ovbt2`; short smoke after peer guards only, not comparable to the long 1-player result. |

Invalid or historically blocked production evidence:

- A long 2-player attempt is invalid because the player node was freed during workload. The harness now fails cleanly instead of dereferencing a freed instance.
- Before the handshake fix, 4-player production attempts were invalid because dynamic Player and Mob `StateSynchronizer` paths were missing before nodes materialized, producing hundreds of `Node not found`, `Failed to get path from RPC`, and `Invalid packet` errors. A discriminating repeat with sequential admission plus a 10 s lobby hold still failed: all four clients were admitted but none passed; RPC missing counts were client0=289, client1=23, client2=223, client3=331, and fixed population observed was 0. Artifact `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-4p-impg1qcq`. The failure persisted despite admission and settle timing, which supported a product Netfox spawn/state ordering defect rather than merely simultaneous join timing.
- Commit `dc9dff4` changed full snapshots to reliable as an experiment. Local validation passed, but VPS evidence showed it was insufficient and that reliable snapshots congested or delayed reliable `MultiplayerSpawner` traffic, so that experiment was reverted.
- Commit `790c13a` introduced per-`StateSynchronizer` peer replica-ready ACK/visibility gating. Commit `c30bf6e` restored full snapshots to `unreliable_ordered` while preserving that handshake.

Current verified outcome after `c30bf6e`:

- Local 4-player/20-mob behavior: 4/4 clients functionally PASS, exact 20 mobs throughout, and zero active `StateSynchronizer` RPC/path/invalid-packet errors. The only known remaining evidence gate was `npc_stride_counts`.
- VPS 4-player/20-mob attempts with the default 20 s gameplay readiness window could still be too short: runs variably saw 0 mobs or only some clients ready, but had zero client-side `StateSynchronizer` path errors after `c30bf6e`.
- One discriminating VPS run with gameplay readiness increased to 60 s got all four clients ready and exact population, confirming spawns eventually materialize. During profiling, one client lost its multiplayer peer entirely (`multiplayer_peer_exists=false`, peer id reset to 0, no replacement player, empty Players), and the runner aborted. CPU avg 55.1%, peak 65.1%, and RSS 107656 KiB came from only 9 sample rows and are invalid/incomplete; do **not** include them as capacity results. Artifact `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-4p-5wq1t9p0`.

Current VPS matrix status: the original active `StateSynchronizer` spawn-before-state path defect is fixed based on local and VPS evidence. The comparable 4-player matrix remains blocked by a distinct WAN peer-disconnect/startup-latency issue. Teardown may still emit `RollbackSynchronizer` RPC path errors after peers disconnect; do not conflate that teardown defect with the fixed active `StateSynchronizer` defect. Next investigation: determine why Noray/ENet peers drop under 4 players plus 20 mobs and measure transport/bandwidth; do not present optimization as an established cause.

## Player Scaling Benchmark

Existing measured data provides a clean local connected 1/2/4-player no-mob matrix with three repeats per count, 5 s warmup, 65 s requested samples, exit 0, all gates passing, and zero `active_sample_errors`. The first production VPS evidence adds one valid long 1-player/20-mob run and one short 2-player smoke. Follow-up `c30bf6e` evidence fixes the active 4-player `StateSynchronizer` spawn-before-state path defect, but the comparable VPS matrix remains blocked by a distinct WAN peer-disconnect/startup-latency issue and still does **not** provide production capacity. Local macOS CPU/RSS noise is visible, so conclusions should prefer medians and scaling shape over individual percentages.

Existing local observations from `BENCHMARK_SERVER.md`:

| Players | CPU avg values / median | CPU peak values / median | RSS values / median | Rollback entities | Sync entities | Network traffic | Notes |
| ---: | --- | --- | --- | ---: | ---: | --- | --- |
| 0 | 1.02% single historical | 1.50% single historical | latest 83,952 KiB; max 119,344 KiB | 0 | 0 | not measured | Scenario A, raw headless, no mobs; not directly comparable to connected rows |
| 1 | 5.34, 7.61, 7.33% / 7.33% | 5.86, 9.55, 8.63% / 8.63% | 147,392; 121,872; 122,752 KiB / 122,752 KiB | 1 observable rollback node | 1 synchronized player entity | not measured | Local connected no-mob repeats; exits 0; gates pass; active errors 0 |
| 2 | 6.80, 9.21, 9.12% / 9.12% | 7.75, 10.62, 10.60% / 10.60% | 122,176; 98,608; 120,976 KiB / 120,976 KiB | 2 observable rollback nodes | 2 synchronized player entities | not measured | Local connected no-mob repeats; exits 0; gates pass; active errors 0 |
| 4 | 11.78, 13.32, 13.23% / 13.23% | 12.63, 14.52, 14.46% / 14.46% | 100,320; 124,736; 101,072 KiB / 101,072 KiB | 4 observable rollback nodes | 4 synchronized player entities | not measured | Local connected no-mob repeats; exits 0; gates pass; active errors 0 |
| 8 | not measured cleanly | not measured cleanly | not measured cleanly | not measured | not measured | not measured | Current room rules likely cap play at 6 total players (`max_players_per_team=3` across RED/BLUE) unless capacity is changed separately |

Do not compare A and D/connected rows as pure player deltas without caveats: A bypasses Noray/backend/client-probe; connected rows use the profile harness. Treat the 1/2/4 local matrix as evidence that CPU and rollback/state breadth increase with players, not as VPS capacity. Treat the single valid long VPS 1-player run as one production observation, not capacity. Treat an eight-player failure under current rules as a capacity/rules finding, not automatically as a benchmark harness failure.

The profile harness now separates `active_sample_errors` from teardown-only server errors. Active sample errors block benchmark validity. Teardown-only errors are reported but nonblocking when they occur after fixed workload completion: 1-player repeats had `[0, 0, 0]`, 2-player repeats `[0, 2, 2]`, and 4-player repeats `[12, 6, 12]`. These do not invalidate the active samples above, but they remain a real disconnect cleanup defect/follow-up.

## Rollback Measurements

Current instrumentation in `common/perf_probe.gd` already connects to `NetworkRollback` signals:

- `before_loop`
- `after_process_tick`
- `after_loop`

It reports every 5 seconds:

- `rollback_events`
- `rollback_avg_ticks`
- `rollback_max_ticks`
- observable rollback nodes
- Netfox custom monitors when available, including rollback loop/tick/node metrics

Existing 1-player/no-mob scenario D reportedly showed one observable rollback node and 125-151 rollback events per interval. The local connected 1/2/4-player no-mob repeats observed rollback/sync nodes scaling with player count: 1, 2, and 4 respectively. PERF/rollback medians across active PERF rows from repeat 1 were:

| Players | Rollback events median | Rollback avg ticks median | Rollback nodes observable | Snapshot nodes | Full state props | Sent state props |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 149.5 | 2.00 | 1 | 1 | 23 | 5 |
| 2 | 150 | 2.23 | 2 | 2 | 92 | 46 |
| 4 | 150 | 2.36 | 4 | 4 | 348 | 115 |

This indicates rollback/resimulation is real even without mobs. The broad serialized state counts grow sharply across the three local player counts and support prioritizing player rollback/state breadth. Do not infer an exact complexity curve from only three points, and do not treat these artifacts as a long-sample VPS 0/1/2/4/8 capacity comparison.

## Benchmark / Profiling Harness

Existing harnesses:

- `tools/run_server_benchmark.sh` runs an explicit `--benchmark=<scenario>` server child, samples CPU/RSS externally for at least 60 seconds, and reports average/max CPU plus RSS.
- `tests/manual/profile_room_scaling.py` owns Noray/backend/client-probe startup for connected scenarios. It supports `--benchmark`, warmup/sample windows, `--keep-artifacts`, and sets `NOIKAR_PERF_PROBE=1`, `NOIKAR_PERF_PROBE_NPC_COST=1`, `NOIKAR_NPC_SNAPSHOT_HZ`, and `NOIKAR_SERVER_MAX_FPS=60` for profiling runs.
- A/B/C are direct headless-only scenarios. D/E/F require the connected Noray/client-probe route.

Highest-value next instrumentation points before optimization:

1. `common/perf_probe.gd`
   - visibility-filter evaluation counts
   - active projectile counts and projectile tick cost
   - rollback/synchronized node counts by entity type
2. `core/AIComponent.gd`
   - split AI inclusive cost into target search, ally avoidance, passive sleep/stagger, and threat refresh
   - count active moving NPCs vs sleeping/staggered NPCs
3. `core/LogicComponent.gd`
   - keep movement slide/flush timing
   - add idle-vs-moving NPC counts
4. `common/net/NpcStateSynchronizer.gd`
   - submitted snapshots
   - skipped stride ticks
   - non-motion event sends
   - pending-ack resends
5. `common/interest_manager.gd`
   - peer visibility checks
   - visible vs filtered-out mob/peer pairs
6. `common/ProjectileEntity.gd`
   - active projectile ticks
   - collisions
   - despawns/lifetime expiry
7. `common/match_manager.gd`
   - spawned mobs/pets/projectiles
   - lobby snapshot RPC fanout

## Test-Controlled Latency

No project-local latency/loss harness was found that safely applies 0/30/60/100/150 ms and 0/1/3% packet loss without external tools.

Recommended external approaches:

- Linux VPS / Linux local: use `tc netem` on loopback or the relevant test interface. This requires root/admin privileges and must be documented per host.
- macOS: use a packet filter / network link conditioner style setup, or run clients/server in Linux containers/VMs and use `tc netem` inside that isolated environment.

Avoid adding artificial latency hacks inside gameplay code; it risks measuring the hack rather than Netfox/Godot behavior.

## Potential CPU Hotspots

Ranked by current evidence, not by assumption:

1. **Player rollback/resimulation path**
   - `scenes/BaseEntity.tscn` puts every human player in rollback with 16 state properties and 7 input properties.
   - `core/LogicComponent.gd` and `core/CombatComponent.gd` both resimulate on rollback.
   - Existing D measurement has one rollback node and many rollback events per interval.

2. **Authoritative NPC movement/physics**
   - `LogicComponent._simulate_tick()` calls AI and `_apply_npc_movement()` for non-human server entities.
   - `_apply_npc_movement()` still calls `move_and_slide()` and often `force_update_transform()` even for idle NPCs.
   - This is not rollback, but it scales with NPC count and active tick frequency.

3. **NPC AI target search and ally avoidance**
   - `AIComponent._find_nearest_target()` scans hostile groups at about 5 Hz per active AI.
   - `_steer_around_nearby_allies()` scans all allies in the same group when moving, which can become O(n²)-like for clustered mobs/pets.
   - Existing NPC-cost telemetry counts target-scan and avoidance visits.

4. **NPC snapshot/state submission and visibility filtering**
   - Mobs/pets snapshot `global_position`, `quaternion`, combat attack count, and several `ServerState` fields.
   - `common/interest_manager.gd` evaluates peer visibility per tick loop with a 90 m radius.
   - Existing nine-run local comparison suggests lower CPU at 15/10 Hz NPC snapshots.

5. **Projectile tick/collision work when combat creates many projectiles**
   - `common/ProjectileEntity.gd` connects server projectiles to `NetworkTime.on_tick`.
   - Each active projectile performs velocity assignment, `move_and_collide()`, and lifetime checks at 30 Hz.
   - This is not visible in the current no-mob player matrix, but can scale with attack rate and projectile count.

6. **Possible duplicated state registration**
   - Scene files define some `StateSynchronizer.properties`, then `ServerState.gd` adds properties dynamically. Verify whether Netfox de-duplicates these paths.

7. **Headless presentation leftovers**
   - `BaseEntity._strip_server_presentation()` strips entity-level visual nodes.
   - `MatchManager._strip_headless_presentation()` should strip scene-level presentation. Any missed visual/UI node on the dedicated server would be pure waste.

## Unnecessary Rollback Candidates

Confirmed candidates:

- **TrainingDummy**: if spawned in production or load tests, it has rollback even with prediction disabled. If it is test-only, ignore for production.

Not confirmed candidates:

- **Mobs/enemies**: already out of rollback.
- **Pets**: already out of rollback.
- **Projectiles**: already out of rollback.
- **Souls/totems**: no rollback found.

Player rollback should not be removed globally. The question is whether all current player combat/cooldown/charge fields truly need to be rollback state on every peer.

## Unnecessary State Properties

Likely review candidates:

- Player rollback `:quaternion`: local mouse look is render-frame-applied in `LogicComponent._process()`, and owned-player `TickInterpolator` removes quaternion interpolation. Server-authoritative combat still may need yaw/aim, so this needs a targeted test before removal.
- Player rollback combat internals:
  - `_state_timer`
  - `_primary_cooldown`
  - `_secondary_cooldown`
  - `_active_damage_multiplier`
  - `_active_r_stun_token`
  - `_active_attack_slot`
  These may be necessary for deterministic resimulation, but they are high-value audit targets.
- Player `StateSynchronizer` knockback fields are still synchronized even though knockback movement logic in `LogicComponent._apply_movement()` is commented out.
- NPC `quaternion`: if mobs can derive facing from velocity/target and only need cosmetic orientation, snapshotting full rotation may be avoidable later.
- NPC `stun_remaining_time` / ability fields: common `ServerState` adds these to NPCs too; verify whether every NPC/pet actually needs all ability R and stun timing fields.
- Duplicated static + dynamic state registration for health/death/name/character/knockback should be verified.

## Recommended Architecture

For this project specifically:

### Server authoritative

Keep the server authoritative for:

- player position validation
- movement correction
- damage/hit validation
- cooldowns and skill outcomes
- stun/death/respawn
- mob AI/movement/combat
- match state and progression

### Local player

Keep prediction/rollback only for responsive player movement and the minimum combat inputs/state needed to reconcile visible local actions.

Next audit step: split player rollback properties into:

1. required for movement correction
2. required for attack responsiveness
3. server-only authoritative outcome state
4. visual-only state

### Remote players

Prefer snapshot/interpolation for remote presentation. The current base player scene gives every player a `RollbackSynchronizer`; verify whether non-owned player instances on clients are paying rollback participation beyond what Netfox requires for reconciliation. If remote players are only receiving authoritative state, they should not need prediction-like work.

### Mobs / pets

The current architecture already matches the target direction:

- server simulates AI/movement/combat
- clients receive snapshots
- clients interpolate presentation
- no mob rollback/prediction found

Main optimization path is not “remove mob rollback”; it is reducing NPC simulation/snapshot cost while preserving authority.

### IA decoupled from network tick

Current AI runs from the authoritative simulation tick but internally throttles target search and passive mobs. A later refactor could formalize:

- AI decisions: 5-10 Hz
- path/target searches: 2-10 Hz based on state
- movement/physics: still server simulation tick for active actors
- snapshots: 10-20 Hz for NPCs

## Optimization Plan

### HIGH IMPACT / LOW RISK

- Verify and remove duplicated `StateSynchronizer` properties if Netfox does not de-duplicate them.
- Keep using `NOIKAR_NPC_SNAPSHOT_HZ=15` or `10` in controlled tests; existing local data suggests measurable CPU reduction for 20 NPCs.
- Use the completed local no-mob 1/2/4 matrix to guide player rollback/state audit, but do not resume VPS capacity decisions until the distinct WAN peer-disconnect/startup-latency issue is understood and comparable 4-client/20-mob runs complete with valid sample windows.

### HIGH IMPACT / MEDIUM RISK

- Reduce player rollback state to the minimum proven set. Start with properties that look visual/derived or duplicated.
- Audit whether remote player instances need the same rollback/prediction setup as owned local players.
- Decouple NPC decision cadence more explicitly from the 30 Hz simulation tick.

### MEDIUM IMPACT / LOW RISK

- Lower or adaptive-throttle AI target search for passive/far mobs.
- Optimize ally avoidance scans; avoid full group scans per moving mob when waves grow.
- Skip `force_update_transform()` for idle NPCs when no state changed, if Netfox/Godot synchronization remains correct.

### MEDIUM IMPACT / MEDIUM RISK

- Snapshot fewer NPC rotation fields if facing can be reconstructed visually.
- Split NPC state schemas by entity type so mobs do not synchronize player-only ability/cooldown fields.

### DO NOT DO YET

- Do not remove player rollback globally.
- Do not assume Netfox is the primary problem.
- Do not rewrite mobs; current code already keeps them out of rollback.
- Do not rely on local CPU percentages, a single valid 1-player VPS run, or a short 2-player smoke for VPS capacity planning.

## Answer: top 3 likely reasons for excess CPU

1. **Every connected human player is a full rollback participant with a large rollback state set.**
   - Evidence: `scenes/BaseEntity.tscn` `RollbackSynchronizer` has prediction enabled and records full transform, velocity, dash state, combat attack state, timers, charge/projectile fields, cooldowns, and 7 input fields.
   - Scripts: `core/LogicComponent.gd`, `core/CombatComponent.gd` both implement `_rollback_tick()`.

2. **NPC cost is mostly authoritative simulation/physics/AI, not rollback.**
   - Evidence: `scenes/EnemyEntity.tscn` has no `RollbackSynchronizer`; scenario F documented `npc_rollback_synchronizers=0` for 20 NPCs.
   - CPU-relevant code: `core/LogicComponent.gd` runs NPC movement and `move_and_slide()`; `core/AIComponent.gd` runs target search and ally avoidance; `core/CombatComponent.gd` runs combat state.

3. **NPC snapshots/state are still fairly rich and cadence-sensitive.**
   - Evidence: `ServerState.gd` adds NPC transform, rotation, attack count, health/death/team/events/stun/ability fields; `NpcStateSynchronizer.gd` submits authoritative snapshots by stride.
   - Existing benchmark artifact: `tests/manual/results/npc_snapshot_comparison.json` shows median local CPU decreasing from 11.96% at 30 Hz NPC snapshots to 11.30% at 15 Hz and 10.84% at 10 Hz in the 1-player/20-NPC workload.
