# Isolated REAL20 VPS benchmark

> **Final delivery: STOP / NOT READY.** [Read the final comparison summary](benchmarks/COMPARISON_SUMMARY.md) and [traceable CSV](benchmarks/measurements.csv). The corrected 479-entry / 200161320-byte PCK was verified, but REAL20 compare30 did not qualify: 16/20 ready, generator guard and runtime errors, no steady windows. Compare60 was held, not run. [Final cleanup](benchmarks/netfox/vps_final_cleanup.json) cleared owned processes, rules and ports and removed the temporary matched Godot runtime. The private binding below therefore points to a **removed runtime**; re-stage and independently verify a new isolated matched runtime/binding before any future authorized arm. Do not touch production or execute the historical commands as-is.

## Newly authorized REAL10 quick mode — implementation only

The user requested a faster **one-room REAL10 / 5v5** check. The prepared mode keeps ten distinct authenticated normal headless clients, twenty live NPCs, ordinary gameplay and prediction, client 60 FPS / physics 50 Hz and server 75 FPS / native 30 Hz. It requests **one actual 30-second window after 5 seconds of warmup**, not three windows and not a comparable REAL20 / FishNet measurement. Existing REAL20 defaults remain 20 clients, 10v10, 10-second warmup and three consecutive 30-second windows. Production rules remain three players per team; only explicit remote benchmark runtime clones use five or ten per team.

**Not operationally qualified.** [The quick implementation report](benchmarks/netfox/load10_quick_implementation.json) records 63/63 focused Python checks passing. The writer's native `--check-only` preload check returned exit 0 but emitted unresolved-autoload compilation errors; it is **NOT PASS**. A fresh checker must first verify the exact source snapshot in proper project context. No gameplay, services or export ran in this writer unit. [Shader include closure proof](benchmarks/netfox/load10_shader_include_packaging.json) now includes eight previously omitted include/UID files, including the original `streaks.gdshader` relative include. Strict static closure is 486 files / 200,096,160 source bytes / 87 classes; this is not a rebuilt PCK or proof that the historical 162 shader/node/RPC/null errors are fixed.

Operator preparation reports a newly isolated matched runtime staged at the new owned runtime root; no gameplay services were started. The new private binding below has `runtime_path`, `runtime_version` and `runtime_sha256`. The adapter forwards all three, restricts the executable to a known owned `/tmp/noikar-netfox-runtime-<12hex>` root and checks the pinned official version and executable hash before launch. Partial or mismatched fields fail closed. An old binding with no runtime fields retains legacy selection, but the removed legacy executable fails preflight rather than silently launching another runtime.

### Planned quick command — after independent context / package verification

Do not reuse the old PCK or execute the old removed-runtime binding. `NODE20` must be replaced with the already installed, independently verified absolute VPS Node 20.19.2 path. These commands are a handoff, **not evidence of execution**:

```sh
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 tests/manual/package_vps_benchmark.py \
  --destination /private/tmp/noikar-load10-package-NEW-ID \
  --godot /Applications/Godot.app/Contents/MacOS/Godot

PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 tests/manual/profile_vps.py \
  --binding /private/tmp/noikar-load10-runtime-12d0d2ee1355/private-target-binding.json \
  --package /private/tmp/noikar-load10-package-NEW-ID \
  --noray-closure /private/tmp/noikar-noray-closure-_gw1pgpw/noray-runtime.tar.gz \
  --node NODE20 --netfox-profile compare30 \
  --player-count 10 --sample-windows 1 --sample-seconds 30 --warmup-seconds 5 \
  --preparation-timeout-seconds 15 --dedupe-phase-trace \
  --output docs/benchmarks/netfox/load10_quick_compare30_NEW-ID.json \
  --execute --allow-temporary-firewall
```

Supported closed plans are exactly REAL10 / 1 × 30 seconds / 5-second warmup and REAL20 / 3 × 30 seconds / 10-second warmup. No implicit reduction or clamping. REAL10 qualification still requires one OID, ten unique owners and authenticated accounts, exact 5/5 teams, all ten spawned / OWNER_READY / actively moving, achieved clocks and twenty actual authoritative NPCs with stride 1. Nine of ten, missing clocks/readings, runtime errors or incomplete cleanup fail; unavailable statistics remain null.

