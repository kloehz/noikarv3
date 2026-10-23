@tool
extends "res://addons/netfox/tick-interpolator.gd"
class_name NpcTickInterpolator

const MAX_RENDER_DELAY_TICKS := 4.0
const BUFFER_SCRIPT := preload("res://common/net/NpcSnapshotBuffer.gd")

@export_range(1, 3, 1)
var npc_snapshot_stride: int = 1:
	set(value):
		npc_snapshot_stride = clampi(value, 1, 3)

var _snapshot_buffer = BUFFER_SCRIPT.new()
var _state_synchronizer: Node
var _was_sparse_mode := false
var _last_sparse_network_tick := -1
var _minimum_fresh_source_tick := -1
var _history_authority_id := -1

func process_settings():
	super.process_settings()
	_resolve_state_synchronizer()
	_get_effective_snapshot_stride()
	_reset_mode_transition_state(false)
	_was_sparse_mode = _compute_sparse_mode()

func teleport() -> void:
	if _snapshot_buffer.latest_tick >= 0:
		_minimum_fresh_source_tick = max(_minimum_fresh_source_tick, _snapshot_buffer.latest_tick)
	_snapshot_buffer.reset()
	super.teleport()

func _connect_signals() -> void:
	if not NetworkTime.before_tick_loop.is_connected(_before_tick_loop):
		NetworkTime.before_tick_loop.connect(_before_tick_loop)
	if not NetworkTime.after_tick_loop.is_connected(_after_tick_loop):
		NetworkTime.after_tick_loop.connect(_after_tick_loop)

func _disconnect_signals() -> void:
	if NetworkTime.before_tick_loop.is_connected(_before_tick_loop):
		NetworkTime.before_tick_loop.disconnect(_before_tick_loop)
	if NetworkTime.after_tick_loop.is_connected(_after_tick_loop):
		NetworkTime.after_tick_loop.disconnect(_after_tick_loop)

func _before_tick_loop() -> void:
	if _uses_sparse_mode():
		_is_teleporting = false
		return
	super._before_tick_loop()

func _after_tick_loop() -> void:
	if _uses_sparse_mode():
		var current_tick := int(NetworkTime.tick)
		if _last_sparse_network_tick >= 0 and current_tick < _last_sparse_network_tick:
			_snapshot_buffer.reset()
			_minimum_fresh_source_tick = -1
			if _state_synchronizer != null and _state_synchronizer.has_method("reset_client_history_epoch"):
				_state_synchronizer.call("reset_client_history_epoch")
		_last_sparse_network_tick = current_tick
		if enable_recording:
			_push_sparse_history_sample(current_tick)
		return
	super._after_tick_loop()

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var buffered := _uses_sparse_mode()
	if not multiplayer.has_multiplayer_peer() or not is_instance_valid(root) or not can_interpolate():
		return
	if not buffered:
		super._process(delta)
		return
	var pose: Dictionary = _snapshot_buffer.advance(delta * NetworkTime.tickrate, MAX_RENDER_DELAY_TICKS)
	_apply_buffered_pose(pose)

func _uses_sparse_mode() -> bool:
	var sparse := _compute_sparse_mode()
	var authority_id := root.get_multiplayer_authority() if is_instance_valid(root) else -1
	if sparse != _was_sparse_mode or authority_id != _history_authority_id:
		_reset_mode_transition_state(sparse)
		_was_sparse_mode = sparse
		_history_authority_id = authority_id
	return sparse

func _compute_sparse_mode() -> bool:
	if not multiplayer.has_multiplayer_peer():
		return false
	if not is_instance_valid(root):
		return false
	# Historical method name retained for diagnostics. All remote NPC rates now
	# use the source-time buffer; only authority uses tick-local interpolation.
	return enabled and not root.is_multiplayer_authority()

func _get_effective_snapshot_stride() -> int:
	if _state_synchronizer == null:
		_resolve_state_synchronizer()
	if _state_synchronizer != null and _state_synchronizer.has_method("get_effective_snapshot_stride"):
		npc_snapshot_stride = int(_state_synchronizer.call("get_effective_snapshot_stride"))
	return maxi(1, npc_snapshot_stride)

func _reset_mode_transition_state(_sparse: bool) -> void:
	# Settings/authority changes invalidate presentation, not the synchronizer's
	# retained packets. Fence those packets so the next ingestion cannot replay
	# an obsolete pose. A network clock rewind explicitly starts a new epoch.
	var fence := maxi(_minimum_fresh_source_tick, _snapshot_buffer.latest_tick)
	if is_instance_valid(_state_synchronizer):
		fence = maxi(fence, int(_state_synchronizer.call("get_latest_received_tick")))
	_snapshot_buffer.reset()
	_last_sparse_network_tick = -1
	_minimum_fresh_source_tick = fence
	_state_from = _PropertySnapshot.new()
	_state_to = _PropertySnapshot.new()
	_is_teleporting = false
	_history_authority_id = root.get_multiplayer_authority() if is_instance_valid(root) else -1

func _resolve_state_synchronizer() -> void:
	_state_synchronizer = null
	if root == null:
		return
	var server_state := root.get_node_or_null("ServerState")
	if server_state:
		var sync := server_state.get_node_or_null("StateSynchronizer")
		if sync != null and sync.has_method("get_latest_received_transform_tick"):
			_state_synchronizer = sync

func _push_sparse_history_sample(tick: int) -> void:
	if _state_synchronizer == null:
		_resolve_state_synchronizer()
	if _state_synchronizer == null:
		return
	var after_tick := maxi(_minimum_fresh_source_tick, _snapshot_buffer.latest_tick)
	var samples: Array = _state_synchronizer.call("get_received_transform_samples", after_tick, tick)
	for sample in samples:
		var snapshot: _PropertySnapshot = sample.snapshot
		var position_path := _find_snapshot_property(snapshot, ":global_position")
		var rotation_path := _find_snapshot_property(snapshot, ":quaternion")
		if position_path.is_empty() or rotation_path.is_empty():
			continue
		_snapshot_buffer.push_snapshot(sample.tick, snapshot.get_value(position_path), snapshot.get_value(rotation_path))

func _render_sparse_pose_at(render_tick: float) -> void:
	var pose: Dictionary = _snapshot_buffer.sample(render_tick)
	_apply_buffered_pose(pose)

func _apply_buffered_pose(pose: Dictionary) -> void:
	if pose.is_empty() or not is_instance_valid(root):
		return
	root.global_position = pose.position
	root.quaternion = pose.rotation

func _find_snapshot_property(snapshot: _PropertySnapshot, suffix: String) -> String:
	for property_path in snapshot.properties():
		var path := String(property_path)
		if path == suffix or path.ends_with(suffix):
			return path
	return ""
