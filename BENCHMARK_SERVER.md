# Server Benchmark Harness

This harness measures server behavior only. It does not optimize, tune, or change normal gameplay behavior when no `--benchmark=` user argument is supplied.


## First production VPS evidence

Deployment commit `50395c0` completed successfully through Deploy World Runtime run `34666205456`, and the VPS current symlink pointed to that commit for these runs. Host shape: 2 vCPU, 8,136,536 KiB RAM. Production rooms use 20 mobs; these measurements deliberately did not mutate global Noray or service configuration to force zero mobs.

CPU/RSS were sampled remotely from `/proc` utime+stime and resident pages over one persistent SSH connection. These rows are production evidence, but not a capacity matrix yet. Preserve the local macOS evidence below separately.

| Players | Window | Mobs | Result | CPU avg | CPU interval peak | RSS max | Artifact | Interpretation |
| ---: | --- | ---: | --- | ---: | ---: | ---: | --- | --- |
| 1 | 5 s warmup, 65 s sample | 20 | client PASS; zero active client errors; 65 sample rows | 26.73% | 49.08% | 103,768 KiB | `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-1p-xyzc_tyd` | Valid long single run. Treat as one run, not capacity. |
| 2 | 2 s warmup, 10 s sample | 20 | both clients PASS; zero active errors | 36.50% | 41.61% | 104,680 KiB | `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-2p-a98ovbt2` | Valid short smoke after peer guards. Do not compare as a long result. |

Invalid attempts and current blocker:

- A long 2-player attempt is invalid because the player node was freed during workload. The harness now fails cleanly instead of dereferencing a freed instance.
- 4-player production attempts are invalid because dynamic Player and Mob `StateSynchronizer` paths were missing before nodes materialized, producing hundreds of `Node not found`, `Failed to get path from RPC`, and `Invalid packet` errors. A discriminating repeat with sequential admission and a 10 s lobby hold still failed: all four clients were admitted but none passed; RPC missing counts were client0=289, client1=23, client2=223, client3=331, and fixed population observed was 0. Artifact `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T/noikar-vps-4p-impg1qcq`. This persistence despite admission/settle timing supports a product Netfox spawn/state ordering defect, not merely simultaneous join timing. The remote room server cleaned up after clients exited.

Peer lifecycle fixes committed in `50395c0`: `AbilityHud` and `NpcTickInterpolator` no-peer guards, plus clean probe failure on a freed player. Do **not** claim the spawn ordering bug is fixed.

Current conclusion: the VPS matrix is blocked on correctness. Do not report 2-player or 4-player long capacity and do not extrapolate. Next recommendation: fix or gate `StateSynchronizer` delivery until dynamic `MultiplayerSpawner` nodes exist and are ready; validate 4 clients with 20 mobs and zero active RPC path errors; then resume repeated 1/2/4 VPS measurements.

## Current authoritative nine-run NPC snapshot comparison

These are measured local macOS results for Godot 4.7, one connected client, 20 NPCs, 10 s warmup, and 65 s requested samples. They are preserved as local evidence and are separate from the production VPS rows above. Runs alternated rate order across replicate groups: R1 30/15/10, R2 10/15/30, R3 15/30/10. The sanitized numeric report is `tests/manual/results/npc_snapshot_comparison.json`; it includes SHA256 provenance for each private capture plus current source-content digests for `tests/manual/profile_room_scaling.py` and `common/perf_probe.gd`.

| Rate Hz | CPU avg values | CPU avg median / min / max | CPU interval peak median / min / max | RSS median / min / max KiB | Median duration s | Relative CPU reduction from median |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 30 | 12.22, 11.96, 11.85 | 11.96 / 11.85 / 12.22 | 13.48 / 13.47 / 13.53 | 127,920 / 102,400 / 131,408 | 65.55 | baseline |
| 15 | 11.43, 11.24, 11.30 | 11.30 / 11.24 / 11.43 | 12.54 / 12.46 / 12.56 | 122,480 / 121,488 / 123,792 | 65.59 | 5.52% vs 30 Hz |
| 10 | 10.85, 10.84, 10.70 | 10.84 / 10.70 / 10.85 | 12.44 / 11.59 / 12.44 | 126,656 / 123,280 / 126,768 | 65.62 | 9.36% vs 30 Hz; 4.07% vs 15 Hz |

