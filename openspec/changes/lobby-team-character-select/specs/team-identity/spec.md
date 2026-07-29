# Delta for team-identity

## MODIFIED Requirements

### Requirement: Deterministic Team Assignment

The server MUST assign teams only during LOBBY: sort authenticated connected peer IDs ascending, alternate RED/BLUE (first sorted peer → RED), and record each assignment in a server-side roster. It MUST enforce the configured per-team capacity, recompute assignments after LOBBY churn, and freeze the resulting roster when CHARACTER_SELECT begins. The same peer-ID set MUST yield the same assignment regardless of join order. (Previously: Assignment used connected peers during LOBBY but did not define authenticated capacity or selection-roster freezing.)

#### Scenario: Same roster, different join orders

- GIVEN peers {7, 11, 42, 99} connect in different orders across two runs
- WHEN LOBBY assignment runs
- THEN both runs produce 7→RED, 11→BLUE, 42→RED, 99→BLUE

#### Scenario: Odd roster sizes RED

- GIVEN an odd number of connected peers
- WHEN assignment runs
- THEN RED has exactly one more player than BLUE

#### Scenario: Team capacity is full

- GIVEN each team has reached its configured capacity
- WHEN another authenticated peer requests membership
- THEN the server rejects membership without changing assignments

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
| character_select_sec | 30.0 |

Stage 2 consumes only phase timings and team caps; remaining fields are schema-complete so later stages do not reshape the resource. The server MUST convert `character_select_sec` to ticks for its deadline. (Previously: MatchRules had no character-selection duration.)

#### Scenario: Defaults match locked values

- GIVEN the default rules resource is loaded headless
- WHEN every field is read
- THEN each value equals the table above

### Requirement: Replicated Per-Entity Team

Every entity's server-dictated state MUST carry a replicated `team_id` following the `ServerState` + `StateSynchronizer` pattern (common/components/ServerState.gd:63-85), defaulting to `NONE`. Only the server MUST write it. Player entities MUST reflect the frozen roster assignment only after launch; no player entity exists during LOBBY or CHARACTER_SELECT. Mobs, totems, and souls stay `NONE` at this stage. (Previously: Player entities reflected LOBBY assignment without a pre-launch spawn gate.)

#### Scenario: Spawned player shows assigned team

- GIVEN peer 42 is frozen as BLUE and gameplay launches
- WHEN its player entity spawns and state replicates
- THEN every client's copy reads `team_id = BLUE`

#### Scenario: Pre-assignment default

- GIVEN any entity before LOBBY assignment completes
- WHEN its `team_id` is read
- THEN it equals NONE

#### Scenario: Selection has no player entity

- GIVEN a frozen roster is in CHARACTER_SELECT
- WHEN entity state is inspected
- THEN no player entity exposes a team assignment
