@tool
extends "res://addons/netfox/state-synchronizer.gd"
class_name NpcStateSynchronizer

const MOTION_PROPERTY_PATHS := [":global_position", ":quaternion"]

@export_range(1, 3, 1)
var npc_snapshot_stride: int = 1:
	set(value):
		npc_snapshot_stride = clampi(value, 1, 3)
		_recompute_authority_snapshot_phase()

var _authority_snapshot_phase: int = 0
var _last_sent_non_motion_values: Array = []
var _last_event_tick: int = -1
var _last_client_history_tick: int = -1
var _client_history_epoch_requires_complete: bool = false
var _motion_property_paths: Array[String] = []
var _non_motion_property_entries: Array[PropertyEntry] = []
var _non_motion_property_paths: Array[String] = []
var _server_state_parent: Node = null

func process_settings() -> void:
	super.process_settings()
	_server_state_parent = get_parent()
	_cache_property_paths()
	_sync_stride_from_server_state()
	_recompute_authority_snapshot_phase()
	if get_effective_snapshot_stride() > 1:
		_last_sent_non_motion_values = _read_non_motion_values()
	else:
		_last_sent_non_motion_values.clear()

func get_authority_snapshot_phase() -> int:
	return _authority_snapshot_phase

func get_effective_snapshot_stride() -> int:
	if not NetworkRollback.enable_diff_states:
		return 1
	return maxi(1, npc_snapshot_stride)

func should_submit_authority_snapshot(tick: int) -> bool:
	var stride := get_effective_snapshot_stride()
	return stride <= 1 or posmod(tick, stride) == _authority_snapshot_phase

func _connect_signals() -> void:
	if not is_inside_tree():
		return
	if not NetworkTime.after_tick.is_connected(_after_tick):
		NetworkTime.after_tick.connect(_after_tick)
	if not NetworkTime.after_tick_loop.is_connected(_after_loop):
		NetworkTime.after_tick_loop.connect(_after_loop)

func _disconnect_signals() -> void:
	if NetworkTime.after_tick.is_connected(_after_tick):
		NetworkTime.after_tick.disconnect(_after_tick)
	if NetworkTime.after_tick_loop.is_connected(_after_loop):
		NetworkTime.after_tick_loop.disconnect(_after_loop)

func get_latest_received_transform_tick(tick: int) -> int:
	if _state_history.is_empty():
		return -1
	var closest_tick: int = _state_history.get_closest_tick(tick)
	var snapshot := _state_history.get_snapshot(closest_tick)
	if snapshot == null or snapshot.is_empty():
		return -1
	if _client_history_epoch_requires_complete and not _is_complete_snapshot(snapshot):
		return -1
	for property_path in _motion_property_paths:
		if snapshot.has(property_path):
			return closest_tick
	return -1

func get_received_transform_snapshot(tick: int) -> _PropertySnapshot:
	var closest_tick := get_latest_received_transform_tick(tick)
	if closest_tick < 0:
		return _PropertySnapshot.new()
	return _state_history.get_snapshot(closest_tick)

func _after_tick(dt: float, tick: int) -> void:
	_sync_stride_from_server_state()
	var eligible_metadata_tick := -1
	if not is_multiplayer_authority():
		eligible_metadata_tick = _apply_received_stride_metadata(tick)
	var stride := get_effective_snapshot_stride()
	if stride <= 1:
		if not is_multiplayer_authority() and _client_history_epoch_requires_complete and eligible_metadata_tick < 0:
			return
		super._after_tick(dt, tick)
		if not is_multiplayer_authority() and eligible_metadata_tick >= 0:
			_accept_client_history_tick(eligible_metadata_tick)
		_record_post_submit_state_if_authority(tick, false)
		return

	if is_multiplayer_authority():
		var has_event := _has_non_motion_event()
		if should_submit_authority_snapshot(tick) or has_event or _has_pending_event_ack():
			super._after_tick(dt, tick)
			_record_post_submit_state_if_authority(tick, has_event)
		return

	_apply_sparse_client_tick(tick)

func _apply_sparse_client_tick(tick: int) -> void:
	var closest_tick := _get_eligible_client_history_tick(tick)
	if closest_tick < 0:
		return
	var snapshot := _state_history.get_snapshot(closest_tick)
	var metadata := _PropertySnapshot.new()
	for property_path in snapshot.properties():
		if not _is_motion_property(property_path):
			metadata.set_value(property_path, snapshot.get_value(property_path))
	if not metadata.is_empty():
		metadata.apply(_property_cache)
	_accept_client_history_tick(closest_tick)