| Order | Replicate | Rate Hz | CPU avg % | Interval peak % | Resolution s | RSS KiB | Duration s | Stride proof | Gates/errors | Workload details when captured |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |
| 1 | R1 | 30 | 12.22 | 13.47 | 1.03 | 131,408 | 65.55 | stride 1, 20/20 authoritative, missing 0, unknown 0 | all gates true; errors 0 | not captured in this schema |
| 2 | R1 | 15 | 11.43 | 12.56 | 1.03 | 123,792 | 65.61 | stride 2, 20/20 authoritative, missing 0, unknown 0 | all gates true; errors 0 | not captured in this schema |
| 3 | R1 | 10 | 10.85 | 12.44 | 1.03 | 126,656 | 65.62 | stride 3, 20/20 authoritative, missing 0, unknown 0 | all gates true; errors 0 | not captured in this schema |
| 4 | R2 | 10 | 10.84 | 12.44 | 1.03 | 126,768 | 65.62 | stride 3, 20/20 authoritative, missing 0, unknown 0 | all gates true; errors 0 | not captured in this schema |
| 5 | R2 | 15 | 11.24 | 12.54 | 1.03 | 122,480 | 65.48 | stride 2, 20/20 authoritative, missing 0, unknown 0 | all gates true; errors 0 | not captured in this schema |
| 6 | R2 | 30 | 11.96 | 13.48 | 1.03 | 102,400 | 65.56 | stride 1, 20/20 authoritative, missing 0, unknown 0 | all gates true; errors 0 | not captured in this schema |
| 7 | R3 | 15 | 11.30 | 12.46 | 1.03 | 121,488 | 65.59 | stride 2, 20/20 authoritative | all gates true; errors 0 | nearest NPC min/mean/max 28.55/41.83/49.56 m; observed NPCs within 90 m 10; client travel 83.67 m movement, 717.11 m sampled path |
| 8 | R3 | 30 | 11.85 | 13.53 | 1.03 | 127,920 | 65.42 | stride 1, 20/20 authoritative | all gates true; errors 0 | nearest NPC min/mean/max 29.54/40.32/52.22 m; observed NPCs within 90 m 10; client travel 51.00 m movement, 635.97 m sampled path |
| 9 | R3 | 10 | 10.70 | 11.59 | 1.03 | 123,280 | 65.59 | stride 3, 20/20 authoritative | all gates true; errors 0 | nearest NPC min/mean/max 29.80/40.79/50.83 m; observed NPCs within 90 m 10; client travel 40.73 m movement, 643.64 m sampled path |

Measured result only: this records lower median CPU at 15 Hz and 10 Hz in these nine local runs, with authoritative stride proof passing in every run. It is not an optimization claim and does not change production NPC snapshot rates or player rollback behavior.

### Current-result limitations

- CPU interval peaks come from the Python profile harness interval estimator. Earlier A-C rows used a shell `%CPU` estimator, so compare those peak columns only with that estimator difference stated.
- A-C bypassed Noray, so D-A is not a player-only cost.
- Earlier B retained NPC components, physics, and sync; it was not a pure physics-only measurement.
- All stride proof above is authoritative for these captures. Client-side unseen NPCs can stay at their default due to 90 m interest; only 10 NPCs were observed by the client in R3 workload fields.
- Closest workload distances around 28-31 m do not prove melee-heavy combat. Route differences, client load, and local OS conditions prevent VPS conclusions.
- FPS and automated gates are not visual jitter validation.
- Excluded pre-authoritative runs are not included in this summary.

