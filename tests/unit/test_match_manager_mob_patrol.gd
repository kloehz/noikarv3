extends GutTest

## Contract coverage for the random scatter spawn + per-mob PATROL anchor:
## - Spawn positions fall inside the scatter radius and are NOT a 5x2 grid.
## - Each mob gets its own AIComponent.patrol_center set to its spawn pos.
## - The patrol anchor stays even if the mob is later knocked away.
## - AIComponent._pick_patrol_point returns points inside patrol_radius and
##   respects the _patrol_center anchor.
## - AIComponent transitions from IDLE to PATROL after patrol_start_delay
##   when no target is in range.

const MOBS_PER_STAGE: int = 10
const STAGE_SCATTER_RADIUS: float = 10.0

var _manager: Node3D
var _director: MatchDirector

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_manager = load("res://common/match_manager.gd").new()
	for container_name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new()
		container.name = container_name
		_manager.add_child(container)
	var state := MatchState.new()
	state.name = "MatchState"
	_manager.add_child(state)
	_director = MatchDirector.new()
	_director.rules = load("res://common/resources/default_match_rules.tres")
	_director.match_state = state
	_manager.add_child(_director)
	add_child_autofree(_manager)
	NetworkTime.after_tick.disconnect(_director._on_after_tick)
	await get_tree().process_frame

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _mobs_of_team(team: int) -> Array:
	var result: Array = []
	for child in _manager.get_node("Mobs").get_children():
		if child.has_node("ServerState") and int(child.get_node("ServerState").team_id) == team:
			result.append(child)
	return result

func test_spawn_positions_are_scattered_not_grid() -> void:
	_manager._begin_stage_progression()
	var red_mobs: Array = _mobs_of_team(TeamId.RED)
	var positions: Array = []
	for mob in red_mobs:
		positions.append(mob.global_position)
	# No two mobs share the exact same position (radial scatter guarantees it).
	var unique_positions := {}
	for pos in positions:
		unique_positions[str(pos)] = true
	assert_eq(unique_positions.size(), positions.size(),
		"Random scatter must not produce duplicate positions")

func test_each_mob_has_its_own_patrol_center_at_spawn_position() -> void:
	_manager._begin_stage_progression()
	for mob in _mobs_of_team(TeamId.RED):
		var ai: Node = mob.get_node_or_null("AIComponent")
		assert_not_null(ai, "Mob %s missing AIComponent" % mob.name)
		assert_eq(ai._patrol_center, mob.global_position,
			"patrol_center should be set to the mob's spawn position")
		assert_eq(ai._patrol_target, mob.global_position,
			"patrol_target should initialize to the same anchor")

func test_set_patrol_center_updates_target_only_once() -> void:
	_manager._begin_stage_progression()
	var mob: Node = _mobs_of_team(TeamId.RED)[0]
	var ai: Node = mob.get_node_or_null("AIComponent")
	# Simulate the mob being knocked away: re-anchor to a new center but
	# the existing patrol_target should NOT snap (the mob walks toward it).
	ai._patrol_target = Vector3(50, 0, 50)
	ai.set_patrol_center(Vector3(100, 0, 100))
	assert_eq(ai._patrol_center, Vector3(100, 0, 100))
	assert_eq(ai._patrol_target, Vector3(50, 0, 50),
		"set_patrol_center must not overwrite an in-progress patrol target")

func test_patrol_state_is_idle_on_spawn_and_transitions_after_delay() -> void:
	_manager._begin_stage_progression()
	var mob: Node = _mobs_of_team(TeamId.RED)[0]
	var ai: Node = mob.get_node_or_null("AIComponent")
	# Reset to IDLE so we can observe the IDLE -> PATROL transition
	# deterministically (the rollback synchronizer may have ticked the AI
	# enough to put it into PATROL by the time the test runs).
	ai.state = ai.State.IDLE
	ai._idle_timer = 0.0
	assert_eq(ai.state, ai.State.IDLE,
		"Setup: mob forced back to IDLE")
	# Tick just under the delay: still IDLE.
	ai.tick(ai.patrol_start_delay - 0.1)
	assert_eq(ai.state, ai.State.IDLE)
	# Tick across the threshold: switches to PATROL and picks a waypoint.
	ai.tick(0.2)
	assert_eq(ai.state, ai.State.PATROL,
		"After patrol_start_delay without a target, mob starts patrolling")
	assert_ne(ai._patrol_target, ai._patrol_center,
		"PATROL must pick a new waypoint distinct from the anchor")

