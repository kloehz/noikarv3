# NPC motion correction

## Contract

Correct the demonstrated enemy/pet hold-and-catch-up defect while preserving
authoritative PvPvE, movement speeds, collisions, combat, 30 Hz clocks, ENet and
optional Steam. User authorized necessary node/physics changes, not speculative
removal of gameplay constraints. Existing migration work stays intact and local.

Execute inline. This is already an isolated migration branch; do not create a
second checkout that omits the uncommitted F5 setup. Do not push, merge, or replace
production. Preserve overlapping changes uncommitted as in the migration ledger.

## Task 1: Source-time playback at every NPC snapshot rate

- [ ] RED: add full-rate burst-arrival tests, metadata-only writer, lifecycle,
  history batching, late source clocks and bounded recovery tests.
- [ ] GREEN: use timestamp history at strides 1–3, metadata-only client sync,
  bounded source-relative playback clock (no extrapolation or one-tick catch-up).
  Consume all new retained source snapshots, not just the newest packet.
- [ ] Verify NPC buffer/interpolator/synchronizer and integration suites.

Expected: controlled constant-speed motion remains bounded under batched arrivals;
the client network clock being ahead cannot empty the rendering buffer. Health
and combat metadata are applied immediately. Authority keeps original simulation
and host presentation; teleports, disconnects, reconfiguration, and clock resets
discard obsolete history. No addon edits or wire-format change required.

## Task 2: Physics and work audit

- [ ] Inspect actual body types, collision consumers, server/client paths and
  existing profiling. Run opt-in cost benchmark and collision recovery tests.
- [ ] Remove only redundant work proven safe by RED/GREEN tests and measurements;
  otherwise retain the existing collision model and record evidence.

Expected: no unsupported CPU savings claim; moving NPCs still cannot walk through
walls/hostile bodies. No enabling experimental dormancy without its acceptance.

## Task 3: Runtime acceptance and review

- [ ] Run native VPS A/B motion probe without changing production or stopping an
  active room. Validate real pet rendering via an opt-in isolated gameplay probe.
- [ ] Run complete GUT, Python contracts, rendered two-process LAN regression.
- [ ] One fresh scoped review of current changes (not all pre-existing migration
  work); address important findings with RED/GREEN, record evidence and limits.

Expected: measured reduction in hold/catch-up, no gameplay/authority regression,
F5 remains usable. Record actual conditions rather than claiming all jitter is
eliminated. No deployment needed for client-only visual changes; if server sync
changes require packaging, update only the authorized idle isolated instance.

## Review focus

Clock lead/rewind; burst/loss/stall recovery; source history bounds and allocation;
teleport and authority changes with stale history; headless listen-server versus
graphical player-host behavior; single transform writer; actual enemy and pet
motion; metadata/health/attack latency; inherited uncommitted work preservation.
