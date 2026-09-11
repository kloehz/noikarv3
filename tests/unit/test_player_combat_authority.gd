extends GutTest

const PLAYER_SCENE := preload("res://scenes/BaseEntity.tscn")
const COMBAT_SCRIPT := preload("res://core/CombatComponent.gd")

class FakeLogic:
	extends Node
	var is_shooting := false
	func get_aim_direction() -> Vector3:
		return Vector3.FORWARD

class FakeEntity:
	extends Node3D
	var character_actor: CharacterActor = null
	var character_spec: CharacterSpec = null
	var sync_is_dead := false

class SpawnProbeProjectile:
	extends Node3D
	var initialized_owner_id := -1
	var initialized_speed := -1.0
	var initialized_damage := -1.0
	func initialize(direction: Vector3, speed: float, damage: float, owner_id: int, knockback: float = 8.0, owner_entity: Node = null) -> void:
		initialized_owner_id = owner_id
		initialized_speed = speed
		initialized_damage = damage

var _prior_peer: MultiplayerPeer = null
var _client_peer: ENetMultiplayerPeer = null

func before_each() -> void:
	_prior_peer = multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_each() -> void:
	if is_instance_valid(_client_peer):
		_client_peer.close()
	_client_peer = null
	multiplayer.multiplayer_peer = _prior_peer
	_prior_peer = null

func test_player_scene_keeps_combat_state_server_owned_and_sanitizes_client_snapshot() -> void:
	_client_peer = ENetMultiplayerPeer.new()
	_client_peer.create_client("127.0.0.1", 44999)
	multiplayer.multiplayer_peer = _client_peer
	var client_id := multiplayer.get_unique_id()
	assert_ne(client_id, 1, "Fixture must run as a non-server player peer")

	var player: Node = PLAYER_SCENE.instantiate()
	player.name = str(client_id)
	add_child_autofree(player)
	player.get_node("RollbackSynchronizer").call("_connect_signals")
	player.get_node("ServerState/StateSynchronizer").call("_connect_signals")

	var logic := player.get_node("LogicComponent")
	var combat := player.get_node("CombatComponent")
	var server_state := player.get_node("ServerState")
	assert_eq(player.get_multiplayer_authority(), client_id, "Player entity stays client-owned for prediction")
	assert_eq(logic.get_multiplayer_authority(), client_id, "Logic/input stays client-owned")
	assert_eq(combat.get_multiplayer_authority(), 1, "Combat rollback state must be server-owned")
	assert_eq(server_state.get_multiplayer_authority(), 1, "ServerState must be server-owned")

	var snapshot := _PropertySnapshot.from_dictionary({
		"CombatComponent:current_attack_state": CombatComponent.AttackState.ACTIVE,
		"CombatComponent:sync_attack_count": 99,
		"CombatComponent:_active_damage_multiplier": 5.0,
		"CombatComponent:_primary_cooldown": 9.0,
		"LogicComponent:is_shooting": true,
	})
	snapshot.sanitize(client_id, PropertyCache.new(player))
	assert_false(snapshot.has("CombatComponent:current_attack_state"), "Client must not overwrite combat phase")
	assert_false(snapshot.has("CombatComponent:sync_attack_count"), "Client must not overwrite combat counter")
	assert_false(snapshot.has("CombatComponent:_active_damage_multiplier"), "Client must not overwrite damage multiplier")
	assert_false(snapshot.has("CombatComponent:_primary_cooldown"), "Client must not overwrite cooldown")
	assert_true(snapshot.has("LogicComponent:is_shooting"), "Client input intentions remain client-owned")


func test_respawn_clears_stale_stun_state() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var player: Node = PLAYER_SCENE.instantiate()
	player.name = "77"
	add_child_autofree(player)
	var server_state: ServerState = player.get_node("ServerState")
	server_state.apply_stun(1.5)
	server_state.sync_is_dead = true

	player.respawn(Vector3(1.0, 2.0, 3.0))
	assert_false(server_state.sync_is_dead)
	assert_false(server_state.is_stunned, "Respawn must clear stale stun flag")
	assert_almost_eq(server_state.stun_remaining_time, 0.0, 0.001, "Respawn must clear stale stun timer")

