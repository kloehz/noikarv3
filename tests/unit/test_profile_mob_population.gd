extends GutTest

const MatchManagerScript = preload("res://common/match_manager.gd")
const FIXED_ENV := {
	"NOIKAR_PERF_PROBE": "1",
	"NOIKAR_PROFILE_FIXED_POPULATION": "1",
	"NOIKAR_PROFILE_MOB_COUNT": "20",
	"NOIKAR_BACKEND_URL": "http://127.0.0.1:18090",
}

class RecordingMatchManager:
	extends MatchManagerScript

	var spawn_calls: Array[Dictionary] = []
	var soul_spawns: int = 0

	func _spawn_named_enemy(enemy_type: String, pos: Vector3, prefix: String, actor_scale: float = 1.0, spawn_grace_duration: float = 0.0, team: int = TeamId.NONE) -> Node:
		spawn_calls.append({
			"enemy_type": enemy_type,
			"position": pos,
			"prefix": prefix,
			"actor_scale": actor_scale,
			"spawn_grace_duration": spawn_grace_duration,
			"team": team,
		})
		var mob := Node3D.new()
		mob.name = "MOB_TEST_%04d" % spawn_calls.size()
		mob.position = pos
		var server_state := ServerState.new()
		server_state.name = "ServerState"
		server_state.team_id = team
		mob.add_child(server_state)
		get_node("Mobs").add_child(mob)
		return mob

	func _spawn_soul(_pos: Vector3, _can_respawn_elite: bool = true) -> void:
		soul_spawns += 1

var _manager: RecordingMatchManager
var _saved_env: Dictionary = {}
var _saved_peer: MultiplayerPeer

func before_each() -> void:
	_saved_peer = multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_capture_env(FIXED_ENV.keys())
	_clear_profile_env()
	_manager = _new_manager()

func after_each() -> void:
	_restore_env()
	multiplayer.multiplayer_peer = _saved_peer

func _new_manager() -> RecordingMatchManager:
	var manager := RecordingMatchManager.new()
	for container_name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new()
		container.name = container_name
		manager.add_child(container)
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	var map := Node3D.new()
	map.name = "Map"
	map.add_child(spawn_points)
	manager.add_child(map)
	_add_marker(spawn_points, "TeamRedMobStage1", Vector3(10, 0, 20))
	_add_marker(spawn_points, "TeamBlueMobStage1", Vector3(-10, 0, -20))
	add_child_autofree(manager)
	return manager

func _add_marker(parent: Node, marker_name: String, position: Vector3) -> void:
	var marker := Marker3D.new()
	marker.name = marker_name
	marker.position = position
	parent.add_child(marker)

func _capture_env(keys: Array) -> void:
	_saved_env.clear()
	for key in keys:
		_saved_env[key] = {"had": OS.has_environment(key), "value": OS.get_environment(key)}

func _restore_env() -> void:
	for key in _saved_env.keys():
		if bool(_saved_env[key]["had"]):
			OS.set_environment(key, str(_saved_env[key]["value"]))
		elif OS.has_method("unset_environment"):
			OS.unset_environment(key)
		else:
			OS.set_environment(key, "")

func _clear_profile_env() -> void:
	for key in FIXED_ENV.keys():
		if OS.has_method("unset_environment"):
			OS.unset_environment(key)
		else:
			OS.set_environment(key, "")

func _enable_fixed_population(count: int, backend_url: String = "http://127.0.0.1:18090") -> void:
	for key in FIXED_ENV.keys():
		OS.set_environment(key, str(FIXED_ENV[key]))
	OS.set_environment("NOIKAR_PROFILE_MOB_COUNT", str(count))
	OS.set_environment("NOIKAR_BACKEND_URL", backend_url)

