extends GutTest

const NPC_SYNC_PATH := "res://common/net/NpcStateSynchronizer.gd"
const VENDOR_SYNC_SCRIPT := preload("res://addons/netfox/state-synchronizer.gd")
const ENEMY_SCENE := preload("res://scenes/EnemyEntity.tscn")
const PET_SCENE := preload("res://scenes/PetEntity.tscn")

var _previous_peer: MultiplayerPeer
var _previous_diff_states: bool
var _npc_sync_script: Script

func before_each() -> void:
	_previous_peer = multiplayer.multiplayer_peer
	_previous_diff_states = NetworkRollback.enable_diff_states
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkRollback.set("enable_diff_states", true)
	_npc_sync_script = load(NPC_SYNC_PATH)

func after_each() -> void:
	NetworkRollback.enable_diff_states = _previous_diff_states
	multiplayer.multiplayer_peer = _previous_peer

func _make_sync(root_name: String, stride: int = 1) -> StateSynchronizer:
	var root := Node3D.new()
	root.name = root_name
	root.set_multiplayer_authority(1)
	var state := ServerState.new()
	state.name = "ServerState"
	state.npc_snapshot_stride = stride
	root.add_child(state)
	var sync := _npc_sync_script.call("new") as StateSynchronizer
	sync.name = "StateSynchronizer"
	sync.root = root
	var properties: Array[String] = [":global_position", ":quaternion", "ServerState:sync_health", "ServerState:npc_snapshot_stride"]
	sync.properties = properties
	state.add_child(sync)
	add_child_autofree(root)
	state.npc_snapshot_stride = stride
	sync.process_settings()
	return sync

func test_extends_vendor_state_synchronizer_and_defaults_to_every_tick() -> void:
	var sync := _make_sync("MOB_DEFAULT")
	assert_true(sync is StateSynchronizer)
	assert_eq(sync.get("npc_snapshot_stride"), 1)
	sync.root.global_position = Vector3(1, 0, 0)
	sync._after_tick(1.0 / 30.0, 1)
	assert_true(sync._state_history.has(1), "Default stride 1 preserves every-tick vendor submission")

func test_stride_two_only_submits_on_deterministic_phase() -> void:
	var sync := _make_sync("MOB_PHASE", 2)
	var phase: int = sync.call("get_authority_snapshot_phase")
	sync.root.global_position = Vector3(1, 0, 0)
	sync._after_tick(1.0 / 30.0, phase)
	assert_true(sync._state_history.has(phase), "Cadence phase submits a complete vendor snapshot")
	phase = sync.call("get_authority_snapshot_phase")
	var offphase := phase + 1
	if posmod(offphase, 2) == phase:
		offphase += 1
	sync.root.global_position = Vector3(2, 0, 0)
	sync._after_tick(1.0 / 30.0, offphase)
	assert_false(sync._state_history.has(offphase), "Off-phase unchanged NPC snapshots are skipped after the baseline send")

func test_offphase_metadata_change_submits_complete_snapshot_immediately() -> void:
	var sync := _make_sync("MOB_EVENT", 3)
	var phase: int = sync.call("get_authority_snapshot_phase")
	var offphase := phase + 1
	while posmod(offphase, 3) == phase:
		offphase += 1
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 77
	sync.root.global_position = Vector3(7, 0, 0)
	sync._after_tick(1.0 / 30.0, offphase)
	assert_true(sync._state_history.has(offphase), "Metadata events bypass sparse cadence")
	var snapshot := sync._state_history.get_snapshot(offphase)
	assert_true(snapshot.has(":global_position"), "Event sends remain complete and include transform")
	assert_true(snapshot.has("ServerState:sync_health"), "Event sends include changed metadata")

func test_diff_disabled_falls_back_to_every_tick() -> void:
	NetworkRollback.enable_diff_states = false
	var sync := _make_sync("MOB_DIFF_DISABLED", 3)
	sync.root.global_position = Vector3(1, 0, 0)
	sync._after_tick(1.0 / 30.0, 1)
	assert_true(sync._state_history.has(1), "Sparse cadence is disabled when netfox diff states are disabled")

func test_first_sparse_packet_applies_metadata_before_sparse_mode_choice() -> void:
	var sync := _make_sync("MOB_FIRST_PACKET", 1)
	sync.root.set_multiplayer_authority(1)
	sync.set_multiplayer_authority(2)
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 77
	server_state.npc_snapshot_stride = 3
	sync.root.global_position = Vector3(9, 0, 0)
	var snapshot := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(30, snapshot)
	sync.root.global_position = Vector3.ZERO
	server_state.sync_health = 100
	server_state.npc_snapshot_stride = 1

	sync._after_tick(1.0 / 30.0, 30)

	assert_eq(server_state.sync_health, 77, "First sparse packet metadata must apply immediately")
	assert_eq(server_state.npc_snapshot_stride, 3, "Received stride metadata must be applied before sparse/default branch choice")
	assert_eq(sync.get("npc_snapshot_stride"), 3, "Synchronizer follows received authoritative stride")
	assert_eq(sync.root.global_position, Vector3.ZERO, "Sparse first packet must not vendor-apply motion")