func test_player_scene_diff_encoder_excludes_predicted_combat_from_client_owned_state() -> void:
	_client_peer = ENetMultiplayerPeer.new()
	_client_peer.create_client("127.0.0.1", 44999)
	multiplayer.multiplayer_peer = _client_peer
	var client_id := multiplayer.get_unique_id()
	assert_ne(client_id, 1, "Fixture must run as a non-server player peer")

	var player: Node = PLAYER_SCENE.instantiate()
	player.name = str(client_id)
	add_child_autofree(player)
	player.get_node("RollbackSynchronizer").call("_connect_signals")
	player.get_node("ServerState/StateSynchronizer").call("_connect_signals")

	var property_cache := PropertyCache.new(player)
	var state_config := _PropertyConfig.new()
	state_config.local_peer_id = client_id
	state_config.set_properties_from_paths([
		"LogicComponent:is_shooting",
		"CombatComponent:current_attack_state",
		"CombatComponent:sync_attack_count",
		"CombatComponent:_active_damage_multiplier",
		"CombatComponent:_primary_cooldown",
	], property_cache)
	var history := _PropertyHistoryBuffer.new()
	var encoder := _DiffHistoryEncoder.new(history, property_cache)
	encoder.add_properties(state_config.get_properties())
	history.set_snapshot(100, {
		"LogicComponent:is_shooting": false,
		"CombatComponent:current_attack_state": CombatComponent.AttackState.READY,
		"CombatComponent:sync_attack_count": 1,
		"CombatComponent:_active_damage_multiplier": 1.0,
		"CombatComponent:_primary_cooldown": 0.0,
	})
	history.set_snapshot(101, {
		"LogicComponent:is_shooting": true,
		"CombatComponent:current_attack_state": CombatComponent.AttackState.ACTIVE,
		"CombatComponent:sync_attack_count": 2,
		"CombatComponent:_active_damage_multiplier": 1.5,
		"CombatComponent:_primary_cooldown": 0.25,
	})

	var encoded := encoder.encode(101, 100, state_config.get_owned_properties())
	var decoded := encoder.decode(encoded, state_config.get_properties())

	assert_true(decoded.has("LogicComponent:is_shooting"), "Client-owned input remains transmissible")
	assert_false(decoded.has("CombatComponent:current_attack_state"), "Predicted server-owned combat phase must stay local")
	assert_false(decoded.has("CombatComponent:sync_attack_count"), "Predicted server-owned combat counter must stay local")
	assert_false(decoded.has("CombatComponent:_active_damage_multiplier"), "Predicted server-owned combat damage must stay local")
	assert_false(decoded.has("CombatComponent:_primary_cooldown"), "Predicted server-owned combat cooldown must stay local")
	assert_eq(history.get_snapshot(101).as_dictionary()["CombatComponent:sync_attack_count"], 2,
		"Server-owned combat state remains in local prediction history for later server-owned transmission")

func test_server_nonfresh_release_reaches_active_and_spawns_one_projectile() -> void:
	var fixture := _combat_fixture(true, "77")
	var combat: CombatComponent = fixture["combat"]
	var logic: FakeLogic = fixture["logic"]
	logic.is_shooting = false
	combat.is_charging = true
	combat.current_charge_time = 0.05
	combat._rollback_tick(0.1, 10, false)
	assert_eq(combat.current_attack_state, CombatComponent.AttackState.STARTUP,
		"Server must process recorded release input even when the tick is not fresh")
	combat._rollback_tick(0.1, 11, false)
	assert_eq(combat.current_attack_state, CombatComponent.AttackState.ACTIVE)
	assert_eq(fixture["projectiles"].get_child_count(), 1,
		"Recorded release must create exactly one authoritative projectile")

func test_replayed_same_attack_at_different_processing_tick_does_not_duplicate_projectile() -> void:
	var fixture := _combat_fixture(true, "77")
	var combat: CombatComponent = fixture["combat"]
	var projectiles: Node = fixture["projectiles"]
	combat.sync_attack_count = 3
	combat._active_attack_slot = 1
	combat._active_attack = null
	combat._on_attack_active(20)
	combat._on_attack_active(21)
	assert_eq(projectiles.get_child_count(), 1,
		"Same attack counter replayed on another processing tick must not duplicate spawn")

	combat.sync_attack_count = 4
	combat._on_attack_active(22)
	assert_eq(projectiles.get_child_count(), 2,
		"A distinct next attack counter must still dispatch")

func test_client_prediction_resimulates_local_charge_without_projectile_and_remote_does_not_start() -> void:
	_client_peer = ENetMultiplayerPeer.new()
	_client_peer.create_client("127.0.0.1", 44999)
	multiplayer.multiplayer_peer = _client_peer
	var client_id := multiplayer.get_unique_id()

	var local := _combat_fixture(false, str(client_id))
	var local_combat: CombatComponent = local["combat"]
	var local_logic: FakeLogic = local["logic"]
	local_logic.is_shooting = true
	local_combat._rollback_tick(0.1, 30, false)
	assert_true(local_combat.is_charging, "Owning client must predict charge during resimulation")
	local_logic.is_shooting = false
	local_combat._rollback_tick(0.1, 31, false)
	assert_eq(local_combat.current_attack_state, CombatComponent.AttackState.STARTUP,
		"Owning client must replay release into predicted state")
	local_combat._rollback_tick(0.1, 32, false)
	assert_eq(local["projectiles"].get_child_count(), 0,
		"Client prediction must not instantiate authoritative projectiles")

	var remote := _combat_fixture(false, str(client_id + 1000))
	var remote_combat: CombatComponent = remote["combat"]
	(remote["logic"] as FakeLogic).is_shooting = true
	remote_combat._rollback_tick(0.1, 40, false)
	assert_false(remote_combat.is_charging, "Remote clients must not create attack intentions")
	assert_eq(remote_combat.current_attack_state, CombatComponent.AttackState.READY)

