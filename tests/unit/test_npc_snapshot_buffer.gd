extends GutTest

const BUFFER_SCRIPT := preload("res://common/net/NpcSnapshotBuffer.gd")
const EPSILON := 0.001

func _assert_vec3_close(actual: Vector3, expected: Vector3, message: String = "") -> void:
	assert_true(actual.distance_to(expected) <= EPSILON, "%s expected=%s actual=%s" % [message, expected, actual])

func _assert_quat_close(actual: Quaternion, expected: Quaternion, message: String = "") -> void:
	var dot: float = abs(actual.normalized().dot(expected.normalized()))
	assert_true(dot >= 1.0 - EPSILON, "%s expected=%s actual=%s dot=%s" % [message, expected, actual, dot])

func test_empty_and_seed_hold_pose() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_eq(buffer.count, 0)
	assert_eq(buffer.latest_tick, -1)
	assert_eq(buffer.sample(0.0), {})

	assert_true(buffer.push_snapshot(5, Vector3(1, 2, 3), Quaternion.IDENTITY))
	assert_eq(buffer.count, 1)
	assert_eq(buffer.latest_tick, 5)
	var before: Dictionary = buffer.sample(4.0)
	var after: Dictionary = buffer.sample(8.0)
	_assert_vec3_close(before.position, Vector3(1, 2, 3), "single sample holds before")
	_assert_vec3_close(after.position, Vector3(1, 2, 3), "single sample holds after")
	_assert_quat_close(after.rotation, Quaternion.IDENTITY)

func test_uneven_tick_interpolation_uses_actual_tick_distance() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(3, Vector3(3, 0, 0), Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(6, Vector3(6, 0, 0), Quaternion.IDENTITY))

	_assert_vec3_close(buffer.sample(1.5).position, Vector3(1.5, 0, 0))
	_assert_vec3_close(buffer.sample(4.5).position, Vector3(4.5, 0, 0))

func test_duplicate_rejected_and_in_window_reorder_supported() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(6, Vector3(6, 0, 0), Quaternion.IDENTITY))
	assert_false(buffer.push_snapshot(6, Vector3(9, 0, 0), Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(3, Vector3(3, 0, 0), Quaternion.IDENTITY))

	assert_eq(buffer.count, 3)
	_assert_vec3_close(buffer.sample(4.5).position, Vector3(4.5, 0, 0))

func test_stale_after_render_cursor_is_rejected_and_pose_does_not_rewind() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(4, Vector3(4, 0, 0), Quaternion.IDENTITY))
	_assert_vec3_close(buffer.sample(3.0).position, Vector3(3, 0, 0))

	assert_false(buffer.push_snapshot(2, Vector3(20, 0, 0), Quaternion.IDENTITY))
	_assert_vec3_close(buffer.sample(1.0).position, Vector3(3, 0, 0), "backward render clock must not rewind")

func test_capacity_minimum_and_overcapacity_drops_oldest() -> void:
	var buffer := BUFFER_SCRIPT.new(2)
	assert_true(buffer.push_snapshot(0, Vector3(0, 0, 0), Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(1, Vector3(1, 0, 0), Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(2, Vector3(2, 0, 0), Quaternion.IDENTITY))

	assert_eq(buffer.count, 2)
	_assert_vec3_close(buffer.sample(0.0).position, Vector3(1, 0, 0), "earliest retained sample holds")
	assert_false(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))

func test_teleport_resets_history_and_late_preteleport_packet_rejected() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(10, Vector3.ZERO, Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(11, Vector3(1, 0, 0), Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(12, Vector3(20, 0, 0), Quaternion.IDENTITY))

	assert_eq(buffer.count, 1)
	assert_eq(buffer.latest_tick, 12)
	assert_false(buffer.push_snapshot(11, Vector3(2, 0, 0), Quaternion.IDENTITY))
	_assert_vec3_close(buffer.sample(12.0).position, Vector3(20, 0, 0))

func test_large_forward_tick_gap_resets_history() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(13, Vector3(1, 0, 0), Quaternion.IDENTITY))

	assert_eq(buffer.count, 1)
	assert_eq(buffer.latest_tick, 13)
	_assert_vec3_close(buffer.sample(6.0).position, Vector3(1, 0, 0))

func test_reset_restores_clean_clock_state() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(5, Vector3(5, 0, 0), Quaternion.IDENTITY))
	_assert_vec3_close(buffer.sample(5.0).position, Vector3(5, 0, 0))
	buffer.reset()

	assert_eq(buffer.count, 0)
	assert_eq(buffer.latest_tick, -1)
	assert_eq(buffer.sample(0.0), {})
	assert_true(buffer.push_snapshot(1, Vector3(1, 0, 0), Quaternion.IDENTITY))

func test_shortest_arc_treats_negated_quaternion_as_same_rotation() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion(0, 0, 0, 1)))
	assert_true(buffer.push_snapshot(2, Vector3.ZERO, Quaternion(0, 0, 0, -1)))

	_assert_quat_close(buffer.sample(1.0).rotation, Quaternion.IDENTITY)

func test_valid_rotation_interpolation_is_normalized() -> void:
	var buffer := BUFFER_SCRIPT.new()
	var target := Quaternion(Vector3.UP, PI)
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	assert_true(buffer.push_snapshot(2, Vector3.ZERO, target))

	var sampled: Quaternion = buffer.sample(1.0).rotation
	assert_true(abs(sampled.length() - 1.0) <= EPSILON)
	assert_true(abs(abs(sampled.y) - sqrt(0.5)) <= EPSILON)
	assert_true(abs(abs(sampled.w) - sqrt(0.5)) <= EPSILON)

func test_recovers_after_holding_latest_sample_far_ahead_of_data() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	_assert_vec3_close(buffer.sample(100.0).position, Vector3.ZERO, "starved render holds latest data")

	assert_true(buffer.push_snapshot(3, Vector3(3, 0, 0), Quaternion.IDENTITY),
		"A newer source tick must be accepted after starvation so interpolation can recover")
	_assert_vec3_close(buffer.sample(101.0).position, Vector3(3, 0, 0), "new latest data becomes the held pose")

func test_nonfinite_render_tick_holds_last_pose_without_poisoning_cursor() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_true(buffer.push_snapshot(0, Vector3.ZERO, Quaternion.IDENTITY))
	_assert_vec3_close(buffer.sample(0.0).position, Vector3.ZERO)

	_assert_vec3_close(buffer.sample(INF).position, Vector3.ZERO,
		"Nonfinite render ticks should not advance stale-rejection cursors")
	assert_true(buffer.push_snapshot(3, Vector3(3, 0, 0), Quaternion.IDENTITY),
		"Finite newer snapshots must still be accepted after a nonfinite render tick")

func test_rejects_nonfinite_position_rotation_zero_quaternion_and_negative_tick() -> void:
	var buffer := BUFFER_SCRIPT.new()
	assert_false(buffer.push_snapshot(-1, Vector3.ZERO, Quaternion.IDENTITY))
	assert_false(buffer.push_snapshot(0, Vector3(INF, 0, 0), Quaternion.IDENTITY))
	assert_false(buffer.push_snapshot(0, Vector3.ZERO, Quaternion(INF, 0, 0, 1)))
	assert_false(buffer.push_snapshot(0, Vector3.ZERO, Quaternion(0, 0, 0, 0)))
	assert_eq(buffer.count, 0)
