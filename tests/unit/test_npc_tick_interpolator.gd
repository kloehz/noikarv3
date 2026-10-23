extends GutTest

const NPC_SYNC_PATH := "res://common/net/NpcStateSynchronizer.gd"
const NPC_INTERPOLATOR_PATH := "res://common/net/NpcTickInterpolator.gd"

var _previous_peer: MultiplayerPeer
var _previous_diff_states: bool
var _sync_script: Script
var _interpolator_script: Script
var _previous_tick: int

func before_each() -> void:
	_previous_peer = multiplayer.multiplayer_peer
	_previous_tick = NetworkTime.tick
	_previous_diff_states = NetworkRollback.enable_diff_states
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	NetworkRollback.enable_diff_states = true
	_sync_script = load(NPC_SYNC_PATH)
	_interpolator_script = load(NPC_INTERPOLATOR_PATH)

func after_each() -> void:
	NetworkTime.set("_tick", _previous_tick)
	NetworkRollback.enable_diff_states = _previous_diff_states
	multiplayer.multiplayer_peer = _previous_peer

func _make_client_pair(stride: int = 3) -> Dictionary:
	var root := Node3D.new()
	root.name = "MOB_RENDER"
	root.set_multiplayer_authority(2)
	var state := ServerState.new()
	state.name = "ServerState"
	state.npc_snapshot_stride = stride
	root.add_child(state)
	var sync := _sync_script.new() as StateSynchronizer
	sync.name = "StateSynchronizer"
	sync.root = root
	sync.properties = [":global_position", ":quaternion", "ServerState:npc_snapshot_stride"]
	sync.set_multiplayer_authority(2)
	state.add_child(sync)
	var interpolator := _interpolator_script.new() as TickInterpolator
	interpolator.name = "TickInterpolator"
	interpolator.root = root
	interpolator.properties = [":global_position", ":quaternion"]
	interpolator.set_multiplayer_authority(2)
	root.add_child(interpolator)
	add_child_autofree(root)
	root.set_multiplayer_authority(2, true)
	sync.process_settings()
	sync.set("npc_snapshot_stride", stride)
	interpolator.process_settings()
	return {"root": root, "state": state, "sync": sync, "interpolator": interpolator}

func _snapshot_at(sync: StateSynchronizer, tick: int, position: Vector3, stride: int = 3) -> void:
	var root := sync.root as Node3D
	var state := sync.get_parent() as ServerState
	root.global_position = position
	root.quaternion = Quaternion.IDENTITY
	state.npc_snapshot_stride = stride
	var snapshot := _PropertySnapshot.extract(sync._property_config.get_properties())
	sync._state_history.set_snapshot(tick, snapshot)

func test_sparse_mode_uses_received_synchronizer_stride_not_local_interpolator_knob() -> void:
	var pair := _make_client_pair(3)
	var interpolator := pair.interpolator as TickInterpolator
	assert_eq(interpolator.get("npc_snapshot_stride"), 3, "Process settings mirrors the cached synchronizer stride instead of using an independent local knob")
	assert_eq(interpolator.call("_get_effective_snapshot_stride"), 3, "Cached synchronizer exposes authoritative received stride")
	assert_false((pair.root as Node3D).is_multiplayer_authority(), "Test fixture simulates a client-side NPC root")
	assert_true(interpolator.call("_uses_sparse_mode"), "Client sparse mode must follow cached NpcStateSynchronizer effective stride")

func test_sparse_mode_is_disabled_without_multiplayer_peer() -> void:
	var pair := _make_client_pair(3)
	var interpolator := pair.interpolator as TickInterpolator
	multiplayer.multiplayer_peer = null

	assert_false(interpolator.call("_compute_sparse_mode"), "Sparse client interpolation must not query authority state without a multiplayer peer")

func test_sparse_mode_ignores_invalid_root_when_checking_authority() -> void:
	var interpolator := _interpolator_script.new() as TickInterpolator
	var stale_root := Node3D.new()
	interpolator.root = stale_root
	interpolator.properties = [":global_position", ":quaternion"]
	stale_root.free()
	add_child_autofree(interpolator)

	assert_false(interpolator.call("_compute_sparse_mode"), "Invalid root references must not be dereferenced for sparse authority detection")

func test_sparse_samples_interpolate_fractional_positions_between_source_ticks() -> void:
	var pair := _make_client_pair(3)
	var root := pair.root as Node3D
	var sync := pair.sync as StateSynchronizer
	var interpolator := pair.interpolator as TickInterpolator
	_snapshot_at(sync, 0, Vector3.ZERO)
	_snapshot_at(sync, 3, Vector3(3, 0, 0))
	interpolator.call("_push_sparse_history_sample", 0)
	interpolator.call("_push_sparse_history_sample", 3)
	interpolator.call("_render_sparse_pose_at", 1.5)

	assert_true(root.global_position.distance_to(Vector3(1.5, 0, 0)) <= 0.001,
		"Sparse renderer must interpolate between authoritative source ticks, not step at packet cadence")

