# FishNet / Netfox comparison setup

> **Final delivery (2026-10-08): STOP — REAL20 Netfox active metrics unavailable.** Read [the outcome-first summary](docs/benchmarks/COMPARISON_SUMMARY.md) and [source-traceable measurements](docs/benchmarks/measurements.csv). FishNet steady windows are retained; Netfox two-client smoke and failed REAL20 startup diagnostics are separate, not a matched ranking. REAL20 compare60 was held, not executed. Final cleanup removed the isolated VPS runtime; existing VPS binding/commands are **NOT READY**. The sections below preserve earlier setup/history, not current execution authorization; final status is in the summary.

The FishNet measurements are preserved here. Netfox `compare30` / `compare60` are opt-in configuration and measurement profiles of **this existing game**, not equivalent-capacity results. Normal game defaults are unchanged. Do not compare local zero-player smoke CPU to FishNet's 20-owner VPS CPU.

## Local connected validation (2026-10-08)

Final short runs of both profiles passed the strict connected gameplay, population, authoritative NPC-stride and cached-profile gates: two real clients, 20 mobs, five-second warmup and approximately ten-second sampling. Each arm ran once, sequentially. See [the final sanitized report](docs/benchmarks/netfox/final_connected_validation.json).

| Profile | CPU, % of one core | Maximum RSS, KiB | Last actual callback Hz |
|---|---:|---:|---:|
| compare30 | 17.17 | 138736 | 30.00 |
| compare60 | 25.02 | 152144 | 59.98 |

CPU is cumulative server process CPU-time delta divided by measured wall time; 100% means one core. RSS is maximum, not the FishNet baseline's median. Callback intervals are not aligned with CPU sample windows. These short local observations do not establish causal savings, 20-owner VPS capacity, or FishNet equivalence.

Phase-event quality remains open: bounded traces showed duplicate/regressing phase events and reached their 128-row limit. The original COUNTDOWN failure is not proven fixed. No VPS was used; owned local processes, containers and volumes were cleaned up.

## Real20-client local case: capacity observed, performance blocked

The existing authenticated-game supervisor now supports **one room with20 distinct real clients,10v10, and20 live NPCs**. This is an explicit local benchmark-only capability; ordinary authored `MatchRules` remain3/team (six total). No bots, injected players, extra rooms, phase forcing, health cheats or vendor changes are used.

```bash
# Run sequentially, once per profile, never both arms together.
python3 tests/manual/profile_room_scaling.py --rooms 1 --player-count 20 --mob-count 20 \
  --netfox-profile compare30 --warmup-seconds 10 --sample-seconds 60 \
  --deadline-seconds 150 --keep-artifacts
# Same command with --netfox-profile compare60 for the second independent arm.
```

Twenty headless Godot client processes retain the full normal client scene, controllers, prediction, physics, networking and input-intention route; only display rendering is headless. The server remains headless,75 applicationFPS, physics50Hz, native30/60Hz; clients cap60 applicationFPS. Headless is NOT server authority: an explicit validated role prevents server bootstrap/presentation stripping on these clients. MatchDirector duplicates the Inspector-authored rules at runtime, never saves them, and every endpoint emits actual10/team readback. Capacity/profile mismatches fail before access-token validation; the normal backend validation, duplicate-account rejection, room-phase rules and full-team gates remain intact. ENet's ordinary default32 clients already exceeds20; only the load20 server explicitly passes20. See [Godot ENet documentation](https://docs.godotengine.org/en/stable/classes/class_enetmultiplayerpeer.html#class-enetmultiplayerpeer-method-create-server).

The host waits for exactly20 lobby members/Ready states. A supervisor barrier waits for all20 server-confirmed character choices before ordinary selection Ready calls; the existing5-second IN_GAME check starts only then. A second barrier releases input warmup only after all20 authenticated/spawned owner peers, unique accounts, exact10/10 teams, real input authorities/server states, one OID and20 live mobs are observed. All20 must have moved in authoritative samples before the CPU window. Missing owners/movement, wrong capacity, changed populations, unavailable cadence or dead clients fail; counts are never clamped. Earlier phase-event regressions remain unproven/unrepaired and can still fail this cohort.

Sampling is **one60-second aggregate after10-second warmup**, not FishNet's three30-second windows. Server CPU uses cumulative process CPU-time / actual aligned wall window (100% = one core); RSS is maximumKiB, not median. Actual server and client native callback progress is recorded; client clock observation includes warmup plus the existing6-second route margin. Load20 cadence qualification uses an explicit±10% envelope, not exact-Hz or prediction-quality proof. Five-second server callback p95/p99 intervals still include warmup and are not individually aligned with the CPU window.

