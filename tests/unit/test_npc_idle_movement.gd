extends GutTest

const PERF_PROBE_SCRIPT := preload("res://common/perf_probe.gd")

class MovementDriver:
	extends Node
	signal drove_tick
	var logic: LogicComponent

	func _physics_process(_delta: float) -> void:
		set_physics_process(false)
		logic.simulate_authoritative_tick(1.0 / 30.0, 1)
		drove_tick.emit()

class ProbeableLogicComponent:
	extends LogicComponent

var _previous_peer: MultiplayerPeer
var _previous_tickrate := 30
var _previous_sync_to_physics := false
var _previous_probe_env := ""
var _previous_cost_env := ""
var _probe: Node = null
var _owns_probe := false

func before_each() -> void:
	await get_tree().process_frame
	_previous_peer = multiplayer.multiplayer_peer
	_previous_tickrate = NetworkTime.get("_tickrate")
	_previous_sync_to_physics = NetworkTime.get("_sync_to_physics")
	NetworkTime.set("_tickrate", 30)
	NetworkTime.set("_sync_to_physics", true)
	_previous_probe_env = OS.get_environment("NOIKAR_PERF_PROBE")
	_previous_cost_env = OS.get_environment("NOIKAR_PERF_PROBE_NPC_COST")
	OS.set_environment("NOIKAR_PERF_PROBE", "1")
	OS.set_environment("NOIKAR_PERF_PROBE_NPC_COST", "1")
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_probe = get_node_or_null("/root/PerfProbe")
	if _probe == null:
		_probe = PERF_PROBE_SCRIPT.new()
		_probe.name = "PerfProbe"
		get_tree().root.add_child(_probe)
		_owns_probe = true
	else:
		_owns_probe = false
	_probe._set_npc_cost_recording_for_tests(false)

func after_each() -> void:
	if is_instance_valid(_probe):
		_probe._set_npc_cost_recording_for_tests(false)
	if _owns_probe and is_instance_valid(_probe):
		_probe.queue_free()
		await get_tree().process_frame
	_probe = null
	_owns_probe = false
	NetworkTime.set("_tickrate", _previous_tickrate)
	NetworkTime.set("_sync_to_physics", _previous_sync_to_physics)
	OS.set_environment("NOIKAR_PERF_PROBE", _previous_probe_env)
	OS.set_environment("NOIKAR_PERF_PROBE_NPC_COST", _previous_cost_env)
	multiplayer.multiplayer_peer = _previous_peer

func test_npc_single_fresh_movement_call_records_real_slide_and_flush_calls() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await get_tree().process_frame
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement.calls, 1, "NPC movement remains inclusive around one real movement call")
	assert_eq(summary.movement_prepare.calls, 0, "Exact no-op idle startup does not run preparation")
	assert_eq(summary.movement_slide.calls, 1, "slide call count reports the actual move_and_slide call")
	assert_eq(summary.movement_flush.calls, 1, "server flush call count reports the actual force_update_transform call")

func test_idle_npc_second_tick_omits_prepare_but_keeps_native_slide_and_flush() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	await _drive_tick(logic)
	_probe._consume_npc_cost_summary()
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement.calls, 1, "Inclusive movement still wraps the tick")
	assert_eq(summary.movement_prepare.calls, 0, "No-op idle path does not fabricate preparation work")
	assert_eq(summary.movement_slide.calls, 1, "Idle NPC still runs one native CharacterBody3D query every tick")
	assert_eq(summary.movement_flush.calls, 1, "Idle NPC keeps native force_update_transform every server tick")

func test_idle_npc_first_tick_flushes_settled_authoritative_pose() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement_slide.calls, 1)
	assert_eq(summary.movement_flush.calls, 1, "The authoritative pose is flushed")

func test_idle_npc_input_and_yaw_wake_preparation_and_flush_same_tick() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	await _drive_tick(logic)
	_probe._consume_npc_cost_summary()
	logic.input_axis = Vector2(1.0, 0.0)
	logic.look_yaw = 0.4
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement_slide.calls, 1)
	assert_eq(summary.movement_flush.calls, 1)
	assert_eq(summary.movement_prepare.calls, 1)
	assert_almost_eq(body.rotation.y, 0.4, 0.001)