func test_sparse_mode_has_single_transform_writer_no_legacy_before_after_snapshots() -> void:
	var pair := _make_client_pair(3)
	var root := pair.root as Node3D
	var sync := pair.sync as StateSynchronizer
	var interpolator := pair.interpolator as TickInterpolator
	_snapshot_at(sync, 0, Vector3.ZERO)
	_snapshot_at(sync, 3, Vector3(3, 0, 0))
	interpolator._state_from.set_value(":global_position", Vector3(99, 0, 0))
	interpolator._state_to.set_value(":global_position", Vector3(99, 0, 0))

	interpolator._before_tick_loop()
	interpolator._after_tick_loop()
	interpolator.call("_push_sparse_history_sample", 0)
	interpolator.call("_push_sparse_history_sample", 3)
	interpolator.call("_render_sparse_pose_at", 1.5)

	assert_ne(root.global_position, Vector3(99, 0, 0), "Sparse mode must not apply legacy before/after TickInterpolator endpoints")
	assert_true(root.global_position.distance_to(Vector3(1.5, 0, 0)) <= 0.001)

func test_network_time_rewind_resets_sync_epoch_and_accepts_fresh_low_snapshot() -> void:
	var pair := _make_client_pair(3)
	var root := pair.root as Node3D
	var state := pair.state as ServerState
	var sync := pair.sync as StateSynchronizer
	var interpolator := pair.interpolator as TickInterpolator
	_snapshot_at(sync, 90, Vector3(90, 0, 0), 3)
	interpolator.call("_push_sparse_history_sample", 90)
	interpolator.call("_render_sparse_pose_at", 90.0)
	state.npc_snapshot_stride = 3
	state.sync_health = 22
	sync.call("_apply_sparse_client_tick", 90)
	state.sync_health = 5

	NetworkTime.set("_tick", 4)
	interpolator.set("_last_sparse_network_tick", 90)
	interpolator.call("_after_tick_loop")
	state.sync_health = 22
	_snapshot_at(sync, 4, Vector3(4, 0, 0), 3)
	state.sync_health = 5
	sync.call("_apply_sparse_client_tick", 4)
	interpolator.call("_push_sparse_history_sample", 4)
	interpolator.call("_render_sparse_pose_at", 4.0)

	assert_eq(state.sync_health, 22, "Renderer network-time rewind must reset the synchronizer history cursor for fresh low complete snapshots")
	assert_eq(root.global_position, Vector3(4, 0, 0))

func test_sparse_teleport_discard_replayed_consumed_source_tick_until_new_source_arrives() -> void:
	var pair := _make_client_pair(3)
	var root := pair.root as Node3D
	var sync := pair.sync as StateSynchronizer
	var interpolator := pair.interpolator as TickInterpolator
	_snapshot_at(sync, 30, Vector3(30, 0, 0), 3)
	interpolator.call("_push_sparse_history_sample", 30)
	interpolator.call("_render_sparse_pose_at", 30.0)
	root.global_position = Vector3(100, 0, 0)
	interpolator.teleport()
	interpolator.call("_push_sparse_history_sample", 30)
	interpolator.call("_render_sparse_pose_at", 30.0)
	assert_eq(root.global_position, Vector3(100, 0, 0), "Replayed pre-teleport source history must not snap the renderer back")

	_snapshot_at(sync, 33, Vector3(33, 0, 0), 3)
	interpolator.call("_push_sparse_history_sample", 33)
	interpolator.call("_render_sparse_pose_at", 33.0)
	assert_eq(root.global_position, Vector3(33, 0, 0), "Fresh post-teleport source history must still be accepted")

func test_authority_transition_resets_buffer_and_legacy_endpoints() -> void:
	var pair := _make_client_pair(3)
	var root := pair.root as Node3D
	var state := pair.state as ServerState
	var sync := pair.sync as StateSynchronizer
	var interpolator := pair.interpolator as TickInterpolator
	_snapshot_at(sync, 0, Vector3.ZERO, 3)
	_snapshot_at(sync, 3, Vector3(3, 0, 0), 3)
	interpolator.call("_push_sparse_history_sample", 3)
	root.set_multiplayer_authority(1, true)
	interpolator.call("_uses_sparse_mode")
	root.set_multiplayer_authority(2, true)
	interpolator.call("_uses_sparse_mode")
	root.global_position = Vector3(20, 0, 0)

	interpolator.call("_render_sparse_pose_at", 1.5)

	assert_eq(root.global_position, Vector3(20, 0, 0), "Mode switches must clear stale sparse samples before new packets arrive")

func test_full_rate_remote_also_uses_timestamp_buffer() -> void:
	var pair := _make_client_pair(1)
	assert_true(pair.interpolator.call("_uses_sparse_mode"), "Full-rate NPCs need source-time buffering too")

func test_full_rate_packet_pairs_do_not_hold_then_double_render_speed_with_clock_lead() -> void:
	_assert_batched_motion(2)

