# PvPvE Action Match Roadmap

## Decision

**Target project:** `noikar/noikarv3` (this repo).

**Reference project:** `noikar-old/noikar` (read-only during migration).

**No networking code from the old project is copied.** Assets, UX patterns, and weapon feel are migrated; all logic is reimplemented on NEW's rollback architecture.

| Area | Base |
|---|---|
| Rollback, movement, projectiles, souls, totems, pets | NEW |
| Bow, sword, staff, lobby UX, bow charge feel | OLD as reference |
| Not-MU MMORPG | Out of scope; only backend/testing patterns if needed |

## Initial Guards

Target is on branch `feature/pets` with uncommitted local changes:

- `scenes/main.tscn`
- `scenes/connection_menu.tscn`
- Model `.import` files
- `.atl/` files

Before touching gameplay:

1. Inventory those changes without overwriting them.
2. Baseline the project (open, run, verify).
3. Create a new branch for this initiative.
4. Treat `noikar-old` as read-only reference.
5. Use `openspec/PROJECT_STATUS.md` as current technical state.
6. Ignore `NETFOX_INTEGRATION.md` as source of truth — it is stale.

## Match Rules

| Rule | Decision |
|---|---|
| Teams | Red vs Blue |
| Start | Opposite corner spawns |
| Initial phase | PvE race to center |
| Mobs | Neutral; provide economy and pressure |
| Mob reward | Team chooses: drop souls to ground OR spawn instant minion |
| Souls | Fall to ground; not auto-collected by killer |
| Pickup | Any ally can collect; enters team bank, not personal inventory |
| Totems | Plantable by players, server-validated |
| Central gate | First team to reach activates boss and teleports the other team |
| Boss | Shared HP; damage attributed to Red or Blue |
| Victory A1 | First team to damage threshold wins |
| Fallback | If boss dies before threshold, highest damage wins; tie goes to short overtime |

## Match Phases

```
LOBBY
  -> COUNTDOWN
  -> ROUND_SETUP
  -> PVE_RACE
  -> BOSS_LOCK
  -> BOSS_DEPLOY
  -> BOSS_A1
  -> RESULT
  -> POST_MATCH
  -> LOBBY
```

### LOBBY
- Create/join room via Noray.
- Choose Red or Blue.
- Ready per player.
- Team balance and capacity defined by rules.
- Only server can start countdown.

### ROUND_SETUP
- Each team spawns at its corner.
- PvE spawn initialization.
- Reset soul banks, minions, totems, score.
- Match seed for reproducible random events.

### PVE_RACE
- Normal action combat.
- Server determines kills, rewards, ownership.
- Each mob death generates a unique reward ticket.
- Highest-contributing player on winning team gets a brief choice window.
- No choice = auto-drop souls.

### BOSS_LOCK
- First valid gate crossing wins the race.
- Gate evaluated server-side only.
- Same-tick crossing: tick, gate penetration, stable entity ID resolves.
- Race-phase spawns/rewards close.
- Inputs briefly locked for transition.

### BOSS_DEPLOY
- Both teams teleported to opposite arena entrances.
- Clean up race-phase PvE not entering boss arena.
- Short boss countdown.
- Boss and meters synced before attacks enabled.

### BOSS_A1
- Boss with shared HP.
- Two damage meters: Red and Blue.
- First team to cross threshold wins immediately.
- Temporary rift totems spawn at predefined anchors.
- If a team trails by 10%+ of threshold, it gets priority on next rift totem.

### RESULT
- Winner, victory cause, damage per team, souls collected, minions summoned.
- No auto-rematch: return to lobby.

## Target Architecture

### New Types

| Type | Responsibility |
|---|---|
| `TeamId` | `NONE`, `RED`, `BLUE` |
| `MatchRules : Resource` | Config: boss HP, threshold, caps, costs, timings, spawns |
| `MatchState` | Server-authoritative: phase, roster, boss HP, damage meters, winner |
| `MatchDirector` | Sole owner of phase transitions, gate, teleports, result |
| `KillRewardChoice` | `DROP_SOULS` or `SPAWN_MINION` |
| `BossEntity` | Shared boss, health, behavior, damage events |
| `TeamBank` | Souls per team; not per player |
| `DamageEvent` | Accepted hit exactly-once to avoid rollback double-count |

### Extensions to Existing Systems

