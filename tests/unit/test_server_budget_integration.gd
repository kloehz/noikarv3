extends GutTest

# Pending full-project GUT verification: these exercise actual component methods,
# with only entity presentation/spawn setup and perception distance isolated.
class BudgetBody:
	extends BaseEntity
	func _enter_tree() -> void:
		pass
	func _ready() -> void:
		pass

class BudgetBrain:
	extends AIComponent
	var nearest_sq: float = 70.0 * 70.0
	var perception_calls: int = 0
	func _ready() -> void:
		set_process(false)
	func _nearest_actor_dist_sq() -> float:
		perception_calls += 1
		return nearest_sq

class MovementDriver:
	extends Node
	signal drove_tick
	var logic: LogicComponent
	func _physics_process(_delta: float) -> void:
		set_physics_process(false)
		logic._apply_npc_movement(1.0 / 30.0)
		drove_tick.emit()

var _previous_peer: MultiplayerPeer

func before_each() -> void:
	_previous_peer = multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_each() -> void:
	multiplayer.multiplayer_peer = _previous_peer

func _fixture(entity_name: String = "MOB_BUDGET") -> BudgetBody:
	var body := BudgetBody.new()
	body.name = entity_name
	body.add_to_group(&"mobs")
	var server := ServerState.new()
	server.name = "ServerState"
	body.add_child(server)
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 2.0
	collision.shape = capsule
	body.add_child(collision)
	var logic := LogicComponent.new()
	logic.name = "LogicComponent"
	body.add_child(logic)
	var brain := BudgetBrain.new()
	brain.name = "AIComponent"
	brain.entity = body
	brain.logic = logic
	brain._is_mob = true
	brain._faction_cached = true
	brain._patrol_start_delay = 100.0
	brain.decision_budget_enabled = true
	brain.distant_dormancy_enabled = true
	body.add_child(brain)
	var players := Node3D.new()
	players.name = "Players"
	body.add_child(players)
	brain._players_node = players
	add_child_autofree(body)
	return body

func test_perception_budget_counts_at_30_and_60hz_and_legacy_fallback() -> void:
	for tickrate in [30, 60]:
		var body := _fixture("MOB_RATE_%d" % tickrate)
		var brain: BudgetBrain = body.get_node("AIComponent")
		for i in tickrate * 3:
			brain.tick(1.0 / tickrate)
		assert_between(brain.perception_calls, 29, 31)
		brain.decision_budget_enabled = false
		brain.perception_calls = 0
		for i in tickrate:
			brain.tick(1.0 / tickrate)
		assert_eq(brain.perception_calls, tickrate, "Opt-out retains original every-tick far-distance scan")

func test_near_and_empty_rooms_never_request_movement_dormancy() -> void:
	var body := _fixture()
	var brain: BudgetBrain = body.get_node("AIComponent")
	for distance in [INF, 54.0 * 54.0]:
		brain.nearest_sq = distance
		brain.wake_from_dormancy()
		brain.tick(1.0 / 30.0)
		assert_false(brain.wants_movement_dormancy())

func test_threat_and_health_drop_wake_without_resetting_active_target_timer_each_tick() -> void:
	var body := _fixture()
	var brain: BudgetBrain = body.get_node("AIComponent")
	brain.wake_from_dormancy()
	brain.tick(1.0 / 30.0)
	assert_true(brain.wants_movement_dormancy())
	body.server_state.sync_health -= 1
	brain.tick(1.0 / 30.0)
	assert_false(brain.wants_movement_dormancy())
	brain._distant_passive = true
	body.server_state.sync_threat_table = {"remote_attacker": 10}
	brain.tick(1.0 / 30.0)
	assert_false(brain.wants_movement_dormancy())
	brain.state = AIComponent.State.CHASE
	brain._target_search_timer = 0.2
	brain.tick(1.0 / 30.0)
	assert_almost_eq(brain._target_search_timer, 0.2 - 1.0 / 30.0, 0.00001)

func test_dormancy_excludes_bosses_elites_pets_and_known_targets() -> void:
	for entity_name in ["BOSS_TEST", "ELITE_TEST"]:
		var body := _fixture(entity_name)
		var brain: BudgetBrain = body.get_node("AIComponent")
		brain._distant_passive = true
		assert_false(brain.wants_movement_dormancy())
	var ordinary := _fixture()
	var ai: BudgetBrain = ordinary.get_node("AIComponent")
	ai._distant_passive = true
	ai._is_pet = true
	assert_false(ai.wants_movement_dormancy())
	ai._is_pet = false
	ai.target = Node3D.new()
	add_child_autofree(ai.target)
	assert_false(ai.wants_movement_dormancy())