Forecast: ten full headless client processes on the Mac, disposable owned loopback Postgres/backend plus SSH forwards, and one owned VPS game/Noray/watchdog. The 5 + 30-second measurement segment is 35 seconds; client route margin is six seconds and admission may dominate elapsed time. No claim that CPU halves or that reducing count fixes runtime errors. Package preparation remains at most 90 seconds, separate server preparation at most 120 seconds, active arm at most 150 seconds and shared cleanup at most 30 seconds (**180 seconds inclusive remote lease**). Local 850% one-core CPU for three complete intervals, 15% reclaimable RAM and 8 GiB owned RSS guards are unchanged for ten clients; remote guards are unchanged. No next arm after unproved cleanup. The operator must separately remove the newly owned temporary runtime after final use.

Rollback of this new unit is limited to the exact paths and prior dirty-byte backups listed in the two reports. Historical reports, final summary/CSV, assets, imported runtime resources, production defaults and the premodified vendor rollback synchronizer remain untouched.

---

The remainder records adapter setup and earlier writer-stage proofs. Those historical “pending” statements are superseded by the final reports, not erased. Physical owned cleanup was verified; no qualified REAL20 performance or framework comparison was obtained. Historical GUT remains 58/59 FAIL.

This adapter prepares **one disposable authenticated room**, not a production deployment. It keeps20 normal headless clients,10v10,20 live NPCs, client60FPS/physics50Hz, server75FPS and native30/60Hz. Qualification requires actual gameplay, unique authenticated owners/accounts, population/movement/stride/readback/achieved cadence and three consecutive30s windows after10s warmup. Missing metrics are unavailable, never zero.

**Cleanup safety correction is prepared for independent verification.** The supervisor now stops the remote arm first, cleans local owned resources while the autonomous watchdog runs, then polls completion only within one shared30s deadline. Disappearing owned groups are idempotent; process teardown exceptions cannot skip the agent's rule-removal/completion `finally`. Timeout, exception, missing ownership/cleanup proof or actual budget excess prevents qualification. This is deterministic fixture proof, not an executed VPS cleanup. The prior GUT aggregate remains58/59, not PASS: the absent default Noray autoload emitted an unexpected error during the occupied-bind fixture.

**Packaging closure is prepared for independent verification, not a qualified runtime sample.** A separate [metadata extraction fix](benchmarks/netfox/package_metadata_extraction_fix.json) passed38 unit tests and one native metadata scan of335 resources plus208 import descriptors. Strict closure contains478 files/200,094,016 source bytes, including the previously omitted VFX bases and forest texture/import/runtime targets. Native `ConfigFile` supplies all `[remap] path/path.*` values unchanged; descriptor-owned UIDs and `deps.dest_files` are not runtime dependencies. Text `ext_resource` UID/path pairs use explicit fallback paths, rejecting ambiguous UID-only references. The previous [failed packaging correction](benchmarks/netfox/package_dependency_correction.json), first Linux compare30 failure and original package remain immutable. Its53.49s erroring startup CPU/RSS diagnostics are not active performance. No replacement PCK, deployment or gameplay was executed by this writer; fresh Linux qualification is still required.

**Runtime qualification is pending.** Writer checks launch no SSH/services/deployment/firewall/load. Existing local failures remain immutable. A15s probe allowance neither proves a phase race fixed nor improves server performance.

## Historical command reference — NOT READY

From `noikarv3`, prepare a new dependency PCK using the matched local4.8.dev6.official.8898c2b3d runtime. Never replace the production4.7 binary. `NODE20` means the already installed, preflight-verified absolute VPS Node20.19.2 path; this adapter does not install runtimes.