func test_decelerating_and_dashing_npc_do_not_take_idle_fast_path() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	logic.current_velocity = Vector3(1.0, 0.0, 0.0)
	await _drive_tick(logic)
	var decel_summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(decel_summary.movement_prepare.calls, 1)

	logic.current_velocity = Vector3.ZERO
	body.velocity = Vector3.ZERO
	logic.is_dashing = true
	logic.dash_direction = Vector3.FORWARD
	logic.dash_timer = 0.1
	await _drive_tick(logic)
	var dash_summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(dash_summary.movement_prepare.calls, 1)

func test_external_teleport_keeps_native_flush_same_tick() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	await _drive_tick(logic)
	_probe._consume_npc_cost_summary()
	body.global_position += Vector3(0.5, 0.0, 0.0)
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement_prepare.calls, 0, "Teleport alone does not wake movement preparation")
	assert_eq(summary.movement_flush.calls, 1, "Externally changed full transform is flushed on the same tick")

func test_dead_and_grace_do_not_emit_movement_timings_until_next_live_pose() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := GraceBody.new()
	body.name = "MOB_IDLE_TEST"
	body.set_multiplayer_authority(1)
	_configure_body_world(body)
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	await _drive_tick(logic)
	_probe._consume_npc_cost_summary()
	body.sync_is_dead = true
	await _drive_tick(logic)
	body.sync_is_dead = false
	body.grace_active = true
	await _drive_tick(logic)
	body.grace_active = false
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement.calls, 1, "Only the resumed live tick records movement")
	assert_eq(summary.movement_flush.calls, 1, "The resumed live pose flushes without cache lifecycle bookkeeping")

func test_idle_collision_recovery_uses_real_slide_flush_and_syncs_velocity() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await _settle_world()
	await _drive_tick(logic)
	_probe._consume_npc_cost_summary()
	var blocker := StaticBody3D.new()
	var blocker_shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5
	capsule.height = 2.0
	blocker_shape.shape = capsule
	blocker.add_child(blocker_shape)
	body.get_parent().add_child(blocker)
	blocker.global_position = body.global_position
	await _settle_world()
	var before := body.global_position
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement_slide.calls, 1)
	assert_eq(summary.movement_flush.calls, 1, "Native collision recovery that changes the body is flushed")
	assert_ne(body.global_position, before, "Real CharacterBody3D recovery moved the overlapped body")
	assert_eq(logic.current_velocity, body.velocity / NetworkTime.physics_factor, "Velocity sync-back still runs after native slide")

func test_player_path_is_untimed_even_when_npc_cost_probe_enabled() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("2")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await get_tree().process_frame
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement.calls, 0)
	assert_eq(summary.movement_prepare.calls, 0)
	assert_eq(summary.movement_slide.calls, 0)
	assert_eq(summary.movement_flush.calls, 0)

func test_player_path_stays_out_of_npc_timed_fastpath() -> void:
	_probe._set_npc_cost_recording_for_tests(true)
	var body := _make_body("2")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await get_tree().process_frame
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement.calls, 0, "Human/player movement is not counted as NPC fastpath work")

func test_telemetry_off_does_not_record_child_movement_costs() -> void:
	_probe._set_npc_cost_recording_for_tests(false)
	var body := _make_body("MOB_IDLE_TEST")
	var logic: LogicComponent = body.get_node("LogicComponent") as LogicComponent
	await get_tree().process_frame
	await _drive_tick(logic)

	var summary: Dictionary = _probe._consume_npc_cost_summary()
	assert_eq(summary.movement.calls, 0)
	assert_eq(summary.movement_prepare.calls, 0)
	assert_eq(summary.movement_slide.calls, 0)
	assert_eq(summary.movement_flush.calls, 0)

func _drive_tick(logic: LogicComponent) -> void:
	var driver := MovementDriver.new()
	driver.logic = logic
	add_child_autofree(driver)
	await driver.drove_tick

class GraceBody:
	extends CharacterBody3D
	var sync_is_dead := false
	var grace_active := false

	func is_spawn_grace_active() -> bool:
		return grace_active

func _settle_world() -> void:
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