The supervisor owns and cleans its20 clients, provisioned server, loopback backend/Noray, uniquely named Docker Postgres container/volume and process groups. Use a150-second internal deadline starting before service startup and an external180-second whole-arm watchdog including cleanup. Process-group waiting and owned Docker removal are bounded; cleanup can consume about30 additional seconds. The existing harness refuses occupied TCP control ports; an independent verifier must additionally check/rebind the UDP registrar/relay range before/after each arm. It aborts if free/reclaimable host memory drops below15%, owned process RSS exceeds8GiB, or measured generator CPU exceeds85% of logical-core capacity for three polling intervals. The CPU guard is generator cumulative-processCPU, not total hostCPU; one-minute host load is also retained. Full client cadence failures qualify generator-capacity failure, not a server performance PASS. Raw temporary logs may contain ephemeral credentials; archive only selected sanitized evidence and do not publish raw argv/log tails. No writer load20 run was performed.

### Local FishNet evidence, separate from VPS

[Local baseline](docs/benchmarks/fishnet/local_baseline.json) preserves the2026-10-06 original report's sourceSHA and selected measured facts: one room,20 real owners10/10, native60Hz approximately60.000/59.998/59.998, serverCPU28.61/32.80/28.22% of one core, sampled maximumRSS114.36/83.95/73.25MiB. It used server applicationFPSuncapped(-1), approximately9200 outerframes/s; clients targeted60FPS. Natural living mobs varied2–20 and players5–20 with normal death/respawn. The report-referenced retained coordinator explicitly launches clients with `-batchmode -nographics`; its selected flags/sourceSHA are now archived. This is launch-source evidence, not independently sampled graphics-device telemetry. These pacing/lifecycle/engine/window/backend differences prevent a matched causal ranking against this prepared Netfox case. The separately archived VPS table is not substituted for the local baseline.

Current source/test/preservation evidence: [load20 capability report](docs/benchmarks/netfox/load20_capability.json). Existing smoke, first failure/control, correction and final2-client reports remain historical snapshots unchanged. The first REAL20 compare30 attempt admitted/spawned all20 owners but reached only18 OWNER_READY before the generator guard stopped it. No qualified server CPU/RSS window exists; compare60 was not launched. Preserve [that immutable failure](docs/benchmarks/netfox/load20_connected_validation.json); it is not a server/framework-capacity verdict.

## Opt-in activation diagnostics and three steady windows

Prepared measurement support, **not a completed REAL20 performance result**. The failed report remains unchanged. No pacing, simulation, UI phase, authority, security, vendor, profile or authored-rule optimization accompanies this observer.

```bash
# One diagnostic arm, using existing1x60s behavior plus opt-in observations.
python3 tests/manual/profile_room_scaling.py --rooms 1 --player-count 20 --mob-count 20 \
  --netfox-profile compare30 --warmup-seconds 10 --sample-seconds 60 \
  --observe-clients --deadline-seconds 150 --keep-artifacts
# Only after generator qualification: three consecutive30s windows, not a90s relabel.
python3 tests/manual/profile_room_scaling.py --rooms 1 --player-count 20 --mob-count 20 \
  --netfox-profile compare30 --warmup-seconds 10 --sample-seconds 30 --sample-windows 3 \
  --observe-clients --deadline-seconds 150 --keep-artifacts
# Run compare60 separately only when independent/appropriate; never both together.
```

`--sample-windows` defaults to1; the existing1x60s route and gates remain. Three windows require exact REAL20/profile/mob20, warmup10s and sample-seconds30 per window; the normal input route then runs90s total plus its unchanged6s margin. Readiness still precedes warmup; no timeout/phase is forced. Use an external180s whole-arm deadline including owned cleanup. With106s route duration, the150s work budget leaves at most44s for startup; shortage/guard/timeout is failure, not reduced load.

