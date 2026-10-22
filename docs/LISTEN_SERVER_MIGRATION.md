# Player-hosted Noikar migration

## Status

Implementation is on `feat/godot-4.8-listen-server` in an isolated clone of
`kloehz/noikarv3`. The original checkout and its uncommitted work are unchanged.
The approved plan is `2026-10-22-noikar-godot-4.8-listen-server.md` in the user's
OpenCode plan directory; this record tracks implementation evidence, not completion.

## Preserved baseline

- Published parent: `68429e3e36ea0c0379e370141297f27595bc44ae`.
- The starting point additionally includes existing local gameplay, performance,
  addon, scene, asset-import and test changes. These are inherited work, not changes
  authored as part of the hosting migration.
- A private hash-verified backup preserves all 483 modified/untracked files and the
  original binary diff/status. The original checkout remains a second untouched copy.
- 452 non-registry/non-bytecode/non-translation source/evidence files were copied.
  Historical measurement captures under `docs/benchmarks/` remain preserved locally
  and in the backup, but are not added to the migration's source commits. No private
  environment configuration was copied to the running project.
- No new Godot project, gameplay replacement, remote repository, deployment, or
  modification to the template repository is involved.

## Initial verification findings

These were reproduced before implementation; they are not newly introduced failures:

| Check | Initial result | Required follow-up |
| --- | --- | --- |
| `python3 tests/verify_headless_server.py --quick` | FAIL: validator requires 4.7 while the preserved project already declares 4.8 | Update and test the engine contract, not just project metadata. |
| `python3 tests/verify_gut_suite_integrity.py` | FAIL: `pending()` in `tests/unit/test_game_manager.gd` | Replace skipped environment-dependent assertion with real deterministic coverage; retain integrity enforcement. |
| `python3 tests/verify_export_isolation.py` | FAIL: shared MatchManager directly references core AI component | Inspect actual resource dependencies and intended scene composition; test isolation behavior rather than disable the checker. |

No full engine/GUT startup was run against this baseline before isolating test
bootstrap: the inherited headless autoload would try to contact external services.
Installed engine: `4.8.beta1.official.4d10419ca`; it is a prerelease. Installed Go:
`go1.26.5 darwin/arm64` (module declares Go 1.26.4).

## Godot 4.8 compatibility checkpoint

The engine compatibility work is verified separately from player hosting:

- Fresh editor import: exit 0, zero engine/script errors. Existing duplicate-UID
  warnings in the unused model-test folder remain visible.
- Full GUT run through `./play.sh tests`: **412/412 tests, 2,441 assertions**, exit 0,
  zero engine/script errors. It still reports six expected warnings from deliberate
  failure/security fixtures and 24 inherited unparented fixture nodes; this is not
  a claim of a warning/orphan-free long-running game.
- GUT children use `NOIKAR_TEST_MODE=1` to suppress external bootstrap. Standalone
  probes may use `--noikar-test-mode`; the production/release policy rejects it.
  Neither path grants account admission or opens a real multiplayer connection.
- Existing test setup now owns its offline peer, optional probe, local presentation
  role and spawned fixtures. No game balance was changed to satisfy stale tests:
  the authored healer damage remains 24, below ranged DPS damage 44.
- The OBJ vendor sample's missing material declaration was removed without changing
  its geometry. Two internal KogMaw GLB/PNG filenames were normalized to avoid a
  reproduced apostrophe/import-checksum serialization error in 4.8; binary hashes
  and resource UIDs were preserved, with one actor reference updated.
- A detached-world team callback now safely ignores a late signal; the regression
  was observed failing before the guard was introduced.

Rollback boundary: bootstrap guard/launcher/tooling, fixture ownership repairs,
late-signal guard, and compatibility-only asset paths. The preservation baseline
retains the original source and paths; no peer-host gameplay implementation is
claimed at this checkpoint.

## Static export boundary

The export checker now reads preset display names/filters rather than interpreting
`preset.0` as a product name. Both runtime exports retain required shared/simulation/
presentation scripts, while backend, Noray service sources, tests, GUT and environment
configuration are explicitly filtered. A global `.gdignore` in these runtime folders
is rejected instead of suggested as an export-security fix. Four controlled-preset
regressions passed RED→GREEN. This is configuration validation, not proof of actual
PCK contents; the final build gate still inspects compiled artifacts. Rollback is
limited to the checker, its tests, and preset filters.

## Rendered compatibility evidence

`tests/manual/engine_visual_probe.gd` rendered the actual inherited main scene,
player model, camera and HUD on native macOS. It manually drove existing movement
and attack handlers for 45 physics frames: camera active, 14.83 m displacement,
attack observed and screenshot saved, with exit 0 and no engine/script errors.
This uses an offline peer and a fixture identity: **no backend authentication,
networked host-client match, or Steam operation is certified by this probe**.

See `docs/evidence/godot-4.8-compatibility.png` and
`docs/evidence/godot-4.8-compatibility.json`. Run it with child-only
`NOIKAR_TEST_MODE=1` and the pinned graphical Godot executable; a headless display
is deliberately rejected. Reports and temporary test outputs are excluded from
runtime resource imports. Rollback removes only the diagnostic probe/evidence.

## LAN transport factory

`common/net/enet_transport.gd` creates ENet endpoints without attaching a second
multiplayer owner or changing Netfox channels. A real loopback test connects five
guests and verifies a sixth guest cannot enter: six humans includes the host.
Invalid ports return an error and no live peer. This is a transport-capacity check,
not account admission or a six-player full-match claim. Rollback removes the factory
and its focused tests only.

## Session lifecycle and compatibility

One GameManager-owned child session attaches the player-host peer. Its generation
invalidates delayed connection/auth/load work before cleanup; closing erases the
scoped room credential, routes teardown through Netfox's existing clock-stop events,
awaits world cleanup, and only then permits another attachment. An obsolete Netfox
initial-sync continuation is now cancelled rather than reviving a closed clock.

Transport authentication exchanges protocol, engine build/full commit hash and a
deterministic hash of the existing Netfox addon scripts/configuration before
`peer_connected`. This compatibility check does not establish account identity.
The account-admission implementation is a separate gate. No account credentials are
accepted in the host identity dictionary. Incompatible-peer disconnect is deferred
outside the auth callback to avoid a reproduced 4.8 beta crash. Ten real lifecycle
tests cover duplicate attach/close, stale completion, cleanup ordering and clock
cancellation. Rollback is the session service, its tests and the local Netfox
cancellation guard; simulation algorithms and tick rate are unchanged.

## Scope and safeguards

Preserve two teams, three players per team, the existing combat/AI/pets/souls/totems,
all stages, shared boss, presentation and effective 30 Hz simulation. Adapt one
peer/session lifecycle and the local host player; retain Netfox initially. LAN and
optional Steam replace dedicated per-room provisioning only in the new player-host
path. Account authentication remains a lightweight API responsibility.

Player hosts must not receive reusable account bearer tokens or dedicated world
credentials. Internet account validation requires HTTPS and the new scoped-admission
backend rollout; no live service changes are authorized by local implementation.

Host departure ends the session safely; automatic host migration and trusted ranked
results are outside scope. Final evidence must distinguish fixtures, actual local
processes, human Steam accounts, native platform runs and unexecuted gates.
