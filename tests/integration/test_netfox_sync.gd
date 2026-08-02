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