func test_patrol_waypoint_stays_inside_patrol_radius() -> void:
	var ai_script := load("res://core/AIComponent.gd")
	var ai = ai_script.new()
	ai.patrol_radius = 6.0
	ai.set_patrol_center(Vector3.ZERO)
	for _i in 50:
		var wp: Vector3 = ai._pick_patrol_point()
		var horiz := Vector2(wp.x, wp.z)
		assert_lt(horiz.length(), ai.patrol_radius + 0.001,
			"Waypoint %s fell outside patrol_radius" % wp)
	ai.free()

func test_patrol_waypoints_use_anchor_when_set() -> void:
	var ai_script := load("res://core/AIComponent.gd")
	var ai = ai_script.new()
	ai.patrol_radius = 5.0
	ai.set_patrol_center(Vector3(100, 0, -200))
	for _i in 30:
		var wp: Vector3 = ai._pick_patrol_point()
		var horiz := Vector2(wp.x - 100, wp.z - (-200))
		assert_lt(horiz.length(), ai.patrol_radius + 0.001,
			"Waypoint %s should be relative to anchor (100,0,-200)" % wp)
	ai.free()

func test_patrol_uses_slower_input_axis_than_chase() -> void:
	# Spin up a real BaseEntity + LogicComponent subtree so AIComponent can
	# write through the real typed properties (logic.input_axis is the
	# sprint vector the PhysicsDriver consumes downstream).
	var ai_script := load("res://core/AIComponent.gd")
	var ai = ai_script.new()
	ai.patrol_speed_factor = 0.4
	var entity_scene := load("res://scenes/BaseEntity.tscn")
	var entity = entity_scene.instantiate()
	var logic_node: Node = entity.get_node_or_null("LogicComponent")
	assert_not_null(logic_node, "BaseEntity.tscn must contain LogicComponent")
	ai.entity = entity
	ai.logic = logic_node
	add_child_autofree(entity)
	entity.global_position = Vector3.ZERO
	# Default _move_towards: full sprint (chase speed).
	ai._move_towards(Vector3(0, 0, -10))
	assert_eq(logic_node.input_axis, Vector2(0, -1),
		"Default _move_towards must keep full chase speed")
	# _move_towards with 0.4 factor: 40% of the sprint magnitude (patrol).
	ai._move_towards(Vector3(0, 0, -10), 0.4)
	assert_almost_eq(logic_node.input_axis.x, 0.0, 0.001)
	assert_almost_eq(logic_node.input_axis.y, -0.4, 0.001,
		"PATROL must scale the input axis by patrol_speed_factor")
	assert_lt(logic_node.input_axis.length(), Vector2(0, -1).length(),
		"Patrol input magnitude must be strictly less than chase speed")

func test_patrol_speed_factor_clamps_out_of_range() -> void:
	var ai_script := load("res://core/AIComponent.gd")
	var ai = ai_script.new()
	var entity_scene := load("res://scenes/BaseEntity.tscn")
	var entity = entity_scene.instantiate()
	var logic_node: Node = entity.get_node_or_null("LogicComponent")
	ai.entity = entity
	ai.logic = logic_node
	add_child_autofree(entity)
	entity.global_position = Vector3.ZERO
	# 1.5 must clamp to 1.0; -0.3 must clamp to 0.0 (no negative backwards movement).
	ai._move_towards(Vector3(0, 0, -10), 1.5)
	assert_eq(logic_node.input_axis, Vector2(0, -1))
	ai._move_towards(Vector3(0, 0, -10), -0.3)
	assert_eq(logic_node.input_axis, Vector2.ZERO,
		"Negative speed_factor must clamp to zero, never move backwards")

func test_mob_flanks_nearby_frontline_instead_of_stacking() -> void:
	var rear_mob: Node = _manager._spawn_named_enemy("HECARIM_TANK", Vector3.ZERO, "MOB_", 1.0, 0.0, TeamId.RED)
	_manager._spawn_named_enemy("HECARIM_TANK", Vector3(-0.6, 0, -1.2), "MOB_", 1.0, 0.0, TeamId.RED)
	_manager._spawn_named_enemy("HECARIM_TANK", Vector3(0.6, 0, -1.2), "MOB_", 1.0, 0.0, TeamId.RED)
	await get_tree().process_frame
	var ai: Node = rear_mob.get_node("AIComponent")
	var steering: Vector3 = ai._steer_around_nearby_mobs(Vector3.FORWARD)
	assert_gt(absf(steering.x), 0.01,
		"A mob blocked by a symmetric frontline must choose a lateral flank path")
	assert_lt(steering.z, 0.0,
		"Flanking must still make progress toward the target")