| Observation | Semantics / limit |
|---|---|
| Client `[PROFILE_CLIENT_OBSERVATION]` | Opt-in `--observe-clients`; begins before login. One actual elapsed interval per second, at most180 numeric rows/client; late frames do not fabricate backfilled rows. Counts and effective process/physics/native rates are measured; caps/configured rates are separate readbacks. |
| Rollback/catch-up | Public signal callbacks accumulated per client interval. Catch-up means extra native callbacks beyond the first in a network loop, not queue depth. Rollback process callbacks are processed rollback-range ticks, not unique corrected inputs. |
| Timing | Monotonic wall durations between public signals. Network includes rollback; actor loading lies inside entity-ready activation. They overlap and MUST NOT be added as exclusive CPU. Signal order can exclude earlier subscriber work. |
| Netfox custom monitors | Available last-loop snapshots, not interval aggregates. Missing monitors are null. Debug-build/feature availability affects these monitors, not the independently counted callbacks. |
| External client CPU/RSS | Individual owned PID cumulative TIME/RSS plus actual read begin/end/midpoint timestamps; at most180 rounds retained. The existing aggregate generator guard uses the same estimator/thresholds, unchanged. |
| Server windows | Three distinct consecutive boundaries observed on the server, after its10s post-barrier warmup. Each retains actual callback count, duration, p95/p99 interarrival, population samples/ownership, movement and actual stride. |
| Aligned CPU/RSS | CPU TIME is linearly interpolated from readings bracketing each observed native boundary, not sampled configuredHz. Brackets exceeding2.5s or inconsistent wall/monotonic clocks fail qualification. Read durations/skew are explicit; CPU is an estimator, not exclusive tick CPU. RSS median/max are sampled KiB inside those same boundaries. |

Every window independently requires real20 ownership/population throughout observed samples, movement of all20 owners, stride1 for20 NPCs, complete bracketing CPU/RSS and the existing90%-110% native envelope. The envelope is not exact cadence parity. Three consecutive windows from one cohort are not three independent launches. `comparison.json` includes the window results; sanitized `observation.json` is retained even on failure when artifacts are kept. Missing CPU/RSS/monitor values stay null/unavailable, never consumption zero. Raw temporary gameplay logs may contain ephemeral provisioning credentials: do not publish or copy them blindly.

Instrumentation overhead is present and must be reported; a startup-vs-sustained diagnosis is still pending. A guard abort before stability does not prove that prewarm would solve it. The850% generator CPU ceiling for three consecutive intervals on this10-core host,15% free-memory floor and8GiB owned-RSS ceiling remain active during startup and sampling. No remote transport is implemented here. Current source/check/preservation evidence is in [the observation implementation report](docs/benchmarks/netfox/observation_implementation.json).

## Quick path

Run the existing authenticated, loopback-only room harness from this project. It owns the local PostgreSQL container/volume, backend, Noray and client/server processes, and performs bounded cleanup. The two-client commands use visible automated clients; the explicit REAL20 commands above use full-game headless clients. Allow up to the default 180-second deadline. Dependencies remain the existing Godot, Docker, Go and sibling Noray installation; nothing is installed or deployed by selecting a profile.

```sh
python3 tests/manual/profile_room_scaling.py --netfox-profile compare30 --player-count 2 --mob-count 20 --warmup-seconds 10 --sample-seconds 65 --keep-artifacts
python3 tests/manual/profile_room_scaling.py --netfox-profile compare60 --player-count 2 --mob-count 20 --warmup-seconds 10 --sample-seconds 65 --keep-artifacts
```

The longer 65-second commands below remain unexecuted. Shorter variants passed final connected workload gates after the bounded evidence correction, as recorded above. Earlier failed attempts remain preserved in the correction/evidence section. Repeat in an alternating 30→60→30 bracket on the same machine with the same clients/population/route. A two-player local result must not be promoted as a 20-player VPS comparison. The profiler's `comparison.json` records source hashes, versions, actual singleton readbacks, cadence rows, external one-core CPU and RSS KiB; retain it outside temporary storage before cleanup. Whole 5-second cadence intervals include startup/warmup and are not aligned to the external CPU window. No steady cadence acceptance gate is claimed yet.

For direct existing A/B/C server scenarios, select explicitly before launch:

```sh
NOIKAR_NETFOX_PROFILE=compare30 tools/run_server_benchmark.sh A -- /Applications/Godot.app/Contents/MacOS/Godot --headless --path . -- --benchmark=A
```

Use `compare60` identically. The shell sampler is historical `%CPU` telemetry; the connected Python harness's cumulative CPU deltas are the comparison estimator. A `--netfox-profile=compare30` Godot **user argument** is also supported. Duplicate, invalid, blank argument values or conflicting argument/environment selections exit 64 before networking. The client/server selection is explicit on every peer; the harness passes the same environment to Noray's inherited server environment and every client. Existing auth RPC rejects explicit/default or arm mismatches before token validation; matched-source peers are required. Native Netfox tickrate mismatch also disconnects rather than silently adjusting.

## Settings and non-equivalence