func test_diagnostic_idle_movement_head_vs_candidate_microbenchmark() -> void:
	if OS.get_environment("NOIKAR_RUN_IDLE_MOVEMENT_BENCH") != "1":
		assert_true(true, "Diagnostic benchmark is opt-in via NOIKAR_RUN_IDLE_MOVEMENT_BENCH=1")
		return
	var baseline_script := _load_head_logic_script()
	assert_not_null(baseline_script, "HEAD LogicComponent source must compile for the diagnostic benchmark")
	if baseline_script == null:
		return
	var baseline_revision := _load_head_revision()
	_probe._set_npc_cost_recording_for_tests(false)
	var delta := 1.0 / 30.0
	var warmup_calls := 2000
	var measured_calls := 10000
	var idle := await _run_isolated_benchmark_case("IDLE", baseline_script, delta, warmup_calls, measured_calls, Callable(self, "_benchmark_idle_input"))
	var moving := await _run_isolated_benchmark_case("MOVING", baseline_script, delta, warmup_calls, measured_calls, Callable(self, "_benchmark_moving_input"))
	var mixed := await _run_isolated_benchmark_case("MIXED", baseline_script, delta, warmup_calls, measured_calls, Callable(self, "_benchmark_mixed_input"))
	print("[IDLE_MOVEMENT_BENCH] baseline_revision=%s" % baseline_revision)
	print("[IDLE_MOVEMENT_BENCH] summary idle_candidate=%.4f idle_baseline=%.4f moving_candidate=%.4f moving_baseline=%.4f mixed_candidate=%.4f mixed_baseline=%.4f" % [idle.candidate_median, idle.baseline_median, moving.candidate_median, moving.baseline_median, mixed.candidate_median, mixed.baseline_median])

func _run_isolated_benchmark_case(label: String, baseline_script: GDScript, delta: float, warmup_calls: int, measured_calls: int, input_schedule: Callable) -> Dictionary:
	var baseline_times: Array[float] = []
	var candidate_times: Array[float] = []
	for repeat in 7:
		var bench := await _make_benchmark_pair(baseline_script)
		_benchmark_movement_method(bench.baseline_logic, &"_apply_movement", delta, warmup_calls, input_schedule)
		_benchmark_movement_method(bench.candidate_logic, &"_apply_npc_movement", delta, warmup_calls, input_schedule)
		_reset_benchmark_pair(bench)
		_assert_benchmark_pair_equivalent(bench, "%s repeat %d after reset" % [label, repeat])
		var baseline_snapshot: Dictionary
		var candidate_snapshot: Dictionary
		if repeat % 2 == 0:
			baseline_times.append(_benchmark_movement_method(bench.baseline_logic, &"_apply_movement", delta, measured_calls, input_schedule))
			baseline_snapshot = _benchmark_snapshot(bench.baseline_body, bench.baseline_logic)
			_reset_benchmark_pair(bench)
			candidate_times.append(_benchmark_movement_method(bench.candidate_logic, &"_apply_npc_movement", delta, measured_calls, input_schedule))
			candidate_snapshot = _benchmark_snapshot(bench.candidate_body, bench.candidate_logic)
		else:
			candidate_times.append(_benchmark_movement_method(bench.candidate_logic, &"_apply_npc_movement", delta, measured_calls, input_schedule))
			candidate_snapshot = _benchmark_snapshot(bench.candidate_body, bench.candidate_logic)
			_reset_benchmark_pair(bench)
			baseline_times.append(_benchmark_movement_method(bench.baseline_logic, &"_apply_movement", delta, measured_calls, input_schedule))
			baseline_snapshot = _benchmark_snapshot(bench.baseline_body, bench.baseline_logic)
		_assert_benchmark_snapshots_equivalent(baseline_snapshot, candidate_snapshot, "%s repeat %d after timed trials" % [label, repeat])
		bench.baseline_viewport.queue_free()
		bench.candidate_viewport.queue_free()
		await get_tree().process_frame
	var baseline_median := _median_float(baseline_times)
	var candidate_median := _median_float(candidate_times)
	var improvement := (baseline_median - candidate_median) / baseline_median * 100.0
	print("[IDLE_MOVEMENT_BENCH][%s] calls_per_repeat=%d warmup_calls=%d" % [label, measured_calls, warmup_calls])
	print("[IDLE_MOVEMENT_BENCH][%s] baseline_us_per_call median=%.4f range=%.4f..%.4f raw=%s" % [label, baseline_median, _min_float(baseline_times), _max_float(baseline_times), str(baseline_times)])
	print("[IDLE_MOVEMENT_BENCH][%s] candidate_us_per_call median=%.4f range=%.4f..%.4f raw=%s" % [label, candidate_median, _min_float(candidate_times), _max_float(candidate_times), str(candidate_times)])
	print("[IDLE_MOVEMENT_BENCH][%s] median_delta_percent=%.2f" % [label, improvement])
	return {"baseline_median": baseline_median, "candidate_median": candidate_median, "baseline_raw": baseline_times, "candidate_raw": candidate_times}

