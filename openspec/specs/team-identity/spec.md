# Delta for team-identity

New capability: typed team identity, deterministic server-side assignment, and schema-complete match rules data. Ownership: server owns assignment and registries; clients read replicated team data only.

## ADDED Requirements

### Requirement: TeamId Identity Type

The system MUST provide a globally named `TeamId` type with an enum of exactly `NONE`, `RED`, `BLUE` (NONE = zero value), serialized as int so it replicates natively through netfox state synchronizers. It MUST provide pure, deterministic helpers (opposite team, display name, team color) with no side effects.

#### Scenario: Helper purity and zero value

- GIVEN a `TeamId` value RED and a default-initialized variable
- WHEN helpers are queried repeatedly on any peer
- THEN results are identical every call with no mutation
- AND the default variable equals NONE

### Requirement: Deterministic Team Assignment

The server MUST assign teams only during the LOBBY phase: sort connected peer ids ascending, alternate RED/BLUE (first sorted peer → RED), recorded in a server-side roster (peer id → team). The same peer-id set MUST yield the same assignment regardless of join order.

#### Scenario: Same roster, different join orders

- GIVEN peers {7, 11, 42, 99} connect in different orders across two runs
- WHEN LOBBY assignment runs
- THEN both runs produce 7→RED, 11→BLUE, 42→RED, 99→BLUE

#### Scenario: Odd roster sizes RED

- GIVEN an odd number of connected peers
- WHEN assignment runs
- THEN RED has exactly one more player than BLUE

### Requirement: Replicated Per-Entity Team

Every entity's server-dictated state MUST carry a replicated `team_id` following the `ServerState` + `StateSynchronizer` pattern (common/components/ServerState.gd:63-85), defaulting to `NONE`. Only the server MUST write it. Player entities MUST reflect the roster assignment; mobs, totems, and souls stay `NONE` at this stage.

#### Scenario: Spawned player shows assigned team

- GIVEN peer 42 assigned BLUE during LOBBY
- WHEN its player entity spawns and state replicates
- THEN every client's copy reads `team_id = BLUE`

#### Scenario: Pre-assignment default

- GIVEN any entity before LOBBY assignment completes
- WHEN its `team_id` is read
- THEN it equals NONE

### Requirement: MatchRules Resource

The system MUST ship a `MatchRules` Resource and a default `.tres` with the locked roadmap values, readable headless:

| Field | Locked value |
|---|---|
| boss_max_hp / boss_damage_threshold | 10000 / 6000 (60%) |
| souls_per_mob_drop | 2 |
| reward_choice_window_sec | 1.5 (fallback DROP_SOULS) |
| minion_cap_per_team / minion_cap_per_type | 3 / 1 |
| totem_soul_cost / cap_per_team / cap_per_player | 4 / 2 / 1 |
| totem_cooldown_sec / lifetime_sec / min_separation_m | 8.0 / 30.0 / 6.0 |
| max_players_per_team | 3 |
| countdown_sec / boss_deploy_countdown_sec | 3.0 / 3.0 |
| result_display_sec / forfeit_disconnect_sec | 10.0 / 30.0 |

Stage 2 consumes only phase timings and team caps; remaining fields are schema-complete so later stages do not reshape the resource.

#### Scenario: Defaults match locked values

- GIVEN the default rules resource is loaded headless
- WHEN every field is read
- THEN each value equals the table above

### Requirement: Team Registry Structure

The server MUST maintain per-team registries (team → spawn ids) in deterministic spawn-sequence order — never dictionary iteration order — with register/unregister functions. Stage 2 MUST NOT enforce caps.

#### Scenario: Deterministic registry order

- GIVEN entities registered for RED in spawn order s1, s2, s3
- WHEN the registry is enumerated on any run
- THEN the order is exactly s1, s2, s3

### Requirement: Explicit Exclusions

This capability MUST NOT implement soul team bank, totem planting/cost rules, minion spawning, kill-reward choice, team-select UI, or cap enforcement.

#### Scenario: Out-of-scope logic absent

- GIVEN the change is applied
- WHEN gameplay code is inspected
- THEN no soul-bank, totem-cost, minion-cap, or team-select logic exists