| Contract | FishNet native30 / native60 | Netfox compare30 / compare60 |
|---|---|---|
| Native simulation | 30 / 60 Hz | 30 / 60 Hz, `sync_to_physics=false`, Netfox render-loop clock |
| Engine physics | Unity automatic50Hz, fixed0.02s | Godot Jolt50Hz; controller still `move_and_slide()` during Netfox ticks using `NetworkTime.physics_factor`; NOT the same physics execution model |
| App caps | server75, client60 | server75, client60, both arms; VSync can constrain actual rendering |
| History | five seconds past-replicate history | 150 / 300 ticks =5000ms rollback history; different semantics |
| Stale input | 15 / 30 ticks =500ms | **Not equivalent**: no matching FishNet input-age policy is implemented |
| Server replicate queue | 8 / 15 ticks =266.7 /250ms | **Not equivalent**: Netfox rollback history is NOT this queue |
| Interpolation | two ticks =66.7 /33.3ms | rollback display offset2 ticks =66.7 /33.3ms plus existing TickInterpolator; NOT identical smoothing |
| Input delay / redundancy | existing Appended interpolation / redundancy3 | input delay0 ticks =0ms / redundancy3; different submission behavior |
| SyncVars |100ms =10Hz | existing player/NPC state submissions each native tick30/60Hz (changed-only diffs); NOT matched10Hz |
| Full state cadence | not established by archived source | player StateSynchronizer8 ticks =266.7 /133.3ms, NPC12 ticks =400 /200ms; rollback full state24 ticks =800 /400ms; no periodic diff ACK (interval0) |
| Match snapshots | not established | existing stride6 =5 /10Hz |
| NPC snapshot cadence | natural mobs; exact send rate not established | stride1 =30 /60Hz; no sparse snapshot option in these profiles |
| Authority / prediction | real owner Replicate + authority Reconcile | existing player rollback/prediction, server NPC AI/snapshots; no controller rewrite |
| Workload |20 real owners10/10, natural varying mobs | authored max3/team =6 total remains; explicit loopback load20 clones runtime rules to10/team; real20 case requires independent runtime proof |

Profile manifest: `tools/benchmark_profiles.json`. The first autoload applies settings in `_init()` **before** Netfox singleton construction. GameManager defers opt-in startup until all autoloads exist, checks the actual cached singleton values, emits `[NETFOX_PROFILE]` before networking, then starts the existing server/client path. No vendor Netfox files or scenes are changed.

Every opt-in server PERF interval records actual `NetworkTime.on_tick` callbacks, elapsed monotonic wall time, achieved Hz and nearest-rank p95/p99 callback inter-arrival milliseconds. Catch-up ticks in the same application frame remain near-zero samples; these are not socket cadence or exclusive tick CPU duration. Storage is bounded to4096 intervals per report; drops are explicit and empty percentiles are-1/unavailable. Configured rate is never treated as achieved cadence. Physics rate readback is configuration, not measured physics cadence.

## Preserved measured FishNet baseline

See `docs/benchmarks/fishnet/baseline.json` and sanitized source excerpts beside it for exact provenance and current source-manifest version hashes. They preserve the 2026-10-07 **partial** one-room sequence:

| Native/window | CPU% one core | RSS median KiB | Actual Hz | Cadence p95/p99ms | Steal median% |
|---|---:|---:|---:|---|---:|
|30/1|16.43|200184|30.000|41.340/43.478|9.52|
|30/2|16.06|199360|30.033|40.985/41.998|7.53|
|30/3|15.23|199360|29.967|41.243/42.300|6.68|
|60/1|28.96|199324|59.833|27.666/29.552|15.92|
|60/2|28.07|202048|60.000|27.473/28.489|14.55|
|60/3|29.66|202048|60.000|27.517/28.756|14.98|

The final30 bracket was not launched;60/window1 missed59.9Hz. Steal differed by more than5 percentage points and natural mob medians differed. Lower raw CPU is **not a causal savings percentage**. Exact measured build/source identity, packet loss, instrumentation overhead and full prediction quality remain unqualified. Archived current Unity6000.6.3f1 / FishNet commit73f30cf identify source-manifest readback, not retroactive measured-build proof. Netfox's current plugin version is1.35.3 with pre-existing local vendor modifications; runtime manifests hash those bytes without modifying them.

NPC sparse buffer capacity16 samples and max gap12 ticks remain authored defaults (at stride1,533.3/266.7ms capacity and400/200ms gap for30/60); sparse mode is not active in these profiles. Existing player input broadcast remains enabled; this is not FishNet's same authority/input fanout.