func test_client_metadata_apply_rejects_older_history_rewind() -> void:
	var sync := _make_sync("MOB_METADATA_CURSOR", 3)
	sync.root.set_multiplayer_authority(1)
	sync.set_multiplayer_authority(2)
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 50
	server_state.npc_snapshot_stride = 3
	var newer := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(20, newer)
	server_state.sync_health = 10
	var older := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(10, older)
	server_state.sync_health = 1

	sync._after_tick(1.0 / 30.0, 20)
	assert_eq(server_state.sync_health, 50)
	sync._after_tick(1.0 / 30.0, 10)
	assert_eq(server_state.sync_health, 50, "Older sparse metadata must not rewind already-applied state")

func test_diff_disabled_advertises_wire_stride_one_for_npc_server_state() -> void:
	NetworkRollback.enable_diff_states = false
	var root := Node3D.new()
	root.name = "MOB_DIFF_WIRE"
	var state := ServerState.new()
	state.name = "ServerState"
	var sync := _npc_sync_script.call("new") as StateSynchronizer
	sync.name = "StateSynchronizer"
	sync.root = root
	state.add_child(sync)
	root.add_child(state)
	add_child_autofree(root)

	state._ready()

	assert_eq(state.npc_snapshot_stride, 1, "Global diff disabled must put stride 1 on the replicated ServerState property")
	assert_eq(sync.get("npc_snapshot_stride"), 1, "Global diff disabled must keep synchronizer wire cadence at baseline")

func test_pending_event_ack_drains_until_current_visible_peers_ack_event() -> void:
	var sync := _make_sync("MOB_ACK_DRAIN", 3)
	var server_state := sync.get_parent() as ServerState
	var event_tick := 11
	server_state.sync_health = 42
	sync.call("_record_post_submit_state_if_authority", event_tick, true)
	sync._ackd_state[2] = event_tick - 1
	sync._ackd_state[3] = event_tick
	sync.visibility_filter._visible_peers = [2, 3]
	assert_true(sync.call("_has_pending_event_ack"), "An older visible peer ack keeps the event drain active")
	sync._ackd_state[2] = event_tick
	assert_false(sync.call("_has_pending_event_ack"), "All current visible peers caught up stops the drain")
	sync._ackd_state[2] = event_tick - 1
	sync.visibility_filter._visible_peers = [3]
	assert_false(sync.call("_has_pending_event_ack"), "Peers leaving visibility stop blocking the current drain")

func test_client_epoch_reset_accepts_fresh_low_complete_snapshot() -> void:
	var sync := _make_sync("MOB_EPOCH_RESET", 3)
	sync.root.set_multiplayer_authority(1)
	sync.set_multiplayer_authority(2)
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 90
	server_state.npc_snapshot_stride = 3
	var high := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(90, high)
	server_state.sync_health = 1
	sync._after_tick(1.0 / 30.0, 90)
	assert_eq(server_state.sync_health, 90)

	sync.call("reset_client_history_epoch")
	server_state.sync_health = 44
	server_state.npc_snapshot_stride = 3
	sync.root.global_position = Vector3(4, 0, 0)
	var fresh_low := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(5, fresh_low)
	server_state.sync_health = 2
	server_state.npc_snapshot_stride = 1

	sync._after_tick(1.0 / 30.0, 5)

	assert_eq(server_state.sync_health, 44, "A complete low tick after a network-time epoch reset must not be blocked by the stale high cursor")
	assert_eq(server_state.npc_snapshot_stride, 3)

func test_client_epoch_reset_rejects_partial_diff_until_complete_snapshot_arrives() -> void:
	var sync := _make_sync("MOB_EPOCH_PARTIAL", 3)
	sync.root.set_multiplayer_authority(1)
	sync.set_multiplayer_authority(2)
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 100
	server_state.npc_snapshot_stride = 3
	var high := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(80, high)
	sync._after_tick(1.0 / 30.0, 80)
	sync.call("reset_client_history_epoch")

	var partial := _PropertySnapshot.new()
	partial.set_value("ServerState:sync_health", 12)
	sync._state_history.set_snapshot(4, partial)
	server_state.sync_health = 33
	server_state.npc_snapshot_stride = 1
	sync._after_tick(1.0 / 30.0, 4)
	assert_eq(server_state.sync_health, 33, "Partial diffs without a complete post-reset base must not apply metadata")
	assert_eq(server_state.npc_snapshot_stride, 1, "Partial diffs without a complete post-reset base must not switch modes")

	server_state.sync_health = 66
	server_state.npc_snapshot_stride = 3
	sync.root.global_position = Vector3(6, 0, 0)
	var complete := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(7, complete)
	server_state.sync_health = 33
	server_state.npc_snapshot_stride = 1
	sync._after_tick(1.0 / 30.0, 7)
	assert_eq(server_state.sync_health, 66, "Recovery resumes on the next complete snapshot")
	assert_eq(server_state.npc_snapshot_stride, 3)

