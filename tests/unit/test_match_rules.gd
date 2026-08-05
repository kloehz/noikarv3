# tests/unit/test_match_rules.gd
extends GutTest

## Unit tests for MatchRules: locked roadmap defaults and seconds_to_ticks convention.

var _rules: MatchRules

func before_each() -> void:
	_rules = load("res://common/resources/default_match_rules.tres")

## Test: Default resource loads headless as a MatchRules
func test_default_resource_loads() -> void:
	assert_not_null(_rules, "default_match_rules.tres must load headless")
	assert_true(_rules is MatchRules, "default_match_rules.tres must be a MatchRules")

## Test: Boss values match the locked roadmap table
func test_boss_values() -> void:
	assert_eq(_rules.boss_max_hp, 10000)
	assert_eq(_rules.boss_damage_threshold, 6000)
	assert_eq(_rules.boss_damage_threshold, int(_rules.boss_max_hp * 0.6),
		"Threshold must be 60% of boss max HP")

## Test: Soul and reward-choice values match the locked table
func test_soul_and_reward_values() -> void:
	assert_eq(_rules.souls_per_mob_drop, 2)
	assert_eq(_rules.reward_choice_window_sec, 1.5)

## Test: Minion caps match the locked table
func test_minion_caps() -> void:
	assert_eq(_rules.minion_cap_per_team, 3)
	assert_eq(_rules.minion_cap_per_type, 1)

## Test: Totem values match the locked table
func test_totem_values() -> void:
	assert_eq(_rules.totem_soul_cost, 4)
	assert_eq(_rules.totem_cap_per_team, 2)
	assert_eq(_rules.totem_cap_per_player, 1)
	assert_eq(_rules.totem_cooldown_sec, 8.0)
	assert_eq(_rules.totem_lifetime_sec, 30.0)
	assert_eq(_rules.totem_min_separation_m, 6.0)

## Test: Team and phase-timing values match the locked table
func test_team_and_phase_values() -> void:
	assert_eq(_rules.max_players_per_team, 3)
	assert_eq(_rules.countdown_sec, 3.0)
	assert_eq(_rules.boss_deploy_countdown_sec, 3.0)
	assert_eq(_rules.result_display_sec, 10.0)
	assert_eq(_rules.forfeit_disconnect_sec, 30.0)
	assert_eq(_rules.character_select_sec, 30.0)

## Test: seconds_to_ticks converts at the configured network tickrate
func test_seconds_to_ticks_conversion() -> void:
	var rate := NetworkTime.tickrate
	assert_eq(_rules.seconds_to_ticks(3.0), 3 * rate)
	assert_eq(_rules.seconds_to_ticks(1.5), roundi(1.5 * rate))
	assert_eq(_rules.seconds_to_ticks(10.0), 10 * rate)
	assert_eq(_rules.seconds_to_ticks(_rules.character_select_sec), roundi(_rules.character_select_sec * rate))

## Test: seconds_to_ticks rounds to the nearest tick
func test_seconds_to_ticks_rounding() -> void:
	var rate := NetworkTime.tickrate
	assert_eq(_rules.seconds_to_ticks(0.025), maxi(1, roundi(0.025 * rate)))
	assert_eq(_rules.seconds_to_ticks(0.01), maxi(1, roundi(0.01 * rate)))

## Test: seconds_to_ticks never returns less than 1 tick
func test_seconds_to_ticks_minimum_one() -> void:
	assert_eq(_rules.seconds_to_ticks(0.0), 1)
	assert_eq(_rules.seconds_to_ticks(0.001), 1)