## Evidence and rollback

`docs/benchmarks/netfox/configuration_smoke.json` preserves bounded local zero-player/A startup/cadence evidence only. The focused tests check parsing, manifest round-trip/type validation, default game caps, profile admission comparison and harness forwarding/readback. They do not prove live multiplayer rejection, visual quality,20-owner capacity or connected profile load. The ordinary GUT autoload also attempts unavailable loopback Noray; assertion success is separate from operational networking proof.

Unset the profile and relaunch to restore the existing default30Hz, physics30Hz, history128 ticks, display offset1 and server cap60. No settings are saved at runtime. To remove this work, remove the new BenchmarkProfile autoload/files and only these task-specific hooks from GameManager, MatchManager, PerfProbe and the existing profiler; remove the comparison docs/tests. Preserve all other previously dirty project, vendor, scenes, assets and registry changes. No commit, deployment or remote service was changed.

## Bounded connected-evidence correction

Historical attempts remain in `docs/benchmarks/netfox/local_connected_validation.json`: compare30 authenticated both clients but neither reached the probe's IN_GAME observation within five seconds; no sample exists, so CPU/RSS are unavailable rather than zero. The default-control differential reached gameplay and both clients passed a10.46-second sample, but required authoritative NPC-stride proof was missing. This does **not** prove COUNTDOWN failure is shared or identify a gameplay/profile-setting root cause.

The proven integration gaps are corrected without weakening functional gates: fixed-population profiling now emits counts from actual server NPC synchronizers even with no benchmark scenario, and compare60/60Hz derives stride1 only after the existing full cached server/client readbacks verify native60. Missing/unknown/extra populations, unsupported cadence ratios and profile/readback mismatches still fail. Legacy native30 snapshot choices30/15/10 keep strides1/2/3. Comparison profiles intentionally support only full-rate snapshots; a native60 profile with a requested30Hz NPC rate remains unsupported rather than assuming the existing30Hz-only NPC environment policy works at60.

Comparison clients enable observation-only `NOIKAR_PROFILE_PHASE_TRACE=1`: at most128 numeric `[PROFILE_PHASE]` lines record local monotonic microseconds, snapshot/event/UI-switch source, phase, before/after UI state and native tick. No account, room identifier, token or arbitrary snapshot content is logged. `comparison.json` keeps bounded sanitized trace rows. The suspected older CHARACTER_SELECT snapshot arriving after COUNTDOWN remains **unproven**; tracing does not change phases, state transitions, timeouts or readiness criteria.

Current correction source hashes and regression outcomes are in `docs/benchmarks/netfox/bounded_correction.json`. Original smoke and first connected reports remain unchanged as historical snapshots. Final independent short compare30/compare60 runs passed their targeted connected workload gates; see `docs/benchmarks/netfox/final_connected_validation.json`. Phase-event integrity, longer runs and 20-owner VPS/FishNet equivalence remain unqualified. The correction writer itself launched no connected workload.


## Isolated VPS and bounded cold-start preparation

The [VPS adapter](docs/VPS_BENCHMARK.md) retains normal authenticated REAL20 admission and simulation; runtime qualification is pending. It adds an opt-in15s **probe IN_GAME observation** allowance (default5s unchanged) and opt-in per-source semantic trace dedupe. Neither is a gameplay/phase repair or proof that original failures are solved. Existing guards and population/native/physics/movement gates remain mandatory.

Remote staging uses a dependency PCK, checksum-pinned disposable Noray closure, loopback backend reverse SSH and autonomous150s+30s owned cleanup lease. Only the requested narrow Noray UDP bind adapter is a vendor transport exception; rollback simulation, profile manifest, production rules and every historical report stay unchanged. See the guide for exact commands and unresolved Linux/auth/firewall/UDP qualification.


A separate [cleanup safety correction](docs/benchmarks/netfox/cleanup_safety_correction.json) removes the sequential20s remote wait plus legacy local cleanup: remote stop occurs first, local teardown and completion polling share one30s deadline, and timeout/exception/unproved cleanup prevents qualification. The autonomous agent handles disappearing groups idempotently and attempts exact owned-rule removal/completion in `finally`. Its25 deterministic no-service tests passed; actual VPS teardown/disconnect and REAL20 samples remain unqualified pending independent verification. The original adapter report and every historical result remain immutable. Prior Python98 tests and Go checks passed, but GUT58/59 failed an unexpected default Noray connection error; there is still no aggregate GUT PASS or qualified VPS sample.
