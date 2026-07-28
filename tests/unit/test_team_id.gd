# tests/unit/test_team_id.gd
extends GutTest

## Unit tests for TeamId: enum zero value and helper purity/determinism.

## Test: Default-initialized TeamId variable equals NONE (zero value)
func test_default_value_is_none() -> void:
	var team: TeamId.Value
	assert_eq(team, TeamId.NONE, "Default TeamId.Value must be NONE (zero value)")

## Test: Enum values are NONE=0, RED=1, BLUE=2
func test_enum_values() -> void:
	assert_eq(TeamId.NONE, 0)
	assert_eq(TeamId.RED, 1)
	assert_eq(TeamId.BLUE, 2)

## Test: opposite() maps RED<->BLUE and NONE->NONE
func test_opposite() -> void:
	assert_eq(TeamId.opposite(TeamId.RED), TeamId.BLUE)
	assert_eq(TeamId.opposite(TeamId.BLUE), TeamId.RED)
	assert_eq(TeamId.opposite(TeamId.NONE), TeamId.NONE)

## Test: Helpers are pure — repeated calls return identical results
func test_helper_purity() -> void:
	for team: TeamId.Value in [TeamId.NONE, TeamId.RED, TeamId.BLUE]:
		assert_eq(TeamId.opposite(team), TeamId.opposite(team))
		assert_eq(TeamId.display_name(team), TeamId.display_name(team))
		assert_eq(TeamId.color(team), TeamId.color(team))

## Test: display_name returns stable names for each team
func test_display_name() -> void:
	assert_eq(TeamId.display_name(TeamId.RED), "Red")
	assert_eq(TeamId.display_name(TeamId.BLUE), "Blue")
	assert_eq(TeamId.display_name(TeamId.NONE), "None")

## Test: color returns distinct colors for RED and BLUE, gray for NONE
func test_color() -> void:
	assert_ne(TeamId.color(TeamId.RED), TeamId.color(TeamId.BLUE),
		"RED and BLUE must have distinct colors")
	assert_eq(TeamId.color(TeamId.NONE), Color(0.6, 0.6, 0.6))
