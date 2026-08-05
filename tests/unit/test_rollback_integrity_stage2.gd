extends GutTest

const COMBAT_COMPONENT_SCRIPT := preload("res://core/CombatComponent.gd")
const REQUIRED_NPC_PRESENTATION_STATE := [
	":global_position",
	":quaternion",
	"LogicComponent:current_velocity",
	"CombatComponent:sync_attack_count",
	"ServerState:sync_health",
	"ServerState:sync_is_dead",
]

func before_all() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_all() -> void:
	multiplayer.multiplayer_peer = null

func test_server_attack_event_ledger_rejects_replay() -> void:
	var combat: Node = COMBAT_COMPONENT_SCRIPT.new()
	add_child_autofree(combat)

	assert_true(combat.call("_record_attack_event", "attacker:1:10"))
	assert_false(combat.call("_record_attack_event", "attacker:1:10"),
		"Restoring an attack tick must not dispatch its world side effect twice")
	assert_true(combat.call("_record_attack_event", "attacker:2:11"))

func test_enemy_and_pet_use_authoritative_state_replication() -> void:
	for path in ["res://scenes/EnemyEntity.tscn", "res://scenes/PetEntity.tscn"]:
		var scene: PackedScene = load(path)
		var state := scene.get_state()
		assert_false(_has_node(state, "RollbackSynchronizer"),
			"Server-owned NPCs must not pay per-entity rollback bookkeeping")
		var properties: Array = _node_property(state, "StateSynchronizer", "properties")
		for property in REQUIRED_NPC_PRESENTATION_STATE:
			assert_true(properties.has(property), "%s must replicate %s" % [path, property])

func test_npc_tick_does_not_override_base_authoritative_tick() -> void:
	var enemy = load("res://scenes/EnemyEntity.tscn").instantiate()
	enemy.name = "MOB_TEST"
	enemy.configure_enemy("AATROX")
	add_child_autofree(enemy)
	await get_tree().process_frame

	assert_eq(_connection_count(NetworkTime.on_tick, enemy, &"_on_npc_tick"), 1,
		"NPC simulation must run exactly once per network tick")
	assert_eq(_connection_count(NetworkTime.after_tick, enemy, &"_on_authoritative_tick"), 1,
		"NPCs must preserve BaseEntity authoritative maintenance")
	assert_eq(_connection_count(NetworkTime.after_tick, enemy, &"_on_npc_tick"), 0,
		"NPC simulation must not run again during after_tick")

func test_projectiles_are_server_authoritative_without_prediction() -> void:
	var scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	var state := scene.get_state()
	var properties := _rollback_state_properties("res://scenes/ProjectileEntity.tscn")

	assert_false(_node_property(state, "RollbackSynchronizer", "enable_prediction"),
		"Server-owned projectile movement must not run on clients")
	for property in [":damage", ":knockback", ":owner_entity_id", ":_lifetime_remaining", ":_has_hit"]:
		assert_true(properties.has(property), "Projectile state must include %s" % property)

func test_projectiles_target_every_faction_entity_layer() -> void:
	var scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	var projectile := scene.instantiate() as ProjectileEntity
	add_child_autofree(projectile)
	await get_tree().process_frame
	for layer in [16, 32, 64]:
		assert_ne(projectile.collision_mask & layer, 0,
			"Projectile collision mask must include faction layer %d" % layer)

func test_enemy_and_pet_expose_spawn_grace_to_child_components() -> void:
	var logic_source := FileAccess.get_file_as_string("res://core/LogicComponent.gd")
	var combat_source := FileAccess.get_file_as_string("res://core/CombatComponent.gd")
	assert_true(logic_source.contains("is_spawn_grace_active"),
		"LogicComponent must reject rollback movement during entity spawn grace")
	assert_true(combat_source.contains("is_spawn_grace_active"),
		"CombatComponent must reject rollback attacks during entity spawn grace")

func _rollback_state_properties(path: String) -> Array:
	var scene: PackedScene = load(path)
	return _node_property(scene.get_state(), "RollbackSynchronizer", "state_properties")

func _node_property(state: SceneState, node_name: String, property_name: String):
	for node_index in state.get_node_count():
		if state.get_node_name(node_index) != node_name:
			continue
		for property_index in state.get_node_property_count(node_index):
			if state.get_node_property_name(node_index, property_index) == property_name:
				return state.get_node_property_value(node_index, property_index)
	return null

func _has_node(state: SceneState, node_name: String) -> bool:
	for node_index in state.get_node_count():
		if state.get_node_name(node_index) == node_name:
			return true
	return false

func _connection_count(signal_value: Signal, target: Object, method: StringName) -> int:
	var count := 0
	for connection in signal_value.get_connections():
		var callable: Callable = connection["callable"]
		if callable.get_object() == target and callable.get_method() == method:
			count += 1
	return count
