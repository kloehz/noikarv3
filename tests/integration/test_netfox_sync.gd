# tests/integration/test_netfox_sync.gd
extends GutTest

## Integration tests for BaseEntity replication via netfox synchronizers.
## BaseEntity.tscn has no MultiplayerSynchronizer; replication goes through
## RollbackSynchronizer (state/input properties) and StateSynchronizer (server
## state deltas). Verifies those nodes exist and are configured correctly.

const TEST_PORT = 9999
var _server_peer: ENetMultiplayerPeer
var _client_peer: ENetMultiplayerPeer
var _server_scene: Node
var _client_scene: Node
var _base_entity_scene: PackedScene

func before_each() -> void:
	_base_entity_scene = load("res://scenes/BaseEntity.tscn")
	assert_not_null(_base_entity_scene, "BaseEntity.tscn should exist")

func _replication_config_for_scene(scene_path: String) -> SceneReplicationConfig:
	var packed_scene: PackedScene = load(scene_path)
	assert_not_null(packed_scene, "%s should exist" % scene_path)
	if packed_scene == null:
		return null
	var entity := packed_scene.instantiate()
	var synchronizer := entity.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	assert_not_null(synchronizer, "%s should keep its MultiplayerSynchronizer" % scene_path)
	if synchronizer == null:
		entity.free()
		return null
	var config := synchronizer.replication_config
	assert_not_null(config, "%s should have a SceneReplicationConfig" % scene_path)
	entity.free()
	return config

func _assert_spawn_only_godot_position_replication(config: SceneReplicationConfig, context: String) -> void:
	assert_not_null(config, "%s should have a replication config" % context)
	if config == null:
		return
	var global_position_path := NodePath(".:global_position")
	assert_true(config.has_property(global_position_path), "%s should keep global_position in spawn data" % context)
	assert_true(config.property_get_spawn(global_position_path), "%s should spawn global_position" % context)
	assert_eq(config.property_get_replication_mode(global_position_path), SceneReplicationConfig.REPLICATION_MODE_NEVER,
		"%s should not continuously replicate global_position through MultiplayerSynchronizer" % context)

func _assert_scene_replication_properties(config: SceneReplicationConfig, context: String, properties: Array[NodePath]) -> void:
	assert_not_null(config, "%s should have a replication config" % context)
	if config == null:
		return
	for property_path in properties:
		assert_true(config.has_property(property_path), "%s should keep %s replicated" % [context, property_path])
		assert_true(config.property_get_spawn(property_path), "%s should include %s in spawn data" % [context, property_path])
		assert_eq(config.property_get_replication_mode(property_path), SceneReplicationConfig.REPLICATION_MODE_ALWAYS,
			"%s should keep %s using always-on Godot replication" % [context, property_path])

func after_each() -> void:
	if is_instance_valid(_server_peer) and _server_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		_server_peer.close()
	if is_instance_valid(_client_peer) and _client_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		_client_peer.close()
	_server_peer = null
	_client_peer = null
	
	if is_instance_valid(_server_scene):
		_server_scene.queue_free()
	if is_instance_valid(_client_scene):
		_client_scene.queue_free()


func _configured_state_sync_for_entity_name(entity_name: String) -> StateSynchronizer:
	var entity = _base_entity_scene.instantiate()
	entity.name = entity_name
	add_child_autofree(entity)
	return entity.get_node("ServerState/StateSynchronizer") as StateSynchronizer

func _state_sync_has_property(sync: StateSynchronizer, property_path: String) -> bool:
	for configured_path in sync.properties:
		if String(configured_path) == property_path or String(configured_path).ends_with(property_path):
			return true
	return false

func _object_has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func _assert_state_sync_omits_property(sync: StateSynchronizer, property_path: String, context: String) -> void:
	assert_not_null(sync, "%s should have a StateSynchronizer" % context)
	if sync == null:
		return
	assert_false(_state_sync_has_property(sync, property_path), "%s StateSynchronizer must not replicate %s" % [context, property_path])

func _assert_state_sync_property_count(sync: StateSynchronizer, expected_count: int, context: String) -> void:
	assert_not_null(sync, "%s should have a StateSynchronizer" % context)
	if sync == null:
		return
	assert_eq(sync.properties.size(), expected_count,
		"%s StateSynchronizer property count should reflect the NPC velocity snapshot reduction" % context)

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

## Test: BaseEntity scene can be instantiated
func test_base_entity_scene_instantiation() -> void:
	var entity = _base_entity_scene.instantiate()
	assert_not_null(entity, "BaseEntity should instantiate")
	entity.queue_free()