func _record_post_submit_state_if_authority(tick: int, mark_event: bool) -> void:
	if not is_multiplayer_authority() or get_effective_snapshot_stride() <= 1:
		return
	var current := _read_non_motion_values()
	if mark_event:
		_last_event_tick = tick
	_last_sent_non_motion_values = current

func _has_non_motion_event() -> bool:
	if get_effective_snapshot_stride() <= 1:
		return false
	if _last_sent_non_motion_values.size() != _non_motion_property_entries.size():
		_last_sent_non_motion_values = _read_non_motion_values()
		return false
	for index in range(_non_motion_property_entries.size()):
		if _non_motion_property_entries[index].get_value() != _last_sent_non_motion_values[index]:
			return true
	return false

func _has_pending_event_ack() -> bool:
	if _last_event_tick < 0:
		return false
	if not visibility_filter:
		return false
	for peer in visibility_filter.get_visible_peers():
		if int(_ackd_state.get(peer, -1)) < _last_event_tick:
			return true
	return false

func _read_non_motion_values() -> Array:
	var result: Array = []
	result.resize(_non_motion_property_entries.size())
	for index in range(_non_motion_property_entries.size()):
		result[index] = _non_motion_property_entries[index].get_value()
	return result

func _cache_property_paths() -> void:
	_motion_property_paths.clear()
	_non_motion_property_paths.clear()
	_non_motion_property_entries.clear()
	if _property_config == null:
		return
	for property_entry in _property_config.get_properties():
		var path := property_entry.to_string()
		if _is_motion_property(path):
			_motion_property_paths.append(path)
		else:
			_non_motion_property_paths.append(path)
			_non_motion_property_entries.append(property_entry)

func _is_motion_property(property_path: String) -> bool:
	for motion_path in MOTION_PROPERTY_PATHS:
		if property_path == motion_path or property_path.ends_with(motion_path):
			return true
	return false

func _recompute_authority_snapshot_phase() -> void:
	var stride := maxi(1, npc_snapshot_stride)
	_authority_snapshot_phase = posmod(hash(_get_authority_phase_identity()), stride)

func _sync_stride_from_server_state() -> void:
	if _server_state_parent == null or not is_instance_valid(_server_state_parent) or _server_state_parent != get_parent():
		_server_state_parent = get_parent()
	if _server_state_parent == null:
		return
	var server_stride := int(_server_state_parent.get("npc_snapshot_stride"))
	if server_stride != npc_snapshot_stride:
		npc_snapshot_stride = server_stride

func reset_client_history_epoch() -> void:
	_state_history.clear()
	_last_client_history_tick = -1
	_client_history_epoch_requires_complete = true

func _apply_received_stride_metadata(tick: int) -> int:
	var closest_tick := _get_eligible_client_history_tick(tick)
	if closest_tick < 0:
		return -1
	var snapshot := _state_history.get_snapshot(closest_tick)
	for property_path in _non_motion_property_paths:
		if property_path == "ServerState:npc_snapshot_stride" or property_path.ends_with(":npc_snapshot_stride"):
			if snapshot.has(property_path):
				var received_stride := int(snapshot.get_value(property_path))
				if received_stride != npc_snapshot_stride:
					npc_snapshot_stride = received_stride
				if _server_state_parent != null and is_instance_valid(_server_state_parent):
					_server_state_parent.set("npc_snapshot_stride", npc_snapshot_stride)
			return closest_tick
	return closest_tick

func _get_eligible_client_history_tick(tick: int) -> int:
	if _state_history.is_empty():
		return -1
	var closest_tick: int = _state_history.get_closest_tick(tick)
	if closest_tick < 0 or closest_tick <= _last_client_history_tick:
		return -1
	var snapshot := _state_history.get_snapshot(closest_tick)
	if snapshot == null or snapshot.is_empty():
		return -1
	if _client_history_epoch_requires_complete and not _is_complete_snapshot(snapshot):
		return -1
	return closest_tick

func _accept_client_history_tick(tick: int) -> void:
	_last_client_history_tick = tick
	_client_history_epoch_requires_complete = false

func _is_complete_snapshot(snapshot: _PropertySnapshot) -> bool:
	for property_path in properties:
		if not snapshot.has(property_path):
			return false
	return true

func _get_authority_phase_identity() -> String:
	if root == null:
		return name
	if root.is_inside_tree():
		return str(root.get_path())
	return root.name
