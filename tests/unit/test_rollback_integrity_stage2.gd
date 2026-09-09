extends GutTest

const COMBAT_COMPONENT_SCRIPT := preload("res://core/CombatComponent.gd")

var _client_peer: ENetMultiplayerPeer = null
const REQUIRED_NPC_PRESENTATION_STATE := [
	":global_position",
	":quaternion",
	"CombatComponent:sync_attack_count",
	"ServerState:sync_health",
	"ServerState:sync_is_dead",
]
const REMOVED_NPC_PRESENTATION_STATE := "LogicComponent:current_velocity"

func before_all() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_each() -> void:
	if is_instance_valid(_client_peer):
		_client_peer.close()
	_client_peer = null

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
	for fixture in [
		{"path": "res://scenes/EnemyEntity.tscn", "name": "MOB_TEST"},
		{"path": "res://scenes/PetEntity.tscn", "name": "PET_TEST"},
	]:
		var path: String = fixture["path"]
		var entity: Node = load(path).instantiate()
		entity.name = fixture["name"]
		if entity.has_method("configure_enemy"):
			entity.configure_enemy("AATROX")
		add_child_autofree(entity)
		await get_tree().process_frame

		assert_null(entity.get_node_or_null("RollbackSynchronizer"),
			"Server-owned NPCs must not pay per-entity rollback bookkeeping")
		var sync := entity.get_node_or_null("ServerState/StateSynchronizer") as StateSynchronizer
		assert_not_null(sync, "%s must configure a runtime StateSynchronizer" % path)
		if sync == null:
			continue
		for property in REQUIRED_NPC_PRESENTATION_STATE:
			assert_true(sync.properties.has(property), "%s must replicate %s" % [path, property])
		assert_false(sync.properties.has(REMOVED_NPC_PRESENTATION_STATE),
			"%s must derive remote animation movement from interpolated position deltas, not %s" % [path, REMOVED_NPC_PRESENTATION_STATE])

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

func test_projectiles_use_spawn_only_state_without_rollback_or_netfox_tick_sync() -> void:
	var scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	var state := scene.get_state()

	assert_false(_has_node(state, "RollbackSynchronizer"),
		"Server-owned projectiles must not create ephemeral RollbackSynchronizer RPC paths")
	assert_false(_has_node(state, "StateSynchronizer"),
		"Short-lived projectiles must not stream per-tick Netfox state")
	assert_false(_has_node(state, "TickInterpolator"),
		"Short-lived projectiles must not pay Netfox interpolation bookkeeping")

	var projectile := scene.instantiate()
	var sync := projectile.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	assert_not_null(sync, "ProjectileEntity should keep spawn/despawn replication through Godot")
	var config := sync.replication_config
	assert_not_null(config, "ProjectileEntity should have a SceneReplicationConfig")
	if config:
		for path in [NodePath(".:position"), NodePath(".:direction"), NodePath(".:speed")]:
			assert_true(config.has_property(path), "Projectile spawn replication must include %s" % path)
			assert_true(config.property_get_spawn(path), "Projectile %s should replicate on spawn" % path)
			assert_eq(config.property_get_replication_mode(path), SceneReplicationConfig.REPLICATION_MODE_NEVER,
				"Projectile %s must never stream after spawn" % path)
		for path in [NodePath(".:damage"), NodePath(".:owner_entity_id"), NodePath(".:knockback"), NodePath(".:_has_hit"), NodePath(".:_lifetime_remaining")]:
			assert_false(config.has_property(path), "Projectile must not spawn-replicate server-only %s" % path)
	projectile.free()

func test_projectile_network_tick_advances_only_on_server() -> void:
	var projectile := ProjectileEntity.new()
	projectile.initialize(Vector3.FORWARD, 30.0, 20.0, 7)
	add_child_autofree(projectile)
	var start := projectile.global_position

	projectile.call("_on_projectile_tick", 1.0 / 30.0, 100)
	assert_gt(projectile.global_position.distance_to(start), 0.9,
		"Server network ticks must advance projectile motion at configured speed")
	var server_after_tick := projectile.global_position
	projectile.call("_process", 1.0 / 30.0)
	assert_eq(projectile.global_position, server_after_tick,
		"Servers must not run cosmetic projectile presentation movement")

	_client_peer = ENetMultiplayerPeer.new()
	_client_peer.create_client("127.0.0.1", 44999)
	multiplayer.multiplayer_peer = _client_peer
	assert_ne(multiplayer.get_unique_id(), 1, "Client sim must not be peer 1")
	var client_projectile := load("res://scenes/ProjectileEntity.tscn").instantiate() as ProjectileEntity
	client_projectile.initialize(Vector3.FORWARD, 30.0, 20.0, 7)
	add_child_autofree(client_projectile)
	await get_tree().process_frame
	assert_eq(client_projectile.collision_layer, 0, "Client projectiles must not expose collision layers")
	assert_eq(client_projectile.collision_mask, 0, "Client projectiles must not collide locally")
	var client_shape := client_projectile.get_node("CollisionShape3D") as CollisionShape3D
	assert_true(client_shape.disabled, "Client projectile collision shape must be disabled")
	var client_start := client_projectile.global_position
	client_projectile.call("_on_projectile_tick", 1.0 / 30.0, 101)
	assert_eq(client_projectile.global_position, client_start,
		"Clients must not simulate projectile collision, damage, lifetime, or despawn on network ticks")
	client_projectile.call("_process", 1.0 / 30.0)
	assert_gt(client_projectile.global_position.distance_to(client_start), 0.9,
		"Clients should move projectile presentation cosmetically between spawn and authoritative despawn")

func test_headless_projectile_strips_presentation_but_keeps_collision_and_spawn_sync() -> void:
	var projectile := load("res://scenes/ProjectileEntity.tscn").instantiate() as ProjectileEntity
	add_child_autofree(projectile)
	await get_tree().process_frame

	assert_not_null(projectile.get_node_or_null("CollisionShape3D"),
		"Headless projectile runtime must keep gameplay collision")
	assert_null(projectile.get_node_or_null("MeshInstance3D"),
		"Headless projectile runtime must strip visual mesh")
	assert_null(projectile.get_node_or_null("TickInterpolator"),
		"Headless projectile runtime must strip client interpolation presentation")

func test_projectile_try_hit_keeps_damage_and_owner_attribution() -> void:
	var shooter := Node.new()
	shooter.name = "7"
	add_child_autofree(shooter)

	var target := CharacterBody3D.new()
	target.name = "8"
	add_child_autofree(target)
	var health := HealthComponent.new()
	health.max_health = 100
	target.add_child(health)
	var hurtbox := HurtboxComponent.new()
	hurtbox.health_component = health
	target.add_child(hurtbox)
	await get_tree().process_frame
	health.current_health = 100
	var damaged_events: Array = []
	health.damaged.connect(func(amount: int, source: Node):
		damaged_events.append({"amount": amount, "source": source})
	)

	var projectile := ProjectileEntity.new()
	projectile.initialize(Vector3.FORWARD, 30.0, 17.0, 7, 5.0, shooter)
	add_child_autofree(projectile)

	assert_true(projectile.call("_try_hit", hurtbox), "Projectile should report a valid damaging hit")
	assert_eq(health.current_health, 83, "Projectile hit should apply configured damage")
	assert_eq(damaged_events.size(), 1, "Projectile hit should emit one damage event")
	assert_eq(damaged_events[0]["source"], shooter, "Projectile damage attribution should use the shooter")

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
