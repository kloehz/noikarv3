# Project Status: noikarv3

**Initialized**: 2026-07-29  
**Current state**: Authenticated multiplayer baseline is functional; SDD is initialized for planning the lobby, team-ready, and character-selection flow. No feature code was changed by initialization.

## Current SDD State

| Area | Status |
| --- | --- |
| Artifact store | `openspec/` |
| Active changes | None |
| Source specifications | `match-lifecycle`, `team-identity`, `network-timing-calibration` |
| Archived changes | `rollback-integrity-baseline`, `tickrate-speed-calibration`, `match-foundation` |
| Execution mode | `auto` |
| Delivery strategy | `auto-forecast`, 400 changed-line review budget |
| Strict TDD | Disabled by `openspec/config.yaml` |

## Architecture Constraints

- Godot 4.7 with static-typed GDScript, Jolt Physics, Netfox v2.x, Noray, and a Go/PostgreSQL authentication API.
- The server owns authoritative state through `ServerState`/`StateSynchronizer`; clients present replicated state.
- Rollback-aware physics belongs only in `_rollback_tick`; match and lobby orchestration must remain outside rollback paths.
- Prefer Inspector-configured `.tscn` composition and reusable nodes over procedural scene construction.
- Use `EventBus` for decoupled cross-system events. Preserve keyboard/gamepad focus when adding UI controls.

## Verified Capabilities

| Check | Result |
| --- | --- |
| `python3 tests/verify_export_isolation.py` | Passed |
| `python3 tests/verify_headless_server.py --quick` | Passed |
| `cd backend && go test ./...` | Passed (2 tests) |
| `cd backend && go test -cover ./...` | Passed |
| GUT 9.7.1 | Vendored; shell execution is blocked because `godot` is not on PATH |

## Planning Boundary

The existing connection flow already includes account login/registration, a create-or-join room screen, and a pre-connection character `OptionButton`. The next change must define the server-authoritative room roster, ready state, post-connection team presentation, and character-selection ownership without changing the existing match-lifecycle and team-identity guarantees.

## Next Step

Run `/sdd-explore` for the multiplayer lobby, team-ready, and character-selection flow; then create a proposal before implementation.
