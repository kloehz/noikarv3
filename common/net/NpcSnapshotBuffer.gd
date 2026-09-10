class_name NpcSnapshotBuffer
extends RefCounted

const DEFAULT_CAPACITY := 16
const MAX_CAPACITY := 16
const MIN_CAPACITY := 2
const DEFAULT_MAX_TICK_GAP := 12
const DEFAULT_TELEPORT_DISTANCE := 8.0
const EPSILON := 0.000001

var count: int:
	get:
		return _samples.size()

var latest_tick: int:
	get:
		return _latest_tick

var max_tick_gap: int
var teleport_distance: float

var _capacity: int
var _samples: Array[Dictionary] = []
var _latest_tick := -1
var _barrier_tick := -1
var _presented_tick := -1
var _last_render_tick := -INF
var _last_pose: Dictionary = {}

func _init(capacity: int = DEFAULT_CAPACITY, p_max_tick_gap: int = DEFAULT_MAX_TICK_GAP, p_teleport_distance: float = DEFAULT_TELEPORT_DISTANCE) -> void:
	_capacity = clampi(capacity, MIN_CAPACITY, MAX_CAPACITY)
	max_tick_gap = max(1, p_max_tick_gap)
	teleport_distance = max(0.0, p_teleport_distance)

func push_snapshot(tick: int, position: Vector3, rotation: Quaternion) -> bool:
	if tick < 0 or tick <= _barrier_tick:
		return false
	if tick <= _presented_tick and tick < _latest_tick:
		return false
	if not _is_valid_position(position) or not _is_valid_rotation(rotation):
		return false
	if _find_sample_index(tick) != -1:
		return false

	var normalized_rotation := rotation.normalized()
	if tick > _latest_tick:
		if _should_reset_for_forward_sample(tick, position):
			_seed(tick, position, normalized_rotation)
			return true
		_append_ordered({"tick": tick, "position": position, "rotation": normalized_rotation})
		_latest_tick = tick
		_trim_to_capacity()
		return true

	_append_ordered({"tick": tick, "position": position, "rotation": normalized_rotation})
	_trim_to_capacity()
	return true

func sample(render_tick: float) -> Dictionary:
	if _samples.is_empty():
		return {}
	if not is_finite(render_tick):
		if not _last_pose.is_empty():
			return _copy_pose(_last_pose)
		var last_for_nonfinite: Dictionary = _samples[_samples.size() - 1]
		return {"position": last_for_nonfinite.position, "rotation": last_for_nonfinite.rotation}
	if render_tick < _last_render_tick and not _last_pose.is_empty():
		return _copy_pose(_last_pose)

	_last_render_tick = render_tick
	_presented_tick = max(_presented_tick, mini(floori(render_tick), _latest_tick))
	var pose := _sample_forward(render_tick)
	_last_pose = _copy_pose(pose)
	return pose

func reset() -> void:
	_samples.clear()
	_latest_tick = -1
	_barrier_tick = -1
	_presented_tick = -1
	_last_render_tick = -INF
	_last_pose = {}

func _seed(tick: int, position: Vector3, rotation: Quaternion) -> void:
	_samples = [{"tick": tick, "position": position, "rotation": rotation}]
	_latest_tick = tick
	_barrier_tick = tick - 1
	_last_pose = {}

func _should_reset_for_forward_sample(tick: int, position: Vector3) -> bool:
	if _samples.is_empty():
		return false
	var previous_position: Vector3 = _samples[_samples.size() - 1].position
	var tick_gap := tick - _latest_tick
	return tick_gap > max_tick_gap or previous_position.distance_to(position) > teleport_distance

func _sample_forward(render_tick: float) -> Dictionary:
	var first: Dictionary = _samples[0]
	if render_tick <= float(first.tick):
		return {"position": first.position, "rotation": first.rotation}

	var last: Dictionary = _samples[_samples.size() - 1]
	if render_tick >= float(last.tick):
		return {"position": last.position, "rotation": last.rotation}

	for index in range(1, _samples.size()):
		var right: Dictionary = _samples[index]
		if render_tick <= float(right.tick):
			var left: Dictionary = _samples[index - 1]
			return _interpolate(left, right, render_tick)

	return {"position": last.position, "rotation": last.rotation}

func _interpolate(left: Dictionary, right: Dictionary, render_tick: float) -> Dictionary:
	var left_tick: int = left.tick
	var right_tick: int = right.tick
	if right_tick <= left_tick:
		return {"position": left.position, "rotation": left.rotation}
	var weight := clampf((render_tick - float(left_tick)) / float(right_tick - left_tick), 0.0, 1.0)
	var left_rotation: Quaternion = left.rotation
	var right_rotation: Quaternion = right.rotation
	if left_rotation.dot(right_rotation) < 0.0:
		right_rotation = -right_rotation
	return {
		"position": (left.position as Vector3).lerp(right.position, weight),
		"rotation": left_rotation.slerp(right_rotation, weight).normalized(),
	}

func _append_ordered(sample_data: Dictionary) -> void:
	for index in range(_samples.size()):
		if sample_data.tick < _samples[index].tick:
			_samples.insert(index, sample_data)
			return
	_samples.append(sample_data)

func _trim_to_capacity() -> void:
	while _samples.size() > _capacity:
		_samples.pop_front()

func _find_sample_index(tick: int) -> int:
	for index in range(_samples.size()):
		if _samples[index].tick == tick:
			return index
	return -1

func _is_valid_position(position: Vector3) -> bool:
	return is_finite(position.x) and is_finite(position.y) and is_finite(position.z)

func _is_valid_rotation(rotation: Quaternion) -> bool:
	return is_finite(rotation.x) and is_finite(rotation.y) and is_finite(rotation.z) and is_finite(rotation.w) and rotation.length() > EPSILON

func _copy_pose(pose: Dictionary) -> Dictionary:
	return {"position": pose.position, "rotation": pose.rotation}