func test_older_stride_metadata_cannot_flip_mode_or_reactivate_legacy_writer() -> void:
	var sync := _make_sync("MOB_OLD_STRIDE", 3)
	sync.root.set_multiplayer_authority(1)
	sync.set_multiplayer_authority(2)
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 77
	server_state.npc_snapshot_stride = 3
	var newer := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(30, newer)
	server_state.sync_health = 100
	server_state.npc_snapshot_stride = 1
	var older := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(20, older)

	sync._after_tick(1.0 / 30.0, 30)
	assert_eq(server_state.sync_health, 77)
	assert_eq(server_state.npc_snapshot_stride, 3)
	sync._after_tick(1.0 / 30.0, 20)

	assert_eq(server_state.sync_health, 77, "Older history must not rewind metadata")
	assert_eq(server_state.npc_snapshot_stride, 3, "Older stride metadata must not flip back to default mode")

func test_pending_event_ack_schedules_until_all_visible_peers_ack_event_tick() -> void:
	var sync := _make_sync("MOB_ACK_SCHEDULE", 3)
	var event_tick := 11
	sync.call("_record_post_submit_state_if_authority", event_tick, true)
	sync.visibility_filter._visible_peers = [2, 3]
	sync._ackd_state[2] = event_tick - 1
	sync._ackd_state[3] = event_tick - 1
	assert_true(sync.call("_has_pending_event_ack"), "Event remains pending until both visible peers ACK the event tick")
	sync._ackd_state[2] = event_tick
	assert_true(sync.call("_has_pending_event_ack"), "One current ACK is not enough while another visible peer is old")
	sync._ackd_state[3] = event_tick
	assert_false(sync.call("_has_pending_event_ack"), "Drain stops once all visible peers ACK at least the event tick")

	var phase: int = sync.call("get_authority_snapshot_phase")
	var offphase := phase + 1
	while posmod(offphase, 3) == phase:
		offphase += 1
	sync.visibility_filter._visible_peers = []
	var server_state := sync.get_parent() as ServerState
	server_state.sync_health = 56
	sync._after_tick(1.0 / 30.0, offphase)
	assert_true(sync._state_history.has(offphase), "The metadata event itself is submitted on an actual after_tick snapshot")

func test_pending_event_ack_handles_visibility_leave_and_no_visible_peers() -> void:
	var sync := _make_sync("MOB_ACK_LEAVE", 3)
	var event_tick := 11
	sync.call("_record_post_submit_state_if_authority", event_tick, true)
	sync._ackd_state[2] = event_tick - 1
	sync._ackd_state[3] = event_tick
	sync.visibility_filter._visible_peers = [2, 3]
	assert_true(sync.call("_has_pending_event_ack"))
	sync.visibility_filter._visible_peers = [3]
	assert_false(sync.call("_has_pending_event_ack"), "A peer leaving visibility no longer blocks event drain")
	sync.visibility_filter._visible_peers = []
	assert_false(sync.call("_has_pending_event_ack"), "No visible peers means no pending drain")

func test_enemy_and_pet_use_project_npc_adapters_not_vendor_scripts() -> void:
	var enemy := ENEMY_SCENE.instantiate()
	var pet := PET_SCENE.instantiate()
	var enemy_sync := enemy.get_node("ServerState/StateSynchronizer")
	var pet_sync := pet.get_node("ServerState/StateSynchronizer")
	var enemy_interpolator := enemy.get_node("TickInterpolator")
	var pet_interpolator := pet.get_node("TickInterpolator")
	assert_true(enemy_sync.get_script() == _npc_sync_script)
	assert_true(pet_sync.get_script() == _npc_sync_script)
	assert_false(enemy_sync.get_script() == VENDOR_SYNC_SCRIPT)
	assert_eq(enemy_sync.get("npc_snapshot_stride"), 1, "Default scene cadence remains 30 Hz")
	assert_eq(pet_sync.get("npc_snapshot_stride"), 1, "Default scene cadence remains 30 Hz")
	assert_eq(enemy_interpolator.get_script(), load("res://common/net/NpcTickInterpolator.gd"))
	assert_eq(pet_interpolator.get_script(), load("res://common/net/NpcTickInterpolator.gd"))
	enemy.free()
	pet.free()
