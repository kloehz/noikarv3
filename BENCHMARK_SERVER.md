# Server Benchmark Harness

This harness measures server behavior only. It does not optimize, tune, or change normal gameplay behavior when no `--benchmark=` user argument is supplied.

## Scenarios

| Scenario | Players | Mobs | AI decisions | Rollback note | Result |
| --- | ---: | ---: | --- | --- | --- |
| A | 0 | 0 | normal | no player rollback participant | pending |
| B | 0 | 20 | NPC decisions off | no player rollback participant | pending |
| C | 0 | 20 | normal | no player rollback participant | pending |
| D | 1 | 0 | normal | player rollback unchanged | pending |
| E | 1 | 20 | normal | player rollback unchanged | pending |
| F | 1 | 20 | normal | player rollback unchanged; NPCs are validated as excluded from rollback when they have no `RollbackSynchronizer` and are reported as snapshot-sync participants when observable | pending |

No fabricated results are included here. Fill the `Result` column only from recorded local/VPS runs.

## Godot usage

Pass the benchmark selector as a Godot user argument:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --benchmark=A
```

Valid selectors are `A`, `B`, `C`, `D`, `E`, and `F`. Invalid selections are logged as `[BENCHMARK] invalid --benchmark selection; expected one of A,B,C,D,E,F` and do not activate the benchmark mode.

The benchmark mode reuses the existing fixed-population/profile path and `PerfProbe`. Every five seconds, headless runs emit `[BENCHMARK]` lines with reliable in-process fields only: scenario, uptime, configured/live player and mob counts, FPS/frames when available, frame/physics monitor values, tick settings, observable rollback/snapshot/synchronized entity counts, and observable Netfox custom monitors. CPU and RSS are external process metrics and are labelled `cpu=external rss=external` in Godot logs.

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

- No live benchmark results are checked into this file.
- CPU/RSS are unavailable inside Godot logs and must come from the Linux sampler or another external process sampler.
- In-process entity counts are observable counts, not proof of network delivery to every client.
- Netfox custom monitor fields appear only when the monitor exists at runtime.
- Connected scenarios depend on backend/Noray/client-probe availability and authentication state.

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