## Test: BaseEntity has netfox synchronizers
func test_base_entity_has_netfox_synchronizers() -> void:
	var entity = _base_entity_scene.instantiate()
	var rollback_sync = entity.get_node_or_null("RollbackSynchronizer")
	assert_not_null(rollback_sync, "BaseEntity should have RollbackSynchronizer")
	var state_sync = entity.get_node_or_null("ServerState/StateSynchronizer")
	assert_not_null(state_sync, "BaseEntity should have ServerState/StateSynchronizer")
	entity.queue_free()

## Test: RollbackSynchronizer is configured for global_position state
func test_rollback_synchronizer_syncs_position() -> void:
	var entity = _base_entity_scene.instantiate()
	var rollback_sync = entity.get_node_or_null("RollbackSynchronizer")
	if assert_not_null(rollback_sync, "RollbackSynchronizer should exist"):
		var state_props: Array = rollback_sync.get("state_properties")
		assert_true(state_props.has(":global_position"), "RollbackSynchronizer should track :global_position as state")
		var input_props: Array = rollback_sync.get("input_properties")
		assert_true(input_props.has("LogicComponent:input_axis"), "RollbackSynchronizer should record LogicComponent:input_axis as input")
	entity.queue_free()

## Test: LogicComponent exists in core folder
func test_logic_component_exists() -> void:
	var logic_component = load("res://core/LogicComponent.gd")
	assert_not_null(logic_component, "LogicComponent should exist in res://core/")

## Test: VisualComponent exists in client folder
func test_visual_component_exists() -> void:
	var visual_component = load("res://client/VisualComponent.gd")
	assert_not_null(visual_component, "VisualComponent should exist in res://client/")

## Test: BaseEntity extends CharacterBody3D
func test_base_entity_extends_character_body() -> void:
	var BaseEntity = load("res://common/BaseEntity.gd")
	assert_not_null(BaseEntity, "BaseEntity script should load")
	
	# Verify it's a CharacterBody3D subclass
	var entity_instance = _base_entity_scene.instantiate()
	assert_true(entity_instance is CharacterBody3D, "BaseEntity should extend CharacterBody3D")
	entity_instance.queue_free()

## Test: Server can spawn BaseEntity
func test_server_can_spawn_entity() -> void:
	# This would require actual multiplayer setup
	# For now, verify the scene structure supports it
	var entity = _base_entity_scene.instantiate()
	assert_not_null(entity, "Should be able to spawn entity")

	# Verify it has required components
	assert_not_null(entity.get_node_or_null("LogicComponent"), "Entity should have LogicComponent child")
	entity.queue_free()

## Test: No client folder files leak into server context
func test_no_client_leakage_in_server_folder() -> void:
	# Verify core folder doesn't contain client-only files
	var core_dir = DirAccess.open("res://core/")
	if core_dir:
		core_dir.list_dir_begin()
		var file_name = core_dir.get_next()
		while file_name != "":
			if not file_name.begins_with("."):
				assert_false("Visual" in file_name, "Core folder should not contain Visual files")
				assert_false("Client" in file_name, "Core folder should not contain Client files")
			file_name = core_dir.get_next()

## Test: Netfox nodes are available (placeholder check)
func test_netfox_nodes_check() -> void:
	# Netfox would be in addons/, check if available
	var has_netfox = DirAccess.dir_exists_absolute("res://addons/netfox")
	# This is informational - Netfox may not be installed yet
	print("Netfox available: ", has_netfox)

## Test: a replicated heal event fires only when the server increments its
## sequence, not when an entity receives its initial synchronized health.
func test_server_state_emits_only_explicit_heal_events() -> void:
	var state := ServerState.new()
	var received: Array[int] = []
	state.heal_received.connect(func(amount: int): received.append(amount))

	state.sync_health = 100
	assert_eq(received.size(), 0, "Health synchronization alone must not emit a heal VFX event")

	state.sync_heal_amount = 12
	state.sync_heal_sequence = 1
	assert_eq(received, [12], "Incrementing the sequence emits the synced heal amount")

	state.sync_heal_sequence = 1
	assert_eq(received.size(), 1, "Repeating the same sequence must not duplicate the VFX event")

## Test: a replicated damage event fires only when the server increments its
## sequence. Mirrors the heal pattern so hit VFX (VFXHit_02) only renders on
## real, server-authoritative damage — never on resync or initial state.
func test_server_state_emits_only_explicit_damage_events() -> void:
	var state := ServerState.new()
	var received: Array = []
	state.damage_received.connect(func(amount: int, source: Node):
		received.append({"amount": amount, "source": source})
	)

	state.sync_health = 100
	assert_eq(received.size(), 0, "Health synchronization alone must not emit a damage VFX event")

	var fake_source := Node.new()
	state.sync_damage_amount = 25
	state.sync_damage_source = fake_source
	state.sync_damage_sequence = 1
	assert_eq(received.size(), 1, "Incrementing the sequence emits the synced damage amount")
	assert_eq(received[0]["amount"], 25, "Amount passed to listeners equals the synced amount")
	assert_eq(received[0]["source"], fake_source, "Source passed to listeners equals the synced source")

	state.sync_damage_sequence = 1
	assert_eq(received.size(), 1, "Repeating the same sequence must not duplicate the VFX event")

	state.sync_damage_sequence = 2
	assert_eq(received.size(), 2, "A second distinct sequence emits a new VFX event")

	fake_source.queue_free()

