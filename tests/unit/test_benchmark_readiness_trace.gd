extends GutTest
const TRACE := preload("res://common/benchmark_readiness_trace.gd")

class FakeSync extends Node:
	var _is_initialized := false
	var _replica_ready_peers := {}

func _make_trace() -> Node:
	var trace := TRACE.new()
	add_child_autofree(trace)
	trace.start("client", 0, 10, func() -> Dictionary: return {}, "1")
	return trace

func _make_sync(state: Node = null) -> Node:
	if state == null:
		state = Node.new()
		state.name = "ServerState"
		add_child_autofree(state)
	# Exact topology is part of this fixture, not an implicit naming assumption.
	assert_eq(str(state.name), "ServerState")
	assert_eq(state.get_parent(), self)
	assert_true(state.is_inside_tree())
	assert_false(state.has_node("StateSynchronizer"))
	var sync := FakeSync.new()
	sync.name = "StateSynchronizer"
	state.add_child(sync)
	assert_eq(str(sync.name), "StateSynchronizer")
	assert_eq(sync.get_parent(), state)
	return sync

func test_default_and_invalid_requests_are_inert() -> void:
	var trace := TRACE.new()
	add_child_autofree(trace)
	trace._process(2.0)
	assert_eq(trace._rows, 0)
	assert_false(trace.start("client", 0, 10, Callable(), ""))
	assert_false(trace.start("client", 10, 10, Callable(), "1"))
	assert_false(trace.start("server", 0, 10, Callable(), "1"))

func test_private_strings_are_discarded_and_unavailable_is_null() -> void:
	var clean := TRACE.sanitized_fields({"phase": null, "token": "secret", "path": "/private", "sync_count": true, "avatar_present": false})
	assert_null(clean.phase)
	assert_false(clean.has("token"))
	assert_false(clean.has("path"))
	assert_false(clean.has("sync_count"))
	assert_false(clean.avatar_present)

func test_poll_and_stage_dedupe_and_cap_do_not_change_clocks() -> void:
	var trace := _make_trace()
	var count: int = trace._rows
	trace._process(0.5)
	assert_eq(trace._rows, count)
	trace._process(0.5)
	assert_eq(trace._rows, count + 1)
	trace.stage(8)
	count = trace._rows
	trace.stage(8)
	assert_eq(trace._rows, count)
	var fps := Engine.max_fps
	var physics := Engine.physics_ticks_per_second
	trace._rows = TRACE.MAX_ROWS - 1
	var last: Dictionary = trace.observe(0)
	assert_true(last.cap_reached)
	assert_false(trace._enabled)
	assert_eq(trace.observe(0), {})
	assert_eq(Engine.max_fps, fps)
	assert_eq(Engine.physics_ticks_per_second, physics)

func test_destroyed_before_deferred_observation_and_rejoin_has_new_generation() -> void:
	var trace := _make_trace()
	var sync := _make_sync()
	var state: Node = sync.get_parent()
	var first_instance := sync.get_instance_id()
	var first: int = trace._generation
	state.remove_child(sync)
	sync.free()
	# A deferred poll cannot access freed objects or carry their ACK state forward.
	trace.observe.call_deferred(0)
	await get_tree().process_frame
	assert_eq(trace.synchronizer_counts().sync_count, 0)
	# Rejoin creates a fresh synchronizer under the surviving authoritative state.
	# A second sibling state would be renamed by Godot and test a wrong topology.
	assert_eq(str(state.name), "ServerState")
	assert_false(state.has_node("StateSynchronizer"))
	var replacement := _make_sync(state)
	assert_ne(replacement.get_instance_id(), first_instance)
	assert_gt(trace._generation, first)
	assert_eq(trace.synchronizer_counts().replica_ack_count, 0)
	replacement._replica_ready_peers[2] = true
	assert_eq(trace.synchronizer_counts().replica_ack_count, 1)
	assert_false(replacement._is_initialized, "Observation must not initialize the replica")