## Historical exploratory single-run scenarios (A-F)

| Scenario | Players | Mobs | AI decisions | Rollback note | CPU avg | CPU peak | RAM / RSS | Result |
| --- | ---: | ---: | --- | --- | ---: | ---: | --- | --- |
| A | 0 | 0 | normal | no player rollback participant | 1.02% | 1.50% | latest 83,952 KiB; max 119,344 KiB | passed, 60 s local sample |
| B | 0 | 20 | off | no player rollback participant | 8.00% | 9.90% | latest 114,656 KiB; max 154,224 KiB | passed, 60 s local sample |
| C | 0 | 20 | normal | no player rollback participant | 9.42% | 9.70% | latest 98,848 KiB; max 154,400 KiB | passed, 60 s local sample |
| D | 1 | 0 | normal | player rollback unchanged | 7.51% | not reported by harness | 92,592 KiB reported | passed, 65.92 s stable local sample |
| E | 1 | 20 | normal | player rollback unchanged | 11.76% | not reported by harness | 131,168 KiB reported | passed, 65.54 s stable local sample |
| F | 1 | 20 | normal | player rollback unchanged; NPC rollback synchronizers=0, snapshot-sync observable=20 | 11.89% | not reported by harness | 131,840 KiB reported | passed, 65.63 s stable local sample |

The historical A-F measurements above are real **local macOS** exploratory single-run observations, not VPS measurements. A-C use the owned-child shell `ps` sampler; D-F use the Python profile harness, which now reports average CPU plus an interval peak derived from adjacent sampled CPU-time deltas. Treat that interval peak as sample-resolution-limited telemetry, not the same estimator as the shell wrapper's `%CPU` maximum. Re-run the same matrix on the 2-vCPU VPS before treating these values as production capacity data.

## Historical A-F observed comparison

The A-F rows are historical exploratory single runs. They are useful context, not an optimization claim and not a production-capacity conclusion.

- A established a 1.02% average local process baseline with zero mobs.
- B added 20 spawned mobs with AI decisions disabled: 8.00% average CPU.
- C enabled normal AI for the same population: 9.42% average CPU. This is a 1.42 percentage-point increase in this single local run, not a statistically conclusive attribution.
- D added one authenticated player with zero mobs: 7.51% average CPU. Its telemetry showed one observable rollback node and 125-151 rollback events per interval.
- E, the representative 1-player/20-mob scenario, averaged 11.76% CPU. Its 20-NPC interval reported 3,020 AI calls (16,636 µs total), 3,020 movement calls (27,340 µs), and 3,020 combat calls (5,313 µs).
- F averaged 11.89% CPU, within 0.13 percentage points of E. It confirmed `npc_rollback_synchronizers=0`, `npc_snapshot_sync_observable=20`, and `synchronized_entities_observable=21`. Therefore E/F do not test a newly-disabled mob rollback path: mobs were already authoritative snapshot participants. More repeated VPS samples are required before inferring a CPU difference.

## Godot usage

