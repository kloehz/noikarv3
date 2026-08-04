extends GutTest

## Contract coverage for the shared boss health bar:
## - MatchManager._on_boss_damaged accumulates damage into the attacking
##   team's counter on the boss's ServerState, ignoring NONE attackers.
## - ServerState emits boss_damage_changed on either counter update.
## - BossHealthBar.set_damage clamps the percentages and stores them.

const MOBS_PER_STAGE: int = 10
const BOSS_SCALE: float = 3.0

var _manager: Node3D
var _director: MatchDirector
var _red_attacker: BaseEntity
var _blue_attacker: BaseEntity

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
	# Seed two attackers (one per team) so we can target them in damage calls.
	_red_attacker = _spawn_attacker(TeamId.RED)
	_blue_attacker = _spawn_attacker(TeamId.BLUE)
	await get_tree().process_frame

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _spawn_attacker(team: int) -> BaseEntity:
	var entity_scene := load("res://scenes/BaseEntity.tscn")
	var entity = entity_scene.instantiate()
	entity.name = str(100 + team)
	var server_state: ServerState = entity.get_node("ServerState")
	server_state.team_id = team
	_manager.get_node("Players").add_child(entity)
	return entity

func _boss_entity() -> Node:
	for child in _manager.get_node("Mobs").get_children():
		if String(child.name).begins_with("BOSS_"):
			return child
	return null

func _kill_all_red() -> void:
	for mob in _manager._mobs_of_team if "_mobs_of_team" in _manager else []:
		pass

func _spawn_boss_for_test() -> Node:
	_manager._spawn_boss()
	return _boss_entity()

func test_damage_from_red_player_accumulates_into_red_counter() -> void:
	var boss := _spawn_boss_for_test()
	var server_state: ServerState = boss.get_node("ServerState")
	_manager._on_boss_damaged(120, _red_attacker, boss, server_state)
	_manager._on_boss_damaged(30, _red_attacker, boss, server_state)
	assert_eq(server_state.red_damage_taken, 150)
	assert_eq(server_state.blue_damage_taken, 0)

func test_damage_from_blue_player_accumulates_into_blue_counter() -> void:
	var boss := _spawn_boss_for_test()
	var server_state: ServerState = boss.get_node("ServerState")
	_manager._on_boss_damaged(80, _blue_attacker, boss, server_state)
	assert_eq(server_state.blue_damage_taken, 80)
	assert_eq(server_state.red_damage_taken, 0)

func test_damage_from_unattributed_source_is_dropped() -> void:
	var boss := _spawn_boss_for_test()
	var server_state: ServerState = boss.get_node("ServerState")
	var unattributed := Node3D.new()
	add_child_autofree(unattributed)
	_manager._on_boss_damaged(50, unattributed, boss, server_state)
	assert_eq(server_state.red_damage_taken, 0)
	assert_eq(server_state.blue_damage_taken, 0)

func test_zero_or_negative_damage_does_not_count() -> void:
	var boss := _spawn_boss_for_test()
	var server_state: ServerState = boss.get_node("ServerState")
	_manager._on_boss_damaged(0, _red_attacker, boss, server_state)
	_manager._on_boss_damaged(-5, _red_attacker, boss, server_state)
	assert_eq(server_state.red_damage_taken, 0)

func test_boss_damage_changed_signal_fires_with_both_counters() -> void:
	var boss := _spawn_boss_for_test()
	var server_state: ServerState = boss.get_node("ServerState")
	var events: Array = []
	server_state.boss_damage_changed.connect(func(red: int, blue: int) -> void:
		events.append([red, blue]))
	_manager._on_boss_damaged(40, _red_attacker, boss, server_state)
	assert_eq(events.size(), 1)
	assert_eq(events[0], [40, 0])
	_manager._on_boss_damaged(15, _blue_attacker, boss, server_state)
	assert_eq(events.size(), 2)
	assert_eq(events[1], [40, 15])

func test_boss_health_bar_set_damage_clamps_percentages() -> void:
	var bar_scene := load("res://client/ui/BossHealthBar.gd")
	var bar = bar_scene.new()
	add_child_autofree(bar)
	# max_hp floors at 1 in the divisor, so 9999/100 -> 1.0; -50 -> 0.0.
	bar.set_damage(50, 50, 100)
	assert_eq(bar._red_pct, 0.5)
	assert_eq(bar._blue_pct, 0.5)
	bar.set_damage(200, -50, 100)
	assert_eq(bar._red_pct, 1.0)
	assert_eq(bar._blue_pct, 0.0)
	bar.set_damage(9999, 9999, 100)
	assert_eq(bar._red_pct, 1.0)
	assert_eq(bar._blue_pct, 1.0)
	# Zero max_hp still works (denominator floored to 1).
	bar.set_damage(5, 5, 0)
	assert_eq(bar._red_pct, 1.0)
	assert_eq(bar._blue_pct, 1.0)

func test_boss_model_scale_applies_to_body_and_hurtbox_shapes() -> void:
	var boss := _spawn_boss_for_test()
	var body_shape: CollisionShape3D = boss.get_node("CollisionShape3D") as CollisionShape3D
	var hurtbox_shape: CollisionShape3D = boss.get_node("HurtboxComponent/CollisionShape3D") as CollisionShape3D
	assert_eq(body_shape.scale, Vector3.ONE * BOSS_SCALE)
	assert_eq(hurtbox_shape.scale, Vector3.ONE * BOSS_SCALE)
	assert_almost_eq(body_shape.position.y, 0.9 * BOSS_SCALE, 0.001,
		"Scaled body collider keeps its feet aligned with the scaled model")