| NEW System | Required Change |
|---|---|
| `common/SoulEntity.gd` | Team owner, reward ID, origin metadata, server-authoritative pickup, replicated expiry |
| `common/TotemEntity.gd` | Owner, team, placement validation, team bank cost, synced state, expiry |
| `common/PetEntity.gd` | Team ID, faction targeting, team/type caps, lifetime, damage attribution |
| `common/EnemyEntity.gd` | Neutral faction, reward payload, stable spawn ID, boss support |
| `common/match_manager.gd` | Extract lobby/match/spawn responsibilities; avoid god object |
| `core/CombatComponent.gd` | Emit accepted damage with source/team; friendly-fire policy; pet/projectile attribution |
| `common/ProjectileEntity.gd` | Snapshot direction, damage, owner, team, lifetime, spawn ID |
| `ServerState.gd` | `team_id`; no global match state here |
| `LogicComponent.gd` | Rollback-safe inputs for attack, reward choice, totem preview/plant |

## P0 Blocker: Fix Rollback Before Gameplay

No boss, teams, or weapons before resolving this.

Today `BaseEntity._rollback_tick()` manually calls `LogicComponent._rollback_tick()`, but Netfox also auto-discovers and ticks rollback-aware descendants. Result: `LogicComponent` may execute **twice per tick**.

Files to audit/fix:

- `common/BaseEntity.gd`
- `common/EnemyEntity.gd`
- `common/PetEntity.gd`
- `core/LogicComponent.gd`
- `scenes/BaseEntity.tscn`
- `addons/netfox/rollback/rollback-synchronizer.gd`

Acceptance criteria:

- One input produces exactly one movement/attack per tick.
- Rollback simulation does not duplicate dash, hitbox, cooldown, or spawn.
- Ownership applied before `RollbackSynchronizer.process_settings()`.
- No `randi`, `randf`, `SceneTreeTimer`, or wall-clock time inside rollback simulation.
- Random totems/spawns use seed + sequence or `RewindableRandomNumberGenerator`.

## Economy: Kills, Souls, Minions

### Mob Reward

On mob death, server calculates valid team contribution and creates a `mob_death_id`.

Winning team gets a 1.5-second choice:

| Choice | Effect |
|---|---|
| `DROP_SOULS` | Spawn 2 physical souls at death point |
| `SPAWN_MINION` | Spawn one chosen-type minion near corpse |

Timeout, disconnect, or invalid request defaults to `DROP_SOULS`.

### Anti-Abuse Rules

- Each `mob_death_id` consumed once.
- Minions: max 3 alive per team.
- Max 1 per type.
- Cap reached = fallback to souls.
- Minions cannot collect souls, plant totems, activate gate, or choose rewards.
- MVP: minions attack mobs and boss only, not enemy players or totems.
- Spawn validated server-side on navmesh/ground, no overlap, fallback to souls.

### Initial Types

| Type | Role |
|---|---|
| Striker | Sustained damage to mobs/boss |
| Guardian | Taunt and mitigation |
| Mender | Limited healing to allies/minions |

## Plantable Totems

Totems are team tactical structures, not direct kill rewards.

### Initial Rules

- Cost: 4 team bank souls.
- Server validation:
  - Valid phase.
  - Player alive and correct team.
  - Max 4m distance to target.
  - Navigable ground, valid slope.
  - No overlap with entities, walls, boss, gate, or arena boundaries.
  - Minimum 6m separation from other totems.
- Cap: 2 planted per team; 1 per player.
- Cooldown: 8 seconds per player.
- Lifetime: 30 seconds.
- No refund on expiry/destruction.

### MVP Effects

| Totem | Effect |
|---|---|
| Ward | Moderate mitigation in radius |
| Surge | Moderate movement/cooldown in radius |
| Well | Low capped healing |

No stacking by type: strongest active effect only.

### Boss Phase

- After 3s grace, manual planting blocked.
- Rift totem spawns every 15 seconds.
- Max 2 simultaneous.
- Anchors from predefined boss arena list, not physical random.
- Duration: 12 seconds.
- Positional/defensive opportunity, not free boss damage.

## Boss A1

### Initial Formula

```
Boss initial HP: 10,000
Damage threshold: 6,000 (60%)
Boss HP = 10,000 - (damage_red + damage_blue)
```

Each accepted damage:

1. Validate phase, range, team, hitbox, target, event ID.
2. Apply mitigation.
3. Clamp to remaining HP.
4. Subtract from boss.
5. Add same value to one team's meter.
6. Evaluate threshold.

Event ID:

```
match_id + tick + attacker_entity_id + attack_instance_id + hit_index + boss_id
```

Prevents rollback replay, duplicate packet, or double collision from double-counting.

### Resolution

| Case | Result |
|---|---|
| Red crosses threshold | Red wins |
| Blue crosses threshold | Blue wins |
| Both cross same tick | Server-stable event order |
| Boss dies before threshold | Higher meter wins |
| Tie at boss death | 10s overtime; first valid damage wins |
| Team disconnected 30s | Forfeit |
| Both teams forfeit | Draw |

### Required HUD