func test_mob_state_synchronizer_omits_threat_table_but_keeps_local_threat() -> void:
	var sync := _configured_state_sync_for_entity_name("MOB_AATROX_1")
	_assert_state_sync_omits_property(sync, ":sync_threat_table", "Mob")
	var state := sync.get_parent() as ServerState
	state.add_threat("2", 40)
	assert_eq(int(state.sync_threat_table.get("2", 0)), 40,
		"Mob threat table remains locally writable/readable for server AI logic")
	state.decay_threat(15)
	assert_eq(int(state.sync_threat_table.get("2", 0)), 25,
		"Mob threat decay remains local server logic, not synchronized state")

func test_pet_state_synchronizer_omits_threat_table_but_keeps_pet_sync_data() -> void:
	var sync := _configured_state_sync_for_entity_name("PET_2")
	_assert_state_sync_omits_property(sync, ":sync_threat_table", "Pet")
	assert_true(sync.properties.has(":pet_type_sync"),
		"Pet type remains synchronized for client presentation")
	assert_true(sync.properties.has(":power_level_sync"),
		"Pet power level remains synchronized for client presentation")
	var state := sync.get_parent() as ServerState
	state.add_threat("MOB_AATROX_1", 12)
	assert_eq(int(state.sync_threat_table.get("MOB_AATROX_1", 0)), 12,
		"Pet threat table remains available locally even though it is not replicated")

func test_mob_state_synchronizer_omits_logic_velocity_but_keeps_transform_snapshots() -> void:
	var sync := _configured_state_sync_for_entity_name("MOB_AATROX_1")
	_assert_state_sync_omits_property(sync, "LogicComponent:current_velocity", "Mob")
	assert_true(_state_sync_has_property(sync, ":global_position"),
		"Mob StateSynchronizer must keep authoritative global_position snapshots")
	assert_true(_state_sync_has_property(sync, ":quaternion"),
		"Mob StateSynchronizer must keep authoritative quaternion snapshots")
	_assert_state_sync_property_count(sync, 19,
		"Mob")

func test_pet_state_synchronizer_omits_logic_velocity_but_keeps_pet_data() -> void:
	var sync := _configured_state_sync_for_entity_name("PET_2")
	_assert_state_sync_omits_property(sync, "LogicComponent:current_velocity", "Pet")
	assert_true(_state_sync_has_property(sync, ":global_position"),
		"Pet StateSynchronizer must keep authoritative global_position snapshots")
	assert_true(_state_sync_has_property(sync, ":quaternion"),
		"Pet StateSynchronizer must keep authoritative quaternion snapshots")
	assert_true(_state_sync_has_property(sync, ":pet_type_sync"),
		"Pet type remains synchronized after the velocity reduction")
	assert_true(_state_sync_has_property(sync, ":power_level_sync"),
		"Pet power level remains synchronized after the velocity reduction")
	_assert_state_sync_property_count(sync, 19,
		"Pet")

func test_player_rollback_synchronizer_retains_logic_velocity_state() -> void:
	var entity = _base_entity_scene.instantiate()
	var rollback_sync = entity.get_node_or_null("RollbackSynchronizer")
	if assert_not_null(rollback_sync, "RollbackSynchronizer should exist"):
		var state_props: Array = rollback_sync.get("state_properties")
		assert_true(state_props.has("LogicComponent:current_velocity"),
			"Player rollback must retain LogicComponent.current_velocity state")
	entity.queue_free()

