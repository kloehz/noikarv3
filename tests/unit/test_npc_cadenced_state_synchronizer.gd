extends GutTest

const CADENCED_SYNC_PATH := "res://common/net/CadencedStateSynchronizer.gd"
const VENDOR_STATE_SYNC_PATH := "res://addons/netfox/state-synchronizer.gd"
const ENEMY_SCENE := preload("res://scenes/EnemyEntity.tscn")
const PET_SCENE := preload("res://scenes/PetEntity.tscn")
const BASE_ENTITY_SCENE := preload("res://scenes/BaseEntity.tscn")
const MAIN_SCENE := preload("res://scenes/main.tscn")

var _cadenced_sync_script: Script

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_cadenced_sync_script = load(CADENCED_SYNC_PATH)

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _free_visibility_filter(sync: StateSynchronizer) -> void:
	var filter: Node = sync.visibility_filter
	if is_instance_valid(filter) and filter.get_parent() == null:
		filter.free()

func _make_sync(root_name: String, stride: int = 2) -> StateSynchronizer:
	assert_not_null(_cadenced_sync_script, "CadencedStateSynchronizer script should load")
	var root := Node3D.new()
	root.name = root_name
	root.set_multiplayer_authority(1)
	add_child_autofree(root)

	var sync: StateSynchronizer = _cadenced_sync_script.call("new") as StateSynchronizer
	sync.name = "StateSynchronizer"
	sync.root = root
	var properties: Array[String] = [":global_position"]
	sync.properties = properties
	sync.set("authority_snapshot_stride", stride)
	root.add_child(sync)
	sync.process_settings()
	return sync

func test_authority_records_snapshots_only_on_its_cadence_phase() -> void:
	var sync := _make_sync("MOB_CADENCE")
	var phase: int = sync.call("get_authority_snapshot_phase")
	var cadence_tick := phase
	var skipped_tick := phase + 1
	if skipped_tick % int(sync.get("authority_snapshot_stride")) == phase:
		skipped_tick += 1

	sync.root.global_position = Vector3(1, 0, 0)
	sync._after_tick(1.0 / 30.0, skipped_tick)
	assert_false(sync._state_history.has(skipped_tick),
		"Authority non-cadence ticks must not submit authority snapshots")

	sync.root.global_position = Vector3(2, 0, 0)
	sync._after_tick(1.0 / 30.0, cadence_tick)
	assert_true(sync._state_history.has(cadence_tick),
		"Authority cadence ticks must delegate to StateSynchronizer and record a snapshot")

func test_authority_phase_is_deterministic_and_within_stride_bounds() -> void:
	var a := _cadenced_sync_script.call("new") as StateSynchronizer
	var b := _cadenced_sync_script.call("new") as StateSynchronizer
	var c := _cadenced_sync_script.call("new") as StateSynchronizer
	var root_a := Node3D.new()
	var root_b := Node3D.new()
	var root_c := Node3D.new()
	root_a.name = "MOB_PHASE_A"
	root_b.name = "MOB_PHASE_A"
	root_c.name = "MOB_PHASE_B"
	a.root = root_a
	b.root = root_b
	c.root = root_c
	a.set("authority_snapshot_stride", 3)
	b.set("authority_snapshot_stride", 3)
	c.set("authority_snapshot_stride", 3)
	a.process_settings()
	b.process_settings()
	c.process_settings()
	var phase_a: int = a.call("get_authority_snapshot_phase")
	var phase_b: int = b.call("get_authority_snapshot_phase")
	var phase_c: int = c.call("get_authority_snapshot_phase")
	_free_visibility_filter(a)
	_free_visibility_filter(b)
	_free_visibility_filter(c)
	a.free()
	b.free()
	c.free()
	root_a.free()
	root_b.free()
	root_c.free()

	assert_between(phase_a, 0, 2,
		"Phase must be inside [0, stride)")
	assert_eq(phase_a, phase_b,
		"Phase must be deterministic for the same root identity")
	assert_between(phase_c, 0, 2,
		"Every scattered phase must remain inside [0, stride)")

func test_client_forwards_every_tick_to_base_state_synchronizer() -> void:
	var sync := _make_sync("MOB_CLIENT")
	sync.root.set_multiplayer_authority(1)
	sync.set_multiplayer_authority(2)

	sync.root.global_position = Vector3(4, 0, 0)
	var snapshot := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(101, snapshot)
	sync.root.global_position = Vector3.ZERO
	sync.root.set_multiplayer_authority(2)
	sync._after_tick(1.0 / 30.0, 101)

	assert_eq(sync.root.global_position, Vector3(4, 0, 0),
		"Non-authority clients must delegate every tick so received history applies normally")