func test_five_tick_bursts_build_bounded_jitter_reserve_without_repeated_freezes() -> void:
	_assert_batched_motion(5)

func _assert_batched_motion(batch_size: int) -> void:
	var pair := _make_client_pair(1)
	var sync := pair.sync as StateSynchronizer
	var interpolator := pair.interpolator as TickInterpolator
	var entity := pair.root as Node3D
	var previous := 0.0
	var steps: Array[float] = []
	for tick in range(120):
		var rendered_position := entity.global_position
		if tick % batch_size == 0:
			for source_tick in range(maxi(0, tick - batch_size + 1), tick + 1):
				_snapshot_at(sync, source_tick, Vector3(source_tick * 0.1, 0, 0), 1)
		entity.global_position = rendered_position
		NetworkTime.set("_tick", tick + 20)
		interpolator._before_tick_loop()
		sync._after_tick(1.0 / 30.0, tick + 20)
		interpolator._after_tick_loop()
		for subframe in range(4):
			interpolator._process(1.0 / 120.0)
			var current := entity.position.x
			if tick >= 60: steps.append(current - previous)
			previous = current
	assert_lte(float(steps.max()), 0.0301, "No one-tick catch-up bursts above 1.2x source speed")
	assert_gt(float(steps.min()), 0.019, "Buffered steady motion does not freeze on missing local ticks")
	assert_gt(entity.position.x, 3.0, "The renderer must actually advance, not pass by freezing")

func test_history_batch_retains_intermediate_turn_in_same_packet_burst() -> void:
	var pair := _make_client_pair(1)
	_snapshot_at(pair.sync, 10, Vector3.ZERO, 1)
	_snapshot_at(pair.sync, 11, Vector3(1, 0, 0), 1)
	_snapshot_at(pair.sync, 12, Vector3(1, 0, 1), 1)
	pair.interpolator.call("_push_sparse_history_sample", 12)
	pair.interpolator.call("_render_sparse_pose_at", 11.0)
	assert_eq(pair.root.global_position, Vector3(1, 0, 0), "All newly received source samples must survive batching")

func test_stride_change_does_not_reset_continuous_source_history() -> void:
	var pair := _make_client_pair(3)
	_snapshot_at(pair.sync, 0, Vector3.ZERO, 3)
	pair.interpolator.call("_push_sparse_history_sample", 0)
	_snapshot_at(pair.sync, 3, Vector3(3, 0, 0), 1)
	pair.state.npc_snapshot_stride = 1
	pair.sync.set("npc_snapshot_stride", 1)
	assert_true(pair.interpolator.call("_uses_sparse_mode"))
	pair.interpolator.call("_push_sparse_history_sample", 3)
	pair.interpolator.call("_render_sparse_pose_at", 1.5)
	assert_eq(pair.root.global_position, Vector3(1.5, 0, 0), "Cadence changes must not discard playback history")

func test_disabled_or_no_peer_process_does_not_write_transform() -> void:
	var pair := _make_client_pair(1)
	_snapshot_at(pair.sync, 0, Vector3.ZERO, 1)
	pair.interpolator.call("_push_sparse_history_sample", 0)
	pair.interpolator.enabled = false
	pair.root.position = Vector3(7, 0, 0)
	pair.interpolator._process(0.1)
	assert_eq(pair.root.position, Vector3(7, 0, 0))
	multiplayer.multiplayer_peer = null
	pair.interpolator.enabled = true
	pair.interpolator._process(0.1)
	assert_eq(pair.root.position, Vector3(7, 0, 0))

func test_authority_change_rejects_reimported_previous_owner_history() -> void:
	_assert_lifecycle_history_fence(false)

func test_reconfiguration_rejects_reimported_pre_reset_history() -> void:
	_assert_lifecycle_history_fence(true)

func _assert_lifecycle_history_fence(reconfigure: bool) -> void:
	var pair := _make_client_pair(1)
	_snapshot_at(pair.sync, 30, Vector3(3, 0, 0), 1)
	pair.interpolator.call("_push_sparse_history_sample", 30)
	pair.interpolator.call("_render_sparse_pose_at", 30.0)
	if reconfigure:
		pair.interpolator.process_settings()
	else:
		pair.root.set_multiplayer_authority(3, true)
		pair.interpolator.call("_uses_sparse_mode")
	pair.root.position = Vector3(20, 0, 0)
	pair.interpolator.call("_push_sparse_history_sample", 30)
	pair.interpolator.call("_render_sparse_pose_at", 30.0)
	assert_eq(pair.root.position, Vector3(20, 0, 0), "A lifecycle reset must fence retained synchronizer history")
	_snapshot_at(pair.sync, 31, Vector3(4, 0, 0), 1)
	pair.interpolator.call("_push_sparse_history_sample", 31)
	pair.interpolator.call("_render_sparse_pose_at", 31.0)
	assert_eq(pair.root.position, Vector3(4, 0, 0), "Fresh source packets resume rendering after the boundary")