func test_restored_active_slot_resolves_secondary_and_legacy_phase_durations() -> void:
	var fixture := _combat_fixture(true, "77")
	var combat: CombatComponent = fixture["combat"]
	var primary: AttackDefinition = fixture["primary"]
	var secondary: AttackDefinition = fixture["secondary"]
	primary.active_time = 0.44
	secondary.active_time = 0.77
	secondary.recovery_time = 0.88
	combat.current_attack_state = CombatComponent.AttackState.STARTUP
	combat._state_timer = 0.0
	combat._active_attack = primary
	combat._active_attack_slot = 2
	combat._update_attack_state(0.1, 50)
	assert_eq(combat.current_attack_state, CombatComponent.AttackState.ACTIVE)
	assert_almost_eq(combat._state_timer, 0.77, 0.0001,
		"Restored secondary slot must override stale cached primary duration")

	combat.current_attack_state = CombatComponent.AttackState.ACTIVE
	combat._state_timer = 0.0
	combat._active_attack = secondary
	combat._active_attack_slot = 0
	combat._update_attack_state(0.1, 51)
	assert_eq(combat.current_attack_state, CombatComponent.AttackState.RECOVERY)
	assert_null(combat._active_attack,
		"Restored slot 0 must clear a stale cached secondary resource")
	assert_almost_eq(combat._state_timer, 0.3, 0.0001,
		"Legacy fallback without an active slot keeps existing duration")

func test_restored_secondary_slot_dispatches_secondary_projectile_definition() -> void:
	var fixture := _combat_fixture(true, "77")
	var combat: CombatComponent = fixture["combat"]
	var projectiles: Node = fixture["projectiles"]
	var primary: AttackDefinition = fixture["primary"]
	var secondary: AttackDefinition = fixture["secondary"]
	primary.base_damage = 11.0
	primary.projectile_speed = 21.0
	secondary.base_damage = 17.0
	secondary.projectile_speed = 37.0
	combat.sync_attack_count = 10
	combat._active_attack = primary
	combat._active_attack_slot = 2
	combat._on_attack_active(60)
	assert_eq(projectiles.get_child_count(), 1)
	var projectile: SpawnProbeProjectile = projectiles.get_child(0)
	assert_almost_eq(projectile.initialized_damage, 17.0, 0.0001,
		"Restored secondary slot must dispatch secondary projectile damage despite stale primary cache")
	assert_almost_eq(projectile.initialized_speed, 37.0, 0.0001,
		"Restored secondary slot must dispatch secondary projectile speed despite stale primary cache")

func _combat_fixture(server_mode: bool, entity_name: String) -> Dictionary:
	if server_mode:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var world := Node3D.new()
	add_child_autofree(world)
	var projectiles := Node3D.new()
	projectiles.name = "Projectiles"
	world.add_child(projectiles)
	var entity := FakeEntity.new()
	entity.name = entity_name
	world.add_child(entity)
	var logic := FakeLogic.new()
	logic.name = "LogicComponent"
	entity.add_child(logic)
	var combat: CombatComponent = COMBAT_SCRIPT.new()
	combat.name = "CombatComponent"
	entity.add_child(combat)
	combat.entity = entity
	combat.logic = logic
	combat.configure(_projectile_attack(0.1), _projectile_attack(0.1))
	return {"world": world, "projectiles": projectiles, "entity": entity, "logic": logic, "combat": combat, "primary": combat._primary, "secondary": combat._secondary}

func _projectile_attack(startup: float) -> AttackDefinition:
	var probe := SpawnProbeProjectile.new()
	var scene := PackedScene.new()
	assert_eq(scene.pack(probe), OK, "Probe projectile scene should pack")
	probe.free()
	var attack := AttackDefinition.new()
	attack.attack_type = AttackDefinition.AttackType.PROJECTILE
	attack.projectile_scene = scene
	attack.projectile_speed = 20.0
	attack.base_damage = 5.0
	attack.startup_time = startup
	attack.active_time = 0.2
	attack.recovery_time = 0.3
	attack.cooldown = 0.0
	attack.charge_duration = 0.1
	attack.minimum_charge_multiplier = 1.0
	attack.maximum_charge_multiplier = 2.0
	return attack