func _make_benchmark_pair(baseline_script: GDScript) -> Dictionary:
	var baseline_viewport := _make_benchmark_world("BaselineBenchWorld")
	var candidate_viewport := _make_benchmark_world("CandidateBenchWorld")
	add_child(baseline_viewport)
	add_child(candidate_viewport)
	var baseline_root := baseline_viewport.get_child(0)
	var candidate_root := candidate_viewport.get_child(0)
	var baseline_body := _make_benchmark_body("MOB_IDLE_BASELINE", Vector3.ZERO, baseline_script)
	var candidate_body := _make_benchmark_body("MOB_IDLE_CANDIDATE", Vector3.ZERO, LogicComponent)
	baseline_root.add_child(baseline_body)
	candidate_root.add_child(candidate_body)
	await _settle_world()
	var bench := {"baseline_viewport": baseline_viewport, "candidate_viewport": candidate_viewport, "baseline_body": baseline_body, "candidate_body": candidate_body, "baseline_logic": baseline_body.get_node("LogicComponent"), "candidate_logic": candidate_body.get_node("LogicComponent")}
	_reset_benchmark_pair(bench)
	_assert_benchmark_pair_equivalent(bench, "initial")
	return bench

func _make_benchmark_world(world_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = world_name
	viewport.disable_3d = false
	viewport.own_world_3d = true
	var root := Node3D.new()
	root.name = "%sRoot" % world_name
	viewport.add_child(root)
	_add_floor(root)
	return viewport

func _reset_benchmark_pair(bench: Dictionary) -> void:
	_reset_benchmark_body(bench.baseline_body, bench.baseline_logic)
	_reset_benchmark_body(bench.candidate_body, bench.candidate_logic)

func _reset_benchmark_body(body: CharacterBody3D, logic: Node) -> void:
	logic.set("input_axis", Vector2.ZERO)
	logic.set("current_velocity", Vector3.ZERO)
	logic.set("is_dashing", false)
	logic.set("dash_timer", 0.0)
	logic.set("dash_cooldown", 0.0)
	logic.set("look_yaw", 0.0)
	body.global_position = Vector3(0.0, 1.0, 0.0)
	body.rotation = Vector3.ZERO
	body.velocity = Vector3.ZERO
	body.force_update_transform()

func _benchmark_idle_input(_index: int) -> Vector2:
	return Vector2.ZERO

func _benchmark_moving_input(index: int) -> Vector2:
	return Vector2(1.0 if int(index / 16) % 2 == 0 else -1.0, 0.0)

func _benchmark_mixed_input(index: int) -> Vector2:
	if index % 32 < 16:
		return Vector2(1.0 if int(index / 32) % 2 == 0 else -1.0, 0.0)
	return Vector2.ZERO

func _assert_benchmark_pair_equivalent(bench: Dictionary, context: String) -> void:
	_assert_benchmark_snapshots_equivalent(_benchmark_snapshot(bench.baseline_body, bench.baseline_logic), _benchmark_snapshot(bench.candidate_body, bench.candidate_logic), context)

func _benchmark_snapshot(body: CharacterBody3D, logic: Node) -> Dictionary:
	return {
		"position": body.global_position,
		"yaw": body.rotation.y,
		"velocity": logic.get("current_velocity"),
		"slide_collisions": body.get_slide_collision_count(),
		"has_floor_support": _has_floor_support(body),
	}

func _assert_benchmark_snapshots_equivalent(baseline: Dictionary, candidate: Dictionary, context: String) -> void:
	_assert_benchmark_snapshot_supported(baseline, "baseline %s" % context)
	_assert_benchmark_snapshot_supported(candidate, "candidate %s" % context)
	assert_almost_eq(candidate.position.x, baseline.position.x, 0.001, "Equivalent isolated capsules preserve x pose: %s" % context)
	assert_almost_eq(candidate.position.y, baseline.position.y, 0.001, "Equivalent isolated capsules preserve y pose: %s" % context)
	assert_almost_eq(candidate.position.z, baseline.position.z, 0.001, "Equivalent isolated capsules preserve z pose: %s" % context)
	assert_almost_eq(candidate.yaw, baseline.yaw, 0.001, "Equivalent isolated capsules preserve yaw: %s" % context)
	assert_almost_eq(candidate.velocity.x, baseline.velocity.x, 0.001, "Equivalent isolated capsules preserve velocity x: %s" % context)
	assert_almost_eq(candidate.velocity.z, baseline.velocity.z, 0.001, "Equivalent isolated capsules preserve velocity z: %s" % context)
	assert_eq(candidate.slide_collisions, baseline.slide_collisions, "Candidate and HEAD produce equivalent collision result counts: %s" % context)

func _assert_benchmark_snapshot_supported(snapshot: Dictionary, context: String) -> void:
	var position: Vector3 = snapshot.position
	assert_true(is_finite(position.x) and is_finite(position.y) and is_finite(position.z), "Benchmark body position remains finite: %s" % context)
	assert_true(absf(position.x) < 9.0 and absf(position.z) < 9.0, "Benchmark body stays on the 20m floor: %s" % context)
	assert_true(snapshot.has_floor_support, "Benchmark body has floor support: %s pos=%s" % [context, str(position)])

func _has_floor_support(body: CharacterBody3D) -> bool:
	if body.is_on_floor():
		return true
	# The benchmark has no gravity; moving horizontally can leave is_on_floor()
	# false even while the capsule bottom is still exactly supported by the
	# static floor plane. Validate the known benchmark floor geometry directly.
	return absf(body.global_position.y - 1.0) < 0.05 and absf(body.global_position.x) < 10.0 and absf(body.global_position.z) < 10.0

func _load_head_logic_script() -> GDScript:
	var output: Array = []
	var exit_code := OS.execute("git", ["show", "HEAD:core/LogicComponent.gd"], output, true)
	if exit_code != 0 or output.is_empty():
		return null
	var source := str(output[0]).replace("class_name LogicComponent\n", "")
	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		push_error("Failed to compile HEAD LogicComponent.gd for benchmark: %s" % error_string(err))
		return null
	return script

func _load_head_revision() -> String:
	var output: Array = []
	var exit_code := OS.execute("git", ["rev-parse", "--short", "HEAD"], output, true)
	if exit_code != 0 or output.is_empty():
		return "HEAD"
	return str(output[0]).strip_edges()

func _make_benchmark_body(body_name: String, position: Vector3, logic_script: GDScript) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = body_name
	body.set_multiplayer_authority(1)
	body.position = position
	body.collision_layer = 1
	body.collision_mask = 1
	var shape := CollisionShape3D.new()
	shape.shape = CapsuleShape3D.new()
	body.add_child(shape)
	var logic: Node = logic_script.new()
	logic.name = "LogicComponent"
	body.add_child(logic)
	return body

func _benchmark_movement_method(logic: Node, method: StringName, delta: float, calls: int, input_schedule: Callable) -> float:
	var started_usec := Time.get_ticks_usec()
	for index in calls:
		logic.set("input_axis", input_schedule.call(index))
		logic.call(method, delta)
	return float(Time.get_ticks_usec() - started_usec) / float(calls)

func _median_float(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]

func _min_float(values: Array[float]) -> float:
	var result := values[0]
	for value in values:
		result = min(result, value)
	return result

func _max_float(values: Array[float]) -> float:
	var result := values[0]
	for value in values:
		result = max(result, value)
	return result

func _add_floor(root: Node) -> void:
	var floor := StaticBody3D.new()
	floor.name = "Floor"
	floor.collision_layer = 1
	floor.collision_mask = 1
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 0.2, 20.0)
	floor_shape.shape = box
	floor_shape.position.y = -0.1
	floor.add_child(floor_shape)
	root.add_child(floor)

func _make_body(body_name: String) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = body_name
	body.set_multiplayer_authority(1)
	_configure_body_world(body)
	return body

func _configure_body_world(body: CharacterBody3D) -> void:
	var viewport := SubViewport.new()
	viewport.name = "%s_World" % body.name
	viewport.disable_3d = false
	viewport.own_world_3d = true
	add_child_autofree(viewport)
	var root := Node3D.new()
	viewport.add_child(root)

	var floor := StaticBody3D.new()
	floor.name = "%s_Floor" % body.name
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(8.0, 0.2, 8.0)
	floor_shape.shape = box
	floor_shape.position.y = -0.1
	floor.add_child(floor_shape)
	root.add_child(floor)

	body.position = Vector3(0.0, 1.0, 0.0)
	var shape := CollisionShape3D.new()
	shape.shape = CapsuleShape3D.new()
	body.add_child(shape)
	var logic := ProbeableLogicComponent.new()
	logic.name = "LogicComponent"
	body.add_child(logic)
	root.add_child(body)