```sh
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 tests/manual/package_vps_benchmark.py \
  --destination /private/tmp/noikar-vps-package-NEW-ID \
  --godot /Applications/Godot.app/Contents/MacOS/Godot

# One arm only, with caller's reviewed execution/firewall escalation.
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 tests/manual/profile_vps.py \
  --binding /private/tmp/noikar-godot48-runtime-7ieqlkwt/private-target-binding.json \
  --package /private/tmp/noikar-vps-package-NEW-ID \
  --noray-closure /private/tmp/noikar-noray-closure-_gw1pgpw/noray-runtime.tar.gz \
  --node NODE20 --netfox-profile compare30 \
  --preparation-timeout-seconds 15 --dedupe-phase-trace \
  --output docs/benchmarks/netfox/vps_compare30_NEW-ID.json \
  --execute --allow-temporary-firewall
```

Compare60 is HOLD and was not executed. No further arm is authorized by this historical reference; future work first requires the runtime/binding and shared blockers to be resolved. Never overwrite historical results or blindly retry failure. Budgets: dependency scan<=40s, version check<=5s and PCK build<=45s separately (<=90s package preparation total);15s remote idle preflight+upload/extraction/local backend/accounts<=120s; active arm<=150s including admission/readiness; cleanup<=30s, **180s inclusive autonomous remote lease**. Insufficient startup/sample time is failure, not a shorter qualified sample.

## Isolation and ownership

| Boundary | Contract |
|---|---|
| API/Postgres | Disposable local loopback resources. Backend explicitly `BIND_HOST=127.0.0.1`; absent setting retains ordinary wildcard default. |
| Reverse SSH | `127.0.0.1:24689 → Mac127.0.0.1:18090`, `ExitOnForwardFailure=yes`. |
| Noray | New disposable TCP24691; HTTP127.0.0.1:24692 (loopback SSH forward); UDP registrar24693; relay24600–24639. |
| ENet | Server requests24690 via real PID→OK UDP registrar and official `local_port`. Clients remain ephemeral0. Same actual public control/registrar address. |
| Authentication | Unchanged JWT/creator ticket, single-use instance binding, server ticket validation and server-ready flow. No forced phases/fake clients/direct synthetic server. |
| Secrets | ENV/stdin only, private0600 environment/SSH binding, no credential argv. Staged Noray spawner forwards existing fields via ENV and retains hooks. Sibling unchanged. |
| Firewall | Absent TCP24691 rule only, unique run tag, actual SSH-egress IPv4 `/32`. Delete exact verified source/protocol/port spec, never mutable index/broad rule. |
| Ownership | Unique `/tmp/noikar-netfox-bench-<12hex>`; PID+starttime+UID+PGID before signals. TERM6s→KILL2s only proved owned groups. |
| Disconnect | Detached autonomous watchdog armed before firewall/services.150s active+30s cleanup, no renewal. Children have closed/redirected stdio. Completion manifest persists. |
| Measurement | Linux `/proc` user+system/CLK_TCK at1Hz,100%=one core; RSSKiB, real same-host Unix timestamps; interpolation to actual native boundaries, not SSH arrival. |

Preflight15s: median idle>=70%, median steal<=10%, MemAvailable>=2GiB, disk>=1GiB, required ports absent. Runtime: available memory>=20%, owned RSS<=1.5GiB; idle<10% or steal>30% for6 observed intervals aborts. Local850% CPU for3 intervals,15% reclaimable RAM and8GiB owned RSS guards remain. Guards are safety, not performance PASS.

The PCK closure includes conservative runtime global classes, relative glTF image/buffer URIs, context-aware source/UID references, native ConfigFile remap values and metadata-only native binary dependencies. Strict closure now passes for the exact dirty snapshot; generated class-cache and dependency hashes are retained in the fix report. A new PCK must still be built and checked independently; source closure size is not measured PCK size. Recheck VPS available disk>=1GiB after staging and before services. It is not a whole-repo ZIP. Secrets/VCS/docs/backend/editor state excluded; runtime class registry is generated. Payload<1GiB. Missing static dependencies or Linux incompatibility must fail qualification, not trigger asset/simulation stripping.

## Cleanup safety proof