func test_signal_connect_and_disconnect_are_symmetric_and_race_safe() -> void:
	var sync := _make_sync("MOB_SIGNAL")
	sync._disconnect_signals()
	sync._connect_signals()
	sync._connect_signals()
	assert_true(NetworkTime.after_tick.is_connected(sync._after_tick),
		"Signal connection should be present after repeated safe connects")
	assert_true(NetworkTime.after_tick_loop.is_connected(sync._after_loop),
		"after_tick_loop connection should be present after repeated safe connects")

	sync._disconnect_signals()
	sync._disconnect_signals()
	assert_false(NetworkTime.after_tick.is_connected(sync._after_tick),
		"Signal disconnect should be safe and complete after repeated disconnects")
	assert_false(NetworkTime.after_tick_loop.is_connected(sync._after_loop),
		"after_tick_loop disconnect should be safe and complete after repeated disconnects")

func _object_has_property(object: Object, property_name: String) -> bool:
	for property in object.get_property_list():
		if String(property.get("name", "")) == property_name:
			return true
	return false

func test_enemy_pet_and_match_state_sync_policy_keeps_visible_movement_per_tick() -> void:
	assert_not_null(_cadenced_sync_script, "CadencedStateSynchronizer script should load")
	var vendor_sync_script := load(VENDOR_STATE_SYNC_PATH)
	assert_not_null(vendor_sync_script, "Vendor StateSynchronizer script should load")
	var enemy := ENEMY_SCENE.instantiate()
	var pet := PET_SCENE.instantiate()
	var player := BASE_ENTITY_SCENE.instantiate()
	var main := MAIN_SCENE.instantiate()

	var enemy_sync := enemy.get_node("ServerState/StateSynchronizer")
	var pet_sync := pet.get_node("ServerState/StateSynchronizer")
	var player_sync := player.get_node("ServerState/StateSynchronizer")
	var match_sync := main.get_node("MatchState/StateSynchronizer")

	assert_true(enemy_sync.get_script() == vendor_sync_script,
		"EnemyEntity must use vendor StateSynchronizer so TickInterpolator receives every 30 Hz network tick")
	assert_true(pet_sync.get_script() == vendor_sync_script,
		"PetEntity must use vendor StateSynchronizer so TickInterpolator receives every 30 Hz network tick")
	assert_false(_object_has_property(enemy_sync, "authority_snapshot_stride"),
		"EnemyEntity must not apply authority snapshot cadence to visible movement")
	assert_false(_object_has_property(pet_sync, "authority_snapshot_stride"),
		"PetEntity must not apply authority snapshot cadence to visible movement")
	assert_false(player_sync.get_script() == _cadenced_sync_script,
		"BaseEntity/player synchronizer must remain vanilla StateSynchronizer")
	assert_true(match_sync.get_script() == _cadenced_sync_script,
		"MatchState must use the reusable authority-only cadenced synchronizer")
	assert_eq(match_sync.get("authority_snapshot_stride"), 6,
		"MatchState must submit low-frequency server-owned snapshots every 6 network ticks")
	var default_sync := _cadenced_sync_script.call("new") as StateSynchronizer
	assert_eq(default_sync.get("authority_snapshot_stride"), 2,
		"CadencedStateSynchronizer default remains the safe generic stride")
	_free_visibility_filter(default_sync)
	default_sync.free()
	assert_false(_object_has_property(player_sync, "authority_snapshot_stride"),
		"BaseEntity/player vanilla StateSynchronizer must not receive authority cadence policy")
	var expected_transform_properties: Array[String] = [":global_position", ":quaternion"]
	assert_eq(enemy_sync.properties, expected_transform_properties,
		"Enemy visible movement sync should stay reduced to transform snapshots only")
	assert_eq(pet_sync.properties, expected_transform_properties,
		"Pet visible movement sync should stay reduced to transform snapshots only")
	assert_eq(enemy_sync.full_state_interval, 12,
		"Enemy full_state_interval stays at the existing value")
	assert_eq(pet_sync.full_state_interval, 12,
		"Pet full_state_interval stays at the existing value")
	_free_visibility_filter(enemy_sync)
	_free_visibility_filter(pet_sync)
	_free_visibility_filter(player_sync)
	_free_visibility_filter(match_sync)
	enemy.free()
	pet.free()
	player.free()
	main.free()