func test_excluded_entities_use_legacy_cadence_and_cannot_request_dormancy() -> void:
	for kind in ["BOSS_TEST", "ELITE_TEST", "MOB_GROUP_BOSS", "PET_TEST", "UNKNOWN_TEST"]:
		var body := _fixture(kind)
		var brain: BudgetBrain = body.get_node("AIComponent")
		if kind == "MOB_GROUP_BOSS":
			body.add_to_group(&"bosses")
		if kind == "PET_TEST" or kind == "UNKNOWN_TEST":
			brain._is_mob = false
			brain._is_pet = kind == "PET_TEST"
		brain._distant_passive = true
		assert_false(brain._is_ordinary_mob())
		assert_false(brain.wants_movement_dormancy())
		brain.tick(1.0 / 30.0)
		assert_false(brain._budget_initialized, "Excluded actors never enter the experimental clock")
		assert_false(brain._distant_passive, "Legacy routing clears experimental sleep intent")
		assert_eq(brain.perception_calls, 1 if brain._is_mob else 0, "Original legacy far-LOD scan eligibility is retained")

func test_excluded_bosses_and_elites_preserve_legacy_far_lod_skip() -> void:
	for kind in ["BOSS_LOD", "ELITE_LOD", "MOB_GROUP_BOSS_LOD"]:
		var body := _fixture(kind)
		var brain: BudgetBrain = body.get_node("AIComponent")
		if kind == "MOB_GROUP_BOSS_LOD":
			body.add_to_group(&"bosses")
		brain.nearest_sq = 50.0 * 50.0
		for i in 3:
			brain.tick(1.0 / 30.0)
		assert_false(brain._budget_initialized)
		assert_eq(brain._tick_stagger, 3, "Original three-tick far-LOD path still runs")
		assert_eq(brain.perception_calls, 3)
		assert_almost_eq(brain._idle_timer, 0.1, 0.00001, "Legacy elapsed delta is unchanged")

func test_external_teleport_wakes_native_movement_immediately() -> void:
	var body := _fixture()
	var logic: LogicComponent = body.get_node("LogicComponent")
	var ai: BudgetBrain = body.get_node("AIComponent")
	logic._record_npc_movement_pose()
	ai._distant_passive = true
	logic._npc_dormant_recovery_remaining = 0.2
	body.global_position += Vector3(1.0, 0.0, 0.0)
	assert_false(logic._skip_dormant_npc_movement(1.0 / 30.0))
	assert_false(ai.wants_movement_dormancy())

func test_new_overlap_recovers_on_bounded_native_query_and_wakes() -> void:
	var body := _fixture()
	var logic: LogicComponent = body.get_node("LogicComponent")
	var ai: BudgetBrain = body.get_node("AIComponent")
	await get_tree().physics_frame
	await get_tree().physics_frame
	logic._record_npc_movement_pose()
	ai._distant_passive = true
	logic._npc_dormant_recovery_remaining = 0.2
	var blocker := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = body.get_child(1).shape.duplicate()
	blocker.add_child(shape)
	add_child_autofree(blocker)
	blocker.global_position = body.global_position
	await get_tree().physics_frame
	await get_tree().physics_frame
	var before := body.global_position
	for i in 6:
		var driver := MovementDriver.new()
		driver.logic = logic
		add_child_autofree(driver)
		await driver.drove_tick
		# Leave the physics callback before GUT frees the emitting driver.
		await get_tree().process_frame
	assert_ne(body.global_position, before, "Actual CharacterBody3D overlap recovery runs by 200ms")
	assert_false(ai.wants_movement_dormancy(), "Recovery displacement wakes the NPC")

func test_rollback_signal_cleanup_is_safe_before_sync_and_idempotent() -> void:
	var rollback := preload("res://addons/netfox/rollback/rollback-synchronizer.gd").new()
	rollback._disconnect_signals()
	rollback._connect_signals()
	assert_true(NetworkTime.before_tick.is_connected(rollback._before_tick))
	assert_true(NetworkRollback.on_record_tick.is_connected(rollback._on_record_tick))
	rollback._disconnect_signals()
	rollback._disconnect_signals()
	assert_false(NetworkTime.before_tick.is_connected(rollback._before_tick))
	assert_false(NetworkRollback.on_record_tick.is_connected(rollback._on_record_tick))
	# Construction owns an unparented default visibility filter.
	rollback.visibility_filter.free()
	rollback.free()

func test_perf_probe_collects_zero_players_after_peer_teardown() -> void:
	multiplayer.multiplayer_peer = null
	# The optional production autoload removes itself when profiling is off.
	# Exercise an owned instance instead of depending on external launch flags.
	var probe = load("res://common/perf_probe.gd").new()
	add_child(probe)
	var metrics: Dictionary = probe._collect_metrics()
	assert_eq(metrics.players, 0)
	assert_eq(metrics.live_players, 0)
