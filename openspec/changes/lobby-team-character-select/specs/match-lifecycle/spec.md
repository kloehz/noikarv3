# Delta for match-lifecycle

## MODIFIED Requirements

### Requirement: Phase Model and Transition Map

The match MUST have exactly the phases LOBBY, CHARACTER_SELECT, COUNTDOWN, ROUND_SETUP, PVE_RACE, BOSS_LOCK, BOSS_DEPLOY, BOSS_A1, RESULT, POST_MATCH, with only these transitions:

| From → To | Driver |
|---|---|
| LOBBY → CHARACTER_SELECT | host starts after all members are lobby-ready |
| CHARACTER_SELECT → LOBBY | frozen-roster disconnect or 30-second deadline |
| CHARACTER_SELECT → COUNTDOWN | every frozen-roster member is selection-ready |
| COUNTDOWN → ROUND_SETUP | timer: `countdown_sec` |
| ROUND_SETUP → PVE_RACE | event: match_seed assigned + initial spawns done |
| PVE_RACE → BOSS_LOCK | event: stub condition |
| BOSS_LOCK → BOSS_DEPLOY | event: stub condition |
| BOSS_DEPLOY → BOSS_A1 | timer: `boss_deploy_countdown_sec` |
| BOSS_A1 → RESULT | event: stub condition |
| RESULT → POST_MATCH | timer: `result_display_sec` |
| POST_MATCH → LOBBY | event: reset complete |

Timer durations MUST come from MatchRules; the selection duration MUST be 30 seconds in ticks. (Previously: LOBBY transitioned directly to COUNTDOWN on a minimum-roster stub.)

#### Scenario: Full phase walk

- GIVEN a headless 2-team server with stub hooks
- WHEN a completed frozen roster selects characters and a match runs to completion
- THEN phases occur in exactly the mapped order

#### Scenario: Selection timeout

- GIVEN CHARACTER_SELECT with an incomplete frozen roster
- WHEN its deadline tick is reached
- THEN the phase returns to LOBBY without COUNTDOWN or spawning

### Requirement: Behavior-Preserving Spawn Routing

Entities MUST spawn under typed containers (Players, Mobs, Minions, Souls, Totems, Boss, plus existing Projectiles), each with its own MultiplayerSpawner (pattern: scenes/main.tscn:21-29). Existing solo/free-play flows MUST work unchanged, and entity name-prefix conventions MUST be preserved — group detection keys off them (BaseEntity.gd:47-52). No player or gameplay entity MUST spawn before every frozen-roster member is selection-ready and the server enters the launch path.

(Previously: Spawn routing had no pre-launch selection gate.)

#### Scenario: Solo/free play unchanged

- GIVEN a single client connecting as today
- WHEN they spawn and play
- THEN spawning, soul, totem, and mob flows behave identically to pre-change

#### Scenario: Group detection intact

- GIVEN entities spawned under the new containers
- WHEN BaseEntity assigns groups
- THEN group names match pre-change values

#### Scenario: Pre-launch spawn gate

- GIVEN members are in LOBBY or incomplete CHARACTER_SELECT
- WHEN the scene tree is inspected
- THEN no player entity exists