func test_production_default_spawns_normal_red_and_blue_stage_1() -> void:
	_manager._begin_stage_progression()
	assert_eq(_manager.spawn_calls.size(), 20)
	assert_eq(_manager._wave_alive_by_team[TeamId.RED], 10)
	assert_eq(_manager._wave_alive_by_team[TeamId.BLUE], 10)
	assert_eq(_manager._stage_progression_active_by_team[TeamId.RED], true)
	assert_eq(_manager._stage_progression_active_by_team[TeamId.BLUE], true)

func test_fixed_population_requires_all_guards_and_rejects_invalid_count_and_evil_url() -> void:
	_enable_fixed_population(20)
	OS.set_environment("NOIKAR_PROFILE_FIXED_POPULATION", "0")
	_manager._begin_stage_progression()
	assert_eq(_manager.spawn_calls.size(), 20, "missing explicit mode keeps normal waves")

	_manager = _new_manager()
	_enable_fixed_population(2)
	_manager._begin_stage_progression()
	assert_eq(_manager.spawn_calls.size(), 20, "invalid count keeps normal waves")

	_manager = _new_manager()
	_enable_fixed_population(20, "http://127.0.0.1:18090.evil")
	_manager._begin_stage_progression()
	assert_eq(_manager.spawn_calls.size(), 20, "prefix URL match must not activate profiling")

func test_fixed_population_counts_spawn_exact_real_factory_calls() -> void:
	for count in [0, 1, 20]:
		_manager = _new_manager()
		_enable_fixed_population(count)
		_manager._begin_stage_progression()
		assert_eq(_manager.spawn_calls.size(), count)
		assert_eq(_manager.get_node("Mobs").get_child_count(), count)
		assert_eq(_manager._wave_alive_by_team[TeamId.RED], 0)
		assert_eq(_manager._wave_alive_by_team[TeamId.BLUE], 0)
		assert_eq(_manager._stage_progression_active_by_team[TeamId.RED], false)
		assert_eq(_manager._stage_progression_active_by_team[TeamId.BLUE], false)

func test_fixed_population_spawn_prefix_is_deterministic_between_one_and_twenty() -> void:
	_enable_fixed_population(1)
	_manager._begin_stage_progression()
	var first_one: Dictionary = _manager.spawn_calls[0]

	_manager = _new_manager()
	_enable_fixed_population(20)
	_manager._begin_stage_progression()
	var first_twenty: Dictionary = _manager.spawn_calls[0]

	assert_eq(first_one["enemy_type"], first_twenty["enemy_type"])
	assert_eq(first_one["position"], first_twenty["position"])
	assert_eq(first_one["team"], first_twenty["team"])
	assert_eq(first_one["enemy_type"], "HECARIM_TANK")
	assert_eq(first_one["team"], TeamId.RED)

func test_fixed_population_death_does_not_advance_stage_or_spawn_boss() -> void:
	_enable_fixed_population(1)
	_manager._begin_stage_progression()
	var mob := _manager.get_node("Mobs").get_child(0) as Node3D
	_manager._on_entity_died(mob)
	await get_tree().process_frame
	assert_eq(_manager._next_stage_index_by_team[TeamId.RED], 0)
	assert_eq(_manager._next_stage_index_by_team[TeamId.BLUE], 0)
	assert_eq(_manager._boss_spawned, false)
	assert_eq(_manager.spawn_calls.size(), 1, "no replacement or next wave")

func test_new_normal_match_after_fixed_population_clears_benchmark_state() -> void:
	_enable_fixed_population(1)
	_manager._begin_stage_progression()
	assert_eq(_manager.spawn_calls.size(), 1)

	_clear_profile_env()
	_manager._begin_stage_progression()
	assert_eq(_manager.spawn_calls.size(), 21)
	assert_eq(_manager._stage_progression_active_by_team[TeamId.RED], true)
	assert_eq(_manager._stage_progression_active_by_team[TeamId.BLUE], true)
	assert_eq(_manager._wave_alive_by_team[TeamId.RED], 10)
	assert_eq(_manager._wave_alive_by_team[TeamId.BLUE], 10)
