extends "res://tests/manual/editor_vps_probe.gd"
## Read-only render/history sampling in our own real VPS session. No tuning changes.
var _frames: Array = []
var _tracked: Array[Node] = []

func run() -> void:
	if OS.get_environment("NOIKAR_NPC_MOTION_PROBE") != "1" or DisplayServer.get_name() == "headless":
		quit(64)
		return
	var manager := root.get_node("GameManager")
	_world = load("res://scenes/main.tscn").instantiate()
	root.add_child(_world)
	current_scene = _world
	_menu = _world.get_node("ConnectionMenu")
	if not await _wait(func(): return manager.editor_playtest != null and manager.editor_playtest.ready_for_login(), 25.0):
		await _fail("motion probe secure tunnel")
		return
	_menu.account_edit.text = "motion-probe-" + str(Time.get_unix_time_from_system()).replace(".", "-")
	_menu.password_edit.text = Crypto.new().generate_random_bytes(18).hex_encode()
	await _menu._on_register_pressed()
	if _menu.current_state != _menu.State.ROOM:
		await _fail("motion probe registration")
		return
	await _menu._on_host_pressed()
	if not await _wait(func(): return _menu.current_state == _menu.State.TEAM_LOBBY):
		await _fail("motion probe room unavailable; no existing room was stopped")
		return
	_menu._on_team_choice_pressed(TeamId.RED)
	if not await _wait(func(): return _menu._local_team == TeamId.RED):
		await _fail("motion probe team")
		return
	_menu._on_lobby_ready_toggled(true)
	if not await _wait(func(): return _menu._snapshot.get("self_lobby_ready", false)):
		await _fail("motion probe ready")
		return
	_menu._on_start_selection_pressed()
	if not await _wait(func(): return _menu.current_state == _menu.State.CHARACTER_SELECT):
		await _fail("motion probe selection")
		return
	_menu._on_character_pressed("warrior")
	_menu._on_selection_ready_toggled(true)
	var id: int = root.multiplayer.get_unique_id()
	if not await _wait(func(): return _world.get_node("Players").has_node(str(id)) and manager.session.phase == "playing" and _world.get_node("Mobs").get_child_count() > 0):
		await _fail("motion probe playing")
		return
	var player := _world.get_node("Players/" + str(id)) as Node3D
	var mobs := _world.get_node("Mobs").get_children()
	mobs.sort_custom(func(a, b): return a.global_position.distance_squared_to(player.global_position) < b.global_position.distance_squared_to(player.global_position))
	for index in mini(4, mobs.size()): _tracked.append(mobs[index])
	var direction: Vector3 = _tracked[0].global_position - player.global_position
	var yaw := atan2(-direction.x, -direction.z)
	player.get_node("LogicComponent").look_yaw = yaw
	Input.action_press("move_forward")
	await _sample_motion(8.0)
	player.get_node("LogicComponent").look_yaw = yaw + PI
	await _sample_motion(8.0)
	Input.action_release("move_forward")
	var output := {"tickrate": root.get_node("NetworkTime").tickrate, "physics_hz": Engine.physics_ticks_per_second, "diff_states": root.get_node("NetworkRollback").enable_diff_states, "frame_count": _frames.size(), "transport": "ENet", "npc_mode": "unchanged", "frames": _frames}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/artifacts"))
	var file := FileAccess.open("res://tests/artifacts/npc-motion-vps.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(output))
	file.close()
	_menu._on_leave_room_pressed()
	await _wait(func(): return manager.session.phase == "menu")
	print("NPC_MOTION_PROBE_RESULT ", JSON.stringify({"ok": true, "frames": _frames.size(), "tracked_enemies": _tracked.size(), "pet_gameplay_sampled": false, "output": "tests/artifacts/npc-motion-vps.json"}))
	quit()

func _sample_motion(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000)
	var clock := root.get_node("NetworkTime")
	var clock_sync := root.get_node("NetworkTimeSynchronizer")
	while Time.get_ticks_msec() < until:
		await RenderingServer.frame_post_draw
		var player := _world.get_node_or_null("Players/" + str(root.multiplayer.get_unique_id())) as Node3D
		var row := {"usec": Time.get_ticks_usec(), "tick": clock.tick, "factor": clock.tick_factor, "rtt_ms": clock_sync.rtt * 1000, "rtt_jitter_ms": clock_sync.rtt_jitter * 1000, "player_position": _vector(player.global_position) if player != null else [], "entities": []}
		for entity in _tracked:
			if not is_instance_valid(entity): continue
			var sync: Node = entity.get_node("ServerState/StateSynchronizer")
			var interpolator: Node = entity.get_node("TickInterpolator")
			var source_tick: int = sync.get_latest_received_transform_tick(clock.tick)
			var source = sync.get_received_transform_snapshot(clock.tick)
			var source_position := Vector3.ZERO
			for path in source.properties():
				if str(path).ends_with(":global_position"): source_position = source.get_value(path)
			var from = interpolator._state_from.get_value(":global_position") if interpolator._state_from.has(":global_position") else null
			var to = interpolator._state_to.get_value(":global_position") if interpolator._state_to.has(":global_position") else null
			row.entities.append({"name": str(entity.name), "position": _vector(entity.global_position), "source_position": _vector(source_position), "source_tick": source_tick, "stride": sync.get_effective_snapshot_stride(), "sparse": interpolator._uses_sparse_mode(), "playback_tick": interpolator.get("_snapshot_buffer").get("_playback_tick"), "buffer_latest_tick": interpolator.get("_snapshot_buffer").latest_tick, "from": _vector(from) if from is Vector3 else null, "to": _vector(to) if to is Vector3 else null})
		_frames.append(row)

func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]
