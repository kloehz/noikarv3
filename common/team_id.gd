# res://common/team_id.gd
## Global team identity type for PvPvE matches.
## Serialized as int so it replicates natively through netfox state synchronizers.
## All helpers are pure and deterministic: no side effects, no state, no RNG.
class_name TeamId

enum Value { NONE, RED, BLUE }

## Flat aliases so consumers can use TeamId.NONE as well as TeamId.Value.NONE.
const NONE := Value.NONE
const RED := Value.RED
const BLUE := Value.BLUE

const _COLORS := {
	Value.NONE: Color(0.6, 0.6, 0.6),
	Value.RED: Color(0.85, 0.2, 0.2),
	Value.BLUE: Color(0.2, 0.45, 0.9),
}

const _NAMES := {
	Value.NONE: "None",
	Value.RED: "Red",
	Value.BLUE: "Blue",
}

## Returns the opposing team. NONE has no opposite and returns NONE.
static func opposite(team: Value) -> Value:
	match team:
		Value.RED:
			return Value.BLUE
		Value.BLUE:
			return Value.RED
		_:
			return Value.NONE

## Returns the human-readable display name for a team.
static func display_name(team: Value) -> String:
	return _NAMES.get(team, "None")

## Returns the display color for a team. NONE maps to neutral gray.
static func color(team: Value) -> Color:
	return _COLORS.get(team, _COLORS[Value.NONE])