Pass the benchmark selector as a Godot user argument:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --benchmark=A
```

Valid selectors are `A`, `B`, `C`, `D`, `E`, and `F`. Invalid selections are logged as `[BENCHMARK] invalid --benchmark selection; expected one of A,B,C,D,E,F` and do not activate the benchmark mode.

The benchmark mode reuses the existing fixed-population/profile path and `PerfProbe`. Every five seconds, headless runs emit `[BENCHMARK]` lines with reliable in-process fields only: scenario, uptime, configured/live player and mob counts, FPS/frames when available, frame/physics monitor values, tick settings, observable rollback/snapshot/synchronized entity counts, and observable Netfox custom monitors. CPU and RSS are external process metrics and are labelled `cpu=external rss=external` in Godot logs.

For raw local headless runs, only `A`, `B`, and `C` bypass Noray/backend provisioning: `GameManager` opens the default local ENet port directly, then `MatchManager` defers fixed-population spawning until the server-start signal. `A` emits the ready marker with `0` mobs; `B` and `C` emit it with `20` mobs. `D`, `E`, `F`, invalid selectors, and ordinary headless runs stay on the existing provisioned Noray/client-probe path.

## Connected-player scenarios

A raw headless server process cannot invent an authenticated player. Scenarios `D`, `E`, and `F` must use the existing Noray/client-probe flow so a real authenticated client joins the room. Use the existing profile harness for connected cases with `--benchmark D|E|F`; the harness validates the selection, sets the expected fixed mob population, and the Noray spawner forwards the real Godot user argument `-- --benchmark=<scenario>` to the spawned server.

## Local commands

Unconnected scenarios:

```bash
cd noikarv3
NOIKAR_BACKEND_URL=http://127.0.0.1:18090 tools/run_server_benchmark.sh A -- /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --benchmark=A
NOIKAR_BACKEND_URL=http://127.0.0.1:18090 tools/run_server_benchmark.sh B -- /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --benchmark=B
NOIKAR_BACKEND_URL=http://127.0.0.1:18090 tools/run_server_benchmark.sh C -- /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --benchmark=C
```

Connected scenarios use the existing Noray/client-probe/profile-room flow. Keep secrets in the environment or local secret store, not in benchmark docs or command transcripts:

```bash
cd noikarv3
python3 tests/manual/profile_room_scaling.py --benchmark D --warmup-seconds 5 --sample-seconds 65
python3 tests/manual/profile_room_scaling.py --benchmark E --warmup-seconds 5 --sample-seconds 65
python3 tests/manual/profile_room_scaling.py --benchmark F --warmup-seconds 5 --sample-seconds 65
```

Connected no-mob player-scaling uses one hosted room, fixed population `mob_count=0`, `NOIKAR_PERF_PROBE=1`, warmup/sample windows, and the external Python process sampler. The harness starts one host client, reads its admitted room OID, then starts joiner clients into that same OID:

```bash
cd noikarv3
python3 tests/manual/profile_room_scaling.py --player-count 1 --warmup-seconds 5 --sample-seconds 65
python3 tests/manual/profile_room_scaling.py --player-count 2 --warmup-seconds 5 --sample-seconds 65
python3 tests/manual/profile_room_scaling.py --player-count 4 --warmup-seconds 5 --sample-seconds 65
python3 tests/manual/profile_room_scaling.py --player-count 8 --warmup-seconds 5 --sample-seconds 65
```

The `--player-count 8` command is wired into the harness for reproducibility, but the current gameplay rules expose `max_players_per_team=3` (six players total across RED/BLUE). Treat any eight-player failure as a capacity/rules finding unless the room rules are changed separately.

### Local no-mob player-scaling runs

These are local macOS connected no-mob runs with three repeats per player count, 5 s warmup, and 65 s requested sample windows. Every 1/2/4-player run exited 0, passed all gates, and reported zero `active_sample_errors`. CPU/RSS still show local-machine noise, so the median is the safest local summary. These runs are not VPS capacity data; re-run the same matrix on the 2-vCPU VPS before capacity decisions.

| Players | Repeats | CPU avg values % | CPU avg median % | Interval peak values % | Interval peak median % | RSS values KiB | RSS median KiB | Rollback/sync nodes observable | Result |
| ---: | --- | --- | ---: | --- | ---: | --- | ---: | ---: | --- |
| 1 | 3 | 5.34, 7.61, 7.33 | 7.33 | 5.86, 9.55, 8.63 | 8.63 | 147,392; 121,872; 122,752 | 122,752 | 1 | exits 0; gates pass; active errors 0 |
| 2 | 3 | 6.80, 9.21, 9.12 | 9.12 | 7.75, 10.62, 10.60 | 10.60 | 122,176; 98,608; 120,976 | 120,976 | 2 | exits 0; gates pass; active errors 0 |
| 4 | 3 | 11.78, 13.32, 13.23 | 13.23 | 12.63, 14.52, 14.46 | 14.46 | 100,320; 124,736; 101,072 | 101,072 | 4 | exits 0; gates pass; active errors 0 |
| 8 | not run to a clean gameplay sample | not measured | not measured | not measured | not measured | not measured | not measured | not measured | Current room rules likely cap gameplay at six total players (`max_players_per_team=3` across RED/BLUE) unless capacity is changed separately |

PERF/rollback medians below are from active PERF rows in repeat 1. They show rollback and broad serialized state growing with active player count, but three player-count points are not enough to infer an exact complexity curve.

| Players | Rollback events median | Rollback avg ticks median | Rollback nodes observable | Snapshot nodes | Full state props | Sent state props |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 149.5 | 2.00 | 1 | 1 | 23 | 5 |
| 2 | 150 | 2.23 | 2 | 2 | 92 | 46 |
| 4 | 150 | 2.36 | 4 | 4 | 348 | 115 |

The broad serialized state counts grow sharply across 1/2/4 players and support prioritizing player rollback/state breadth for audit. Do not read these local results as proof of production VPS capacity or as evidence that an optimization has been implemented.

The profile harness now separates `active_sample_errors` from teardown-only server errors. Active sample errors are blocking for benchmark validity; teardown errors are reported but nonblocking when they occur only after the fixed workload completes. Teardown-only server error counts for the three repeats were: 1 player `[0, 0, 0]`, 2 players `[0, 2, 2]`, and 4 players `[12, 6, 12]`. They do not invalidate the active samples above, but they remain a real disconnect-cleanup defect and follow-up.

Artifacts were retained under `/var/folders/kq/sw184q4x2vz7vp4dcxhk4hg40000gn/T`: repeat 1 `noikar-profile-tlu28lm8`, `noikar-profile-xrdqtttd`, `noikar-profile-wop10v2h`; repeat 2 `noikar-profile-nre0qtja`, `noikar-profile-xdh1deqi`, `noikar-profile-_8jo66y0`; repeat 3 `noikar-profile-qkz9o71h`, `noikar-profile-ye7c01ob`, `noikar-profile-tpjjw_2x`.

## VPS commands

Use the exported server binary and the same wrapper. Pass only non-secret flags in shell history; provide credentials through the existing deployment environment.

```bash
cd /path/to/noikarv3
NOIKAR_BENCHMARK_SAMPLE_SECONDS=65 tools/run_server_benchmark.sh A -- ./noikar-server.x86_64 --headless -- --benchmark=A
```

For `D`, `E`, and `F`, use `python3 tests/manual/profile_room_scaling.py --benchmark D|E|F --warmup-seconds 5 --sample-seconds 65`. The profile harness owns Noray/backend/client-probe startup and passes `NOIKAR_BENCHMARK_SCENARIO` to Noray; `noikar-noray/src/hosts/host.spawner.mjs` converts that validated environment value into the spawned Godot server user argument `-- --benchmark=<scenario>`.

## Linux process sampler

`tools/run_server_benchmark.sh` requires:

```bash
tools/run_server_benchmark.sh <A|B|C|D|E|F> -- <explicit server command including --benchmark=<scenario>>
```

It samples the owned child process for at least 60 seconds, printing:

- UTC timestamp
- PID
- `%CPU`
- RSS KiB
- elapsed process time

At the end it reports average/max CPU and latest/max RSS. It sends `TERM` only to the server child it started.

## Methodology

1. Pick one scenario and record the exact server command.
2. For `A`/`B`/`C`, run the headless server directly.
3. For `D`/`E`/`F`, run `tests/manual/profile_room_scaling.py --benchmark D|E|F --warmup-seconds <seconds> --sample-seconds <seconds>` so the authenticated client-probe route is used and the spawned server receives `-- --benchmark=<scenario>`.
4. Collect at least 60 seconds of process samples from `tools/run_server_benchmark.sh`.
5. Keep raw `[BENCHMARK]` logs with the process-sampler CSV output.
6. Do not compare CPU/RSS from Godot logs; use the external sampler for those fields.

## Headless findings to verify per run

- Presentation nodes are stripped by the existing headless path.
- Fixed-population mobs spawn through the existing profile population facility.
- Scenario `B` disables only NPC AI decisions: target search, steering/path logic, and attacks. Spawned NPCs, authoritative simulation, transform replication, and physics remain active. No `NavigationAgent3D` is introduced.
- Scenario `F` is truthful about rollback: player rollback remains unchanged; NPCs are counted as rollback participants only if a `RollbackSynchronizer` is observable. When mobs lack `RollbackSynchronizer` and expose snapshot state, report them as snapshot-sync rather than rollback participants.

## Limitations

- The local recorded samples are macOS results. They are useful for relative comparison but do not represent the 2-vCPU VPS. The first VPS rows above are production evidence, but the VPS matrix is currently blocked by the 4-player spawn/state ordering correctness defect.
- CPU/RSS are unavailable inside Godot logs and must come from the owned-child Linux sampler, the existing profile harness, or another external process sampler. The Python harness CPU interval peak is derived from sampled process CPU-time deltas and is labelled with its interval/sample resolution; do not compare it directly to the shell wrapper's instantaneous `%CPU` maximum without noting the estimator difference.
- In-process entity counts are observable counts, not proof of network delivery to every client.
- Netfox custom monitor fields appear only when the monitor exists at runtime.
- Connected scenarios depend on backend/Noray/client-probe availability and authentication state.
- `--keep-artifacts` retains raw backend, Noray, server, and client logs for audit and comparison. Treat retained logs as potentially sensitive operational artifacts even though the harness redacts known generated credentials in summaries.

## Potential CPU Hotspots

These are measurement targets, not optimization recommendations:

- **Simulation clock:** `project.godot` configures Netfox and physics at 30 Hz. NPC AI and movement are driven from the authoritative `NetworkTime` simulation tick, rather than a separately discovered per-mob `_process` or `_physics_process` loop.
- **AI decisions:** `core/AIComponent.gd` runs target acquisition at its configured 0.2-second interval, plus patrol/chase/attack decisions and nearby ally avoidance. Scenario `B` isolates this work while retaining NPC physics and replication.
- **NPC physics:** `core/LogicComponent.gd` executes NPC movement and `CharacterBody3D.move_and_slide()` on the authoritative tick. Its movement preparation, slide, and flush spans are available through the NPC cost probe.
- **Combat and spatial queries:** `core/CombatComponent.gd` is measured as `npc_combat` when NPC cost telemetry is enabled. Inspect runtime output for ray/shape-cast work; no `NavigationAgent3D` was found in the inspected mob implementation.
- **Netfox:** players retain their existing rollback/reconciliation path. NPCs have no `RollbackSynchronizer`; they use authoritative snapshot synchronization. Scenario `F` logs observable rollback and snapshot participant counts to confirm this distinction instead of disabling a rollback path that is already absent.
- **Network/state replication:** `common/perf_probe.gd` reports observable Netfox custom monitors and rollback aggregation every five seconds. `common/components/ServerState.gd` controls NPC snapshot cadence through `NOIKAR_NPC_SNAPSHOT_HZ`.
- **Headless scene loading:** `scenes/main.tscn` contains presentation nodes, while the existing headless path removes HUD, connection UI, world environment, sun, entity meshes, camera/presentation components, health UI, and tick interpolation. Treat any presentation node remaining at runtime as a finding; this harness does not change the strip behavior.
- **Population loops:** `common/match_manager.gd` owns fixed-population spawning and benchmark startup observations. Use live entity counts in the logs to distinguish spawn/setup work from steady-state costs.