The separate [cleanup correction report](benchmarks/netfox/cleanup_safety_correction.json) preserves the previous adapter report unchanged. Its25 deterministic tests (13 new safety fixtures,12 existing adapter fixtures) passed without SSH, Docker, services, real signals or network sockets. GUT was not rerun; its prior failure is not promoted to PASS.

```sh
cd tests/manual
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -B -m unittest -v \
  test_cleanup_safety test_vps_benchmark
```

| Boundary | Correction |
|---|---|
| Supervisor | `finish_cleanup`: one monotonic deadline; remote stop<=3s, VPS-only local teardown, completion polling<=remaining time. No up-front20s wait and no inherited `CleanupPlan.run()`. Ordinary loopback cleanup defaults are byte-unchanged. |
| Local teardown | Only tracked session leaders and exact generated Docker names; TERM<=6s/KILL<=2s, each Docker call<=min(8s,remaining), loopback readbacks<=remaining. A changed group is not signaled. |
| Remote teardown | PID/starttime/UID/PGID rechecked; disappeared group succeeds idempotently, foreign PID reuse is not signaled, changed live UID/PGID remains unproved. Rule removal, credential deletion and completion are attempted in `finally`, even after process errors. |
| Deadline | Agent uses min(30s,inclusive lease remainder). UFW status/delete/readback each uses only remaining time. Timeout/OS exception produces incomplete proof, not zero/empty substitute metrics. Actual excess is retained in reports and fails qualification. |
| Qualification | Requires both measured workload/transport gates and complete local+remote cleanup proof within budget. `cleanup_verified` reports the combined result, not only remote completion. No next arm after unproved cleanup. |

These budgets bound user-space waits/child-command timeouts, not a hard real-time OS scheduling guarantee. The observed duration is authoritative: any excess or inability to verify cleanup is a safety failure, regardless of server statistics. Independent execution must still prove actual owned teardown, exact tagged-rule removal and disconnect lease behavior before claiming unattended operational qualification.

## Preparation / trace

`--preparation-timeout-seconds` defaults5;15 allowed only for explicit REAL10 or REAL20 benchmark loads. It bounds **probe observation of actual IN_GAME after ordinary selection**, not production timeout/readiness/auth/phase behavior. Failure text now names IN_GAME observation rather than falsely asserting countdown failed.

`--dedupe-phase-trace` opt-in suppresses consecutive identical `(phase, ui_before, ui_after)` rows per source, retaining transitions/regressions within128 rows. No state event is suppressed or reordered.

Local command retains the existing supervisor and all gates:

```sh
PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 tests/manual/profile_room_scaling.py \
  --player-count 20 --mob-count 20 --netfox-profile compare30 \
  --warmup-seconds 10 --sample-seconds 30 --sample-windows 3 \
  --observe-clients --preparation-timeout-seconds 15 --dedupe-phase-trace \
  --deadline-seconds 150 --keep-artifacts
```

## Qualification / rollback

Before claiming statistics: prove Linux PCK/Node startup, source-scoped TCP and UDP route; one OID/20 real accounts/owners/10v10; all spawned/moving+20 live NPCs/stride1; native/physics/FPS readbacks and achieved cadence; three complete aligned30s windows; no early exits/errors; remote owned groups/ports/rule clear and local disposable resources removed. After SSH uncertainty, inspect remote completion before another arm.

FishNet baseline/configs remain immutable. Engines, prediction/queues/stale policies, snapshots, rendering/pacing, Unity physics vs Netfox simulation delta and natural variable FishNet mobs remain non-equivalent. Consecutive windows are not independent repeated runs. No causal ranking from failed preparation/workload.

Rollback of this safety unit only: restore exact prior dirty bytes of `tests/manual/profile_vps.py`, `tests/manual/vps_benchmark_agent.py`, this guide and `NETFOX_COMPARISON.md` from the correction report backup; remove only new `tests/manual/test_cleanup_safety.py` and `docs/benchmarks/netfox/cleanup_safety_correction.json`. Rollback of the earlier adapter remains a separate boundary recorded in its original implementation report. Do not restore the whole checkout, production rules, assets, historical reports or the vendor rollback synchronizer. Runtime ownership cleanup is separate.