func test_enemy_multiplayer_synchronizer_keeps_position_spawn_only() -> void:
	var config := _replication_config_for_scene("res://scenes/EnemyEntity.tscn")
	_assert_spawn_only_godot_position_replication(config, "EnemyEntity")
	_assert_scene_replication_properties(config, "EnemyEntity", [
		NodePath(".:spawn_grace_duration"),
		NodePath(".:enemy_type"),
		NodePath(".:actor_scale"),
		NodePath(".:difficulty"),
	])

	var enemy: Node = load("res://scenes/EnemyEntity.tscn").instantiate()
	var state_sync := enemy.get_node("ServerState/StateSynchronizer") as StateSynchronizer
	assert_eq(state_sync.get_script(), load("res://addons/netfox/state-synchronizer.gd"),
		"EnemyEntity should use vendor StateSynchronizer for every 30 Hz network tick")
	assert_false(_object_has_property(state_sync, "authority_snapshot_stride"),
		"EnemyEntity visible movement must not be reduced by authority cadence")
	var expected_transform_properties: Array[String] = [":global_position", ":quaternion"]
	assert_eq(state_sync.properties, expected_transform_properties,
		"EnemyEntity should keep only authoritative transform snapshots")
	var tick_interpolator := enemy.get_node("TickInterpolator")
	assert_true(tick_interpolator.properties.has(":global_position"),
		"EnemyEntity should keep TickInterpolator global_position")
	assert_true(tick_interpolator.properties.has(":quaternion"),
		"EnemyEntity should keep TickInterpolator quaternion")
	enemy.free()

func test_pet_multiplayer_synchronizer_keeps_position_spawn_only() -> void:
	var config := _replication_config_for_scene("res://scenes/PetEntity.tscn")
	_assert_spawn_only_godot_position_replication(config, "PetEntity")
	_assert_scene_replication_properties(config, "PetEntity", [
		NodePath(".:owner_id"),
		NodePath(".:pet_type"),
		NodePath(".:power_level"),
	])

	var pet: Node = load("res://scenes/PetEntity.tscn").instantiate()
	var state_sync := pet.get_node("ServerState/StateSynchronizer") as StateSynchronizer
	assert_eq(state_sync.get_script(), load("res://addons/netfox/state-synchronizer.gd"),
		"PetEntity should use vendor StateSynchronizer for every 30 Hz network tick")
	assert_false(_object_has_property(state_sync, "authority_snapshot_stride"),
		"PetEntity visible movement must not be reduced by authority cadence")
	var expected_transform_properties: Array[String] = [":global_position", ":quaternion"]
	assert_eq(state_sync.properties, expected_transform_properties,
		"PetEntity should keep only authoritative transform snapshots")
	var tick_interpolator := pet.get_node("TickInterpolator")
	assert_true(tick_interpolator.properties.has(":global_position"),
		"PetEntity should keep TickInterpolator global_position")
	assert_true(tick_interpolator.properties.has(":quaternion"),
		"PetEntity should keep TickInterpolator quaternion")
	pet.free()

func test_match_state_uses_low_frequency_authority_snapshot_cadence() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main: Node = main_scene.instantiate()
	var match_state: Node = main.get_node("MatchState")
	var match_sync := match_state.get_node("StateSynchronizer") as StateSynchronizer
	assert_eq(match_sync.get_script(), load("res://common/net/CadencedStateSynchronizer.gd"),
		"MatchState should use generic authority-only cadenced snapshots")
	assert_eq(match_sync.get("authority_snapshot_stride"), 6,
		"MatchState cadence should be every 6 network ticks for low-frequency server-owned data")
	main.free()

func test_projectile_uses_spawn_only_godot_replication_without_netfox_tick_sync() -> void:
	var projectile_scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	assert_not_null(projectile_scene, "ProjectileEntity.tscn should exist")
	var state := projectile_scene.get_state()

	assert_false(_has_node(state, "RollbackSynchronizer"),
		"ProjectileEntity must not expose RollbackSynchronizer/Node RPC paths")
	assert_false(_has_node(state, "StateSynchronizer"),
		"ProjectileEntity must not stream per-tick Netfox position snapshots")
	assert_false(_has_node(state, "TickInterpolator"),
		"ProjectileEntity must not interpolate per-tick Netfox projectile snapshots")

	var projectile := projectile_scene.instantiate()
	var synchronizer := projectile.get_node_or_null("MultiplayerSynchronizer") as MultiplayerSynchronizer
	assert_not_null(synchronizer, "ProjectileEntity should use Godot spawn replication")
	var config := synchronizer.replication_config
	assert_not_null(config, "ProjectileEntity should declare SceneReplicationConfig")
	if config:
		for property_path in [NodePath(".:position"), NodePath(".:direction"), NodePath(".:speed")]:
			assert_true(config.has_property(property_path), "Projectile spawn data should include %s" % property_path)
			assert_true(config.property_get_spawn(property_path), "%s should be sent only in spawn data" % property_path)
			assert_eq(config.property_get_replication_mode(property_path), SceneReplicationConfig.REPLICATION_MODE_NEVER,
				"%s must not replicate after spawn" % property_path)
		for server_only_property in [NodePath(".:damage"), NodePath(".:owner_entity_id"), NodePath(".:knockback"), NodePath(".:_has_hit"), NodePath(".:_lifetime_remaining")]:
			assert_false(config.has_property(server_only_property),
				"Projectile spawn replication must not expose server-only %s" % server_only_property)
	projectile.free()