- Shared boss HP.
- Red damage meter.
- Blue damage meter.
- Threshold line visual.
- Current phase.
- Race-winning team.
- Rift totem state/duration.
- Reconnect status.

## Migration from OLD

| Feature | OLD Source | NEW Destination | Rule |
|---|---|---|---|
| Lobby visuals/teams | `scenes/connection/connection.tscn`, `waiting_room.gd` | `connection_menu.tscn`, `client/connection_manager.gd` | Reimplement UI and server validation; do not copy RPCs |
| Team enum | `scripts/constants.gd` | `common/team_id.gd` | Migrate concept |
| Bow mesh | `scenes/weapons/bow/bow.tscn` | Actor/loadout visual | Reuse asset |
| Bow charge UX | `floating_bow.gd` | Client/presentation | Reuse feel, not netcode |
| Arrow visual | `scenes/weapons/bow/arrow.tscn` | `ProjectileEntity.tscn` | Reuse mesh; reimplement simulation |
| Sword/staff assets | `scenes/weapons/sword`, `scenes/weapons/staff` | CharacterActor/loadouts | Reuse assets |
| Mob spawn zones | `debug_platform/mobs_spawn.gd` | Spawn service | Reference, rewrite |

### Prohibited from Direct Copy

- `noikar-old/multiplayer.gd`
- Arrow spawn RPCs.
- `floating_bow.gd` as authority source.
- `arrow.gd` as authoritative damage.
- `floating_weapon.gd` Area3D callbacks.
- `waiting_room.gd` client-mutated roster.

OLD uses classic RPC and `Time.get_ticks_msec()` names. For rollback this causes duplication and desync.

## Implementation Stages

### Stage 0 — Baseline and Test Harness
- Protect existing local changes.
- Open project and log current errors.
- Verify client, headless server, Noray, two clients, NetworkSimulator.
- Run existing tests or formalize replacement.
- Repair/remove stale tests with justification.

Known state:
- `python3 tests/verify_export_isolation.py` passes.
- `verify_headless_server.py --quick` fails (missing `dedicated_server` feature).
- GDScript tests extend `GutTest` but GUT not installed/configured.
- Windows export excludes `/addons/netfox/` though scenes require it.

### Stage 1 — Rollback Integrity
- Fix LogicComponent double-tick.
- Audit authority, snapshots, input frames, randomness, timers.
- Define stable spawn IDs.
- Fix `MultiplayerSpawner` to replicate needed metadata, not just position.

### Stage 2 — Match Foundation
- `TeamId`, `MatchRules`, `MatchState`, `MatchDirector`.
- Separate containers: `Players`, `Mobs`, `Minions`, `Souls`, `Totems`, `Projectiles`, `Boss`.
- Phases and state replication.
- No new weapons yet.

### Stage 3 — Lobby and Teams
- Port OLD lobby visuals.
- Team select, ready, team cap, host/start.
- Opposite team spawns.
- Late join policy: spectator until next match for MVP.

### Stage 4 — Action Combat
- Sword as data-driven melee.
- Bow as rollback-safe charge/release.
- Staff as data-driven projectile or AoE.
- Hit IDs and attribution.
- Explicit friendly-fire policy.

### Stage 5 — PvE Race
- Mob spawns by zone.
- Server-authoritative central gate.
- Reward tickets.
- Souls ground-drop.
- `souls | minion` choice.
- Minion caps and team targeting.

### Stage 6 — Totems
- Local preview.
- Server request/validation.
- Team soul bank.
- MVP effects and lifecycle.
- Placement/cost/spam abuse tests.

### Stage 7 — Boss A1
- Boss arena, teleport, shared HP.
- Team damage meters.
- Threshold and fallback.
- Temporary rift totems.
- Result and HUD.

### Stage 8 — Hardening
- 0/80/150ms latency.
- Packet loss, jitter, reconnect.
- Duplicate hit/reward regression.
- Same-tick gate tie.
- State hash/desync diagnostics.
- Headless dedicated-server export.

### Stage 9 — Balance
- Boss HP/threshold.
- Soul quantity.
- Reward choice timing.
- Minion strength/caps.
- Totem cost/lifetime.
- Boss rift timing and trailing-team bias.

## MVP Exit Criteria

- Two clients enter room, choose teams, ready up.
- Spawn at opposite corners.
- Both teams kill mobs without duplicate rewards.
- Souls fall to ground; not auto-credited to killer.
- Each kill offers `souls | minion` exactly once.
- Valid totems spend souls once; invalid placement does not spend.
- First gate team correctly teleports the other.
- Boss shows shared HP + two meters.
- Damage event counts exactly once.
- Threshold consistently determines winner.
- At 150ms latency, movement and attack startup remain responsive.
- Disconnect/reconnect does not duplicate damage, souls, minions, or totems.
