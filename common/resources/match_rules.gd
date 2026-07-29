# res://common/resources/match_rules.gd
## Schema-complete match rules data for PvPvE matches (Roadmap Stage 2).
## Pure data resource: no logic beyond the seconds-to-ticks conversion helper.
## Stage 2 consumes only phase timings and team caps; remaining fields are
## schema-complete so later stages do not reshape the resource.
class_name MatchRules
extends Resource

## --- Boss ---
@export var boss_max_hp: int = 10000
## Damage dealt to the boss that ends the PVE race phase (60% of max HP).
@export var boss_damage_threshold: int = 6000

## --- Souls ---
## Souls dropped per mob kill.
@export var souls_per_mob_drop: int = 2

## --- Kill reward choice ---
## Window (seconds) to choose a kill reward before fallback DROP_SOULS applies.
@export var reward_choice_window_sec: float = 1.5

## --- Minions ---
@export var minion_cap_per_team: int = 3
@export var minion_cap_per_type: int = 1

## --- Totems ---
@export var totem_soul_cost: int = 4
@export var totem_cap_per_team: int = 2
@export var totem_cap_per_player: int = 1
@export var totem_cooldown_sec: float = 8.0
@export var totem_lifetime_sec: float = 30.0
@export var totem_min_separation_m: float = 6.0

## --- Teams ---
@export var max_players_per_team: int = 3

## --- Phase timings ---
@export var countdown_sec: float = 3.0
@export var boss_deploy_countdown_sec: float = 3.0
@export var result_display_sec: float = 10.0
@export var forfeit_disconnect_sec: float = 30.0
@export var character_select_sec: float = 30.0

## Converts a duration in seconds to simulation ticks.
## Convention: roundi(seconds * NetworkTime.tickrate), minimum 1 tick.
## Rounding absorbs float error; one helper = one convention.
func seconds_to_ticks(seconds: float) -> int:
	return maxi(1, roundi(seconds * NetworkTime.tickrate))
