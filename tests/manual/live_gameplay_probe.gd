extends SceneTree
## Provisions a production room through the real client flow, starts a solo
## match, and exercises replicated player, mob, and projectile movement.
## Run without --headless so GameManager starts as a client.

const FLOW_TIMEOUT_SEC := 45.0
const GAMEPLAY_TIMEOUT_SEC := 60.0
const LONG_POLL_MARGIN_SEC := 2.0
const ORBIT_MIN_DISTANCE := 20.0
const ORBIT_MAX_DISTANCE := 25.0
const NEARBY_NPC_RADIUS := 90.0
const FIXED_ROUTE_CENTER := Vector3(0.0, 0.0, -240.0)
const FIXED_ROUTE_RADIUS := 60.0
const FIXED_ROUTE_WAYPOINT_REACHED := 8.0
const FIXED_ROUTE_POLL_MARGIN_SEC := 6.0
const RELEASE_TIMEOUT_SEC := 120.0

var _main: Node
var _menu: CanvasLayer
var _observed_projectile_spawns: int = 0

func _initialize() -> void:
	node_added.connect(_on_node_added)
	call_deferred("_run")

func _run() -> void:
	await process_frame
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	if main_scene == null:
		_fail("could not load main.tscn")
		return
	_main = main_scene.instantiate()
	root.add_child(_main)
	await create_timer(0.5).timeout
	_menu = _main.get_node_or_null("ConnectionMenu") as CanvasLayer
	if _menu == null:
		_fail("main.tscn is missing ConnectionMenu")
		return

	var profile_account := OS.get_environment("NOIKAR_PROFILE_ACCOUNT")
	var profile_password := OS.get_environment("NOIKAR_PROFILE_PASSWORD")
	_menu.account_edit.text = profile_account if not profile_account.is_empty() else "debugtest1"
	_menu.password_edit.text = profile_password if not profile_password.is_empty() else "debugpassword123"
	var noray_host := OS.get_environment("NOIKAR_NORAY_HOST").strip_edges()
	_menu.noray_address_edit.text = noray_host if not noray_host.is_empty() else "127.0.0.1"
	_menu._on_enter_lobby_pressed()
	if not await _wait_until(func() -> bool: return _menu.current_state == _menu.State.ROOM, 15.0):
		_fail("login did not reach ROOM")
		return

	var join_oid := OS.get_environment("NOIKAR_PROFILE_JOIN_OID").strip_edges()
	if join_oid.is_empty():
		_menu._on_host_pressed()
	else:
		_menu.room_id_edit.text = join_oid
		_menu._on_join_pressed()
	if not await _wait_until(func() -> bool: return _menu.current_state == _menu.State.TEAM_LOBBY, FLOW_TIMEOUT_SEC):
		_fail("room flow did not reach authenticated lobby")
		return
	print("[LIVE-PROBE] admitted oid=%s" % _menu._current_oid)
	var lobby_hold_sec := clampf(float(OS.get_environment("NOIKAR_PROFILE_LOBBY_HOLD_SEC")), 0.0, 30.0)
	if lobby_hold_sec > 0.0:
		print("[LIVE-PROBE] holding authenticated lobby for %.1fs" % lobby_hold_sec)
		await create_timer(lobby_hold_sec).timeout

	var player_index := _profile_player_index()
	var desired_team := _team_for_profile_player(player_index)
	_menu._on_team_choice_pressed(desired_team)
	if not await _wait_until(func() -> bool: return int(_menu._snapshot.get("team", TeamId.NONE)) == desired_team, 5.0):
		_fail("server did not accept team choice %d" % desired_team)
		return
	if not await _ensure_lobby_ready(8.0):
		_fail("server did not accept lobby ready")
		return
	var expected_players := _expected_player_count()
	if join_oid.is_empty() and expected_players > 1:
		if not await _host_start_selection_when_joined(expected_players):
			_fail("host could not start character selection for %d players; saw members=%d ready=%d" % [expected_players, _lobby_member_count(), _lobby_ready_count()])
			return
	elif not join_oid.is_empty():
		if not await _joiner_wait_for_character_selection(desired_team):
			_fail("joiner did not observe character selection start")
			return
	else:
		_menu._on_start_selection_pressed()
	if not await _wait_until(func() -> bool: return _menu.current_state == _menu.State.CHARACTER_SELECT, 5.0):
		_fail("character selection did not start")
		return
	_menu._on_character_pressed("ivern_ranger")
	_menu._on_selection_ready_toggled(true)
	if not await _wait_until(func() -> bool: return _menu.current_state == _menu.State.IN_GAME, 5.0):
		_fail("match did not enter countdown")
		return

	var player_ref: Array[Node3D] = [null]
	if not await _wait_until(func() -> bool:
		var peer_id := _local_peer_id()
		if peer_id <= 0:
			return false
		player_ref[0] = _main.get_node_or_null("Players/%s" % peer_id) as Node3D
		return player_ref[0] != null,
		GAMEPLAY_TIMEOUT_SEC):
		_fail("owned player did not spawn")
		return
	var player := player_ref[0]
	var mobs := _main.get_node("Mobs")
	var expected_mob_count := _expected_mob_count()
	var fixed_route := expected_mob_count >= 0 and OS.get_environment("NOIKAR_PROFILE_FIXED_ROUTE") == "1"
	if fixed_route:
		if not await _wait_until(func() -> bool: return mobs.get_child_count() == expected_mob_count, GAMEPLAY_TIMEOUT_SEC):
			_fail("fixed population did not replicate exact expected count %d, saw %d" % [expected_mob_count, mobs.get_child_count()])
			return
	else:
		if not await _wait_until(func() -> bool: return mobs.get_child_count() >= 20, GAMEPLAY_TIMEOUT_SEC):
			_fail("initial mob waves did not replicate")
			return
	print("[LIVE-PROBE] spawned player=%s mobs=%d fixed_population=%s" % [player.name, mobs.get_child_count(), str(fixed_route).to_lower()])
	if OS.get_environment("NOIKAR_PROFILE_HUMAN") == "1":
		await create_timer(0.5).timeout
		var human_telemetry := _client_telemetry(mobs)
		print("[LIVE-PROBE] HUMAN_READY oid=%s npc_stride_counts=%s interpolator_buffer_counts=%s" % [
			_menu._current_oid,
			str(human_telemetry.npc_stride_counts),
			str(human_telemetry.interpolator_buffer_counts),
		])
		return

	var mob_start_positions: Dictionary = {}
	for child in mobs.get_children():
		mob_start_positions[child] = child.global_position
	var player_start := player.global_position
	var logic := player.get_node_or_null("LogicComponent")
	if logic == null:
		_fail("owned player is missing LogicComponent")
		return
	var combat := player.get_node_or_null("CombatComponent")
	var attack_count_start := int(combat.sync_attack_count) if combat else -1

	var warmup_sec := clampf(float(OS.get_environment("NOIKAR_PROFILE_WARMUP_SEC")), 0.0, 300.0)
	var sample_sec := clampf(float(OS.get_environment("NOIKAR_PROFILE_SAMPLE_SEC")), 0.0, 300.0)
	var long_mode := warmup_sec > 0.0 or sample_sec > 0.0
	var max_projectiles := _observed_projectile_spawns
	var max_mob_displacement := 0.0
	var actual_sample_sec := 0.0
	var workload := "legacy"
	var workload_metrics := {}

	if long_mode:
		workload = "fixed_route" if fixed_route else "sustained_orbit"
		var long_result: Dictionary = await _run_fixed_route_profile(player, mobs, mob_start_positions, logic, warmup_sec, sample_sec, expected_mob_count) if fixed_route else await _run_orbit_profile(player, mobs, mob_start_positions, logic, warmup_sec, sample_sec)
		if not bool(long_result.get("ok", false)):
			_fail(str(long_result.get("reason", "long profile failed")))
			return
		max_projectiles = int(long_result.max_projectiles)
		max_mob_displacement = float(long_result.max_mob_displacement)
		actual_sample_sec = float(long_result.actual_sample_sec)
		workload_metrics = long_result.workload_metrics
	else:
		var closest_mob := _closest_mob(player, mobs)
		var target_delta: Vector3 = closest_mob.global_position - player.global_position
		logic.look_yaw = atan2(-target_delta.x, -target_delta.z)
		Input.action_press("move_forward")
		await create_timer(7.0).timeout
		Input.action_release("move_forward")

		closest_mob = _closest_mob(player, mobs)
		target_delta = closest_mob.global_position - player.global_position
		logic.look_yaw = atan2(-target_delta.x, -target_delta.z)
		Input.action_press("shoot")
		var shoot_deadline := Time.get_ticks_msec() + 2000
		while Time.get_ticks_msec() < shoot_deadline:
			await process_frame
			max_projectiles = max(max_projectiles, _main.get_node("Projectiles").get_child_count())
		Input.action_release("shoot")
		var exercise_deadline := Time.get_ticks_msec() + 8000
		while Time.get_ticks_msec() < exercise_deadline:
			await process_frame
			max_projectiles = max(max_projectiles, _main.get_node("Projectiles").get_child_count())
			for mob in mob_start_positions:
				if is_instance_valid(mob):
					var mob_start: Vector3 = mob_start_positions[mob]
					max_mob_displacement = max(max_mob_displacement,
						mob_start.distance_to(mob.global_position))

	max_projectiles = max(max_projectiles, _observed_projectile_spawns)
	var player_distance := player_start.distance_to(player.global_position)
	var attack_count_end := int(combat.sync_attack_count) if combat else -1
	var player_dead := bool(player.get("sync_is_dead"))
	var mobs_end := mobs.get_child_count()

	_print_client_telemetry(mobs)
	var workload_suffix := _format_workload_metrics(workload_metrics) if not workload_metrics.is_empty() else ""
	print("[LIVE-PROBE] movement=%.2fm mob_displacement=%.2fm max_projectiles=%d attacks=%d->%d dead=%s mobs=%d->%d workload=%s sample=%.2fs%s" % [
		player_distance, max_mob_displacement, max_projectiles, attack_count_start,
		attack_count_end, player_dead, mob_start_positions.size(), mobs_end, workload, actual_sample_sec, workload_suffix])
	if player_dead:
		_fail("owned player died during profiling")
		return
	if long_mode and mobs_end != mob_start_positions.size():
		_fail("mob population changed during profiling")
		return
	if player_distance < 1.0:
		_fail("owned player movement did not replicate")
		return
	if expected_mob_count != 0 and max_mob_displacement < 0.1:
		_fail("authoritative mob movement did not replicate")
		return
	if expected_mob_count != 0 and max_projectiles == 0:
		_fail("projectile spawn did not replicate")
		return

	print("[LIVE-PROBE] PASS oid=%s" % _menu._current_oid)
	if not await _await_supervisor_release():
		_fail("supervisor release barrier timed out")
		return
	_close_peer()
	quit(0)

func _expected_player_count() -> int:
	var raw := OS.get_environment("NOIKAR_PROFILE_PLAYER_COUNT")
	if raw in ["1", "2", "4", "8"]:
		return int(raw)
	return 1

func _local_peer_id() -> int:
	if _menu == null:
		return 0
	var multiplayer_api := _menu.get_multiplayer()
	if multiplayer_api == null or not multiplayer_api.has_multiplayer_peer():
		return 0
	return multiplayer_api.get_unique_id()

func _has_multiplayer_peer() -> bool:
	if _menu == null:
		return false
	var multiplayer_api := _menu.get_multiplayer()
	return multiplayer_api != null and multiplayer_api.has_multiplayer_peer()

func _owned_player_invalid_reason(reason: String) -> String:
	var safe_peer_id := _local_peer_id()
	return "%s monotonic_msec=%d multiplayer_peer_exists=%s safe_local_peer_id=%d replacement_player_exists=%s players_children=%s" % [
		reason,
		Time.get_ticks_msec(),
		str(_has_multiplayer_peer()).to_lower(),
		safe_peer_id,
		str(_replacement_player_exists(safe_peer_id)).to_lower(),
		str(_players_child_names()),
	]

func _replacement_player_exists(peer_id: int) -> bool:
	if _main == null or peer_id <= 0:
		return false
	var players := _main.get_node_or_null("Players")
	return players != null and players.get_node_or_null(str(peer_id)) != null

func _players_child_names() -> Array[String]:
	var names: Array[String] = []
	if _main == null:
		return names
	var players := _main.get_node_or_null("Players")
	if players == null:
		return names
	for child in players.get_children():
		names.append(str(child.name))
	return names

func _profile_player_index() -> int:
	var raw := OS.get_environment("NOIKAR_PROFILE_PLAYER_INDEX")
	if raw.is_valid_int():
		return max(0, int(raw))
	return 0

func _team_for_profile_player(index: int) -> int:
	var max_per_team := 3
	if _menu != null:
		max_per_team = max(1, _menu._max_players_per_team())
	return TeamId.RED if int(index / max_per_team) % 2 == 0 else TeamId.BLUE

func _lobby_member_count() -> int:
	return (_menu._snapshot.get("red_members", []) as Array).size() + (_menu._snapshot.get("blue_members", []) as Array).size()

func _lobby_ready_count() -> int:
	var count := 0
	for member in (_menu._snapshot.get("red_members", []) as Array):
		if bool(member.get("lobby_ready", false)):
			count += 1
	for member in (_menu._snapshot.get("blue_members", []) as Array):
		if bool(member.get("lobby_ready", false)):
			count += 1
	return count

func _ensure_lobby_ready(timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(_menu._snapshot.get("self_lobby_ready", false)):
			return true
		_menu._on_lobby_ready_toggled(true)
		await create_timer(0.25).timeout
	return bool(_menu._snapshot.get("self_lobby_ready", false))

func _host_start_selection_when_joined(expected_players: int) -> bool:
	var deadline := Time.get_ticks_msec() + int(FLOW_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _menu.current_state == _menu.State.CHARACTER_SELECT:
			return true
		if _lobby_member_count() >= expected_players:
			if not bool(_menu._snapshot.get("self_lobby_ready", false)):
				_menu._on_lobby_ready_toggled(true)
			elif _lobby_ready_count() >= expected_players:
				_menu._on_start_selection_pressed()
		await create_timer(0.25).timeout
	return _menu.current_state == _menu.State.CHARACTER_SELECT

func _joiner_wait_for_character_selection(desired_team: int) -> bool:
	var deadline := Time.get_ticks_msec() + int(FLOW_TIMEOUT_SEC * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _menu.current_state == _menu.State.CHARACTER_SELECT:
			return true
		if int(_menu._snapshot.get("team", TeamId.NONE)) == desired_team:
			_menu._on_lobby_ready_toggled(true)
		await create_timer(0.25).timeout
	return _menu.current_state == _menu.State.CHARACTER_SELECT

func _run_orbit_profile(player: Node3D, mobs: Node, mob_start_positions: Dictionary, logic: Node, warmup_sec: float, sample_sec: float) -> Dictionary:
	var max_projectiles := _observed_projectile_spawns
	var max_mob_displacement := 0.0
	var total_sec := warmup_sec + sample_sec + LONG_POLL_MARGIN_SEC
	var start_msec := Time.get_ticks_msec()
	var sample_start_msec := start_msec + int(warmup_sec * 1000.0)
	var sample_end_msec := sample_start_msec + int(sample_sec * 1000.0)
	var shooting_until := start_msec + 2000
	var workload_sample := _new_workload_sample(player)
	Input.action_press("shoot")
	while Time.get_ticks_msec() < start_msec + int(total_sec * 1000.0):
		await process_frame
		var now_msec := Time.get_ticks_msec()
		if not is_instance_valid(player):
			_close_peer()
			return {"ok": false, "reason": _owned_player_invalid_reason("owned player disappeared during profiling")}
		if bool(player.get("sync_is_dead")):
			_close_peer()
			return {"ok": false, "reason": "owned player died during profiling"}
		if mobs.get_child_count() != mob_start_positions.size():
			_close_peer()
			return {"ok": false, "reason": "mob population changed during profiling"}
		if now_msec >= shooting_until:
			Input.action_release("shoot")
		_drive_orbit_intention(player, mobs, logic)
		max_projectiles = max(max_projectiles, _main.get_node("Projectiles").get_child_count())
		if now_msec >= sample_start_msec and now_msec < sample_end_msec:
			_record_workload_sample(workload_sample, player, mobs)
			for mob in mob_start_positions:
				if is_instance_valid(mob):
					var mob_start: Vector3 = mob_start_positions[mob]
					max_mob_displacement = max(max_mob_displacement, mob_start.distance_to(mob.global_position))
	_close_peer()
	if not is_instance_valid(player):
		return {"ok": false, "reason": _owned_player_invalid_reason("owned player disappeared during profiling")}
	var workload_metrics := _finish_workload_sample(workload_sample, player)
	if bool(workload_metrics.workload_invalid):
		return {"ok": false, "reason": "sustained orbit invalid: no NPCs were within 90m during the measurement window"}
	return {
		"ok": true,
		"max_projectiles": max(max_projectiles, _observed_projectile_spawns),
		"max_mob_displacement": max_mob_displacement,
		"actual_sample_sec": min(sample_sec, max(0.0, float(Time.get_ticks_msec() - sample_start_msec) / 1000.0)) if Time.get_ticks_msec() >= sample_end_msec else 0.0,
		"workload_metrics": workload_metrics,
	}

func _run_fixed_route_profile(player: Node3D, mobs: Node, mob_start_positions: Dictionary, logic: Node, warmup_sec: float, sample_sec: float, expected_mob_count: int) -> Dictionary:
	var max_projectiles := _observed_projectile_spawns
	var max_mob_displacement := 0.0
	var total_sec := warmup_sec + sample_sec + FIXED_ROUTE_POLL_MARGIN_SEC
	var start_msec := Time.get_ticks_msec()
	var sample_start_msec := start_msec + int(warmup_sec * 1000.0)
	var sample_end_msec := sample_start_msec + int(sample_sec * 1000.0)
	var shooting_until := start_msec + 2000
	var waypoint_index := 0
	var workload_sample := _new_workload_sample(player)
	Input.action_press("shoot")
	while Time.get_ticks_msec() < start_msec + int(total_sec * 1000.0):
		await process_frame
		var now_msec := Time.get_ticks_msec()
		if not is_instance_valid(player):
			_close_peer()
			return {"ok": false, "reason": _owned_player_invalid_reason("owned player disappeared during profiling")}
		if bool(player.get("sync_is_dead")):
			_close_peer()
			return {"ok": false, "reason": "owned player died during profiling"}
		if mobs.get_child_count() != mob_start_positions.size():
			_close_peer()
			return {"ok": false, "reason": "mob population changed during profiling"}
		if now_msec >= shooting_until:
			Input.action_release("shoot")
		_drive_fixed_route_intention(player, logic, waypoint_index)
		if player.global_position.distance_to(_fixed_route_waypoint(waypoint_index)) <= FIXED_ROUTE_WAYPOINT_REACHED:
			waypoint_index = (waypoint_index + 1) % 8
		max_projectiles = max(max_projectiles, _main.get_node("Projectiles").get_child_count())
		if now_msec >= sample_start_msec and now_msec < sample_end_msec:
			_record_workload_sample(workload_sample, player, mobs)
			for mob in mob_start_positions:
				if is_instance_valid(mob):
					var mob_start: Vector3 = mob_start_positions[mob]
					max_mob_displacement = max(max_mob_displacement, mob_start.distance_to(mob.global_position))
	_emit_fixed_workload_end()
	_close_peer()
	if not is_instance_valid(player):
		return {"ok": false, "reason": _owned_player_invalid_reason("owned player disappeared during profiling")}
	var workload_metrics := _finish_workload_sample(workload_sample, player, expected_mob_count)
	if bool(workload_metrics.workload_invalid):
		return {"ok": false, "reason": "fixed route invalid: no player travel was recorded during the measurement window"}
	return {
		"ok": true,
		"max_projectiles": max(max_projectiles, _observed_projectile_spawns),
		"max_mob_displacement": max_mob_displacement,
		"actual_sample_sec": min(sample_sec, max(0.0, float(Time.get_ticks_msec() - sample_start_msec) / 1000.0)) if Time.get_ticks_msec() >= sample_end_msec else 0.0,
		"workload_metrics": workload_metrics,
	}

func _emit_fixed_workload_end() -> void:
	if ProjectSettings.has_setting("application/run/flush_stdout_on_print"):
		ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	print("[LIVE-PROBE] FIXED_WORKLOAD_END")

func _fixed_route_waypoint(index: int) -> Vector3:
	var angle := TAU * float(index % 8) / 8.0
	return FIXED_ROUTE_CENTER + Vector3(cos(angle) * FIXED_ROUTE_RADIUS, 0.0, sin(angle) * FIXED_ROUTE_RADIUS)

func _drive_fixed_route_intention(player: Node3D, logic: Node, waypoint_index: int) -> void:
	var target := _fixed_route_waypoint(waypoint_index)
	var delta: Vector3 = target - player.global_position
	logic.look_yaw = atan2(-delta.x, -delta.z)
	Input.action_release("move_forward")
	Input.action_release("move_backward")
	Input.action_release("move_left")
	Input.action_release("move_right")
	if delta.length() > FIXED_ROUTE_WAYPOINT_REACHED:
		Input.action_press("move_forward")
	else:
		Input.action_press("move_right")

func _drive_orbit_intention(player: Node3D, mobs: Node, logic: Node) -> void:
	var closest_mob := _closest_mob(player, mobs)
	if closest_mob == null:
		return
	var target_delta: Vector3 = closest_mob.global_position - player.global_position
	logic.look_yaw = atan2(-target_delta.x, -target_delta.z)
	var distance := player.global_position.distance_to(closest_mob.global_position)
	Input.action_release("move_forward")
	Input.action_release("move_backward")
	Input.action_release("move_left")
	Input.action_release("move_right")
	if distance > ORBIT_MAX_DISTANCE:
		Input.action_press("move_forward")
	elif distance < ORBIT_MIN_DISTANCE:
		Input.action_press("move_backward")
	else:
		Input.action_press("move_right")

func _new_workload_sample(player: Node3D) -> Dictionary:
	return {
		"nearest_min": INF,
		"nearest_max": 0.0,
		"nearest_total": 0.0,
		"samples": 0,
		"within_min": 2147483647,
		"within_max": 0,
		"alive_npcs": 0,
		"start_position": player.global_position,
		"last_position": player.global_position,
		"travel": 0.0,
	}

func _record_workload_sample(stats: Dictionary, player: Node3D, mobs: Node) -> void:
	var nearest := INF
	var within_radius := 0
	var alive_npcs := 0
	for child in mobs.get_children():
		if child is not Node3D or not is_instance_valid(child):
			continue
		if child.get("sync_is_dead") != true:
			alive_npcs += 1
		var distance := player.global_position.distance_to(child.global_position)
		nearest = min(nearest, distance)
		if distance <= NEARBY_NPC_RADIUS:
			within_radius += 1
	var last_position: Vector3 = stats.last_position
	stats.travel = float(stats.travel) + last_position.distance_to(player.global_position)
	stats.last_position = player.global_position
	stats.samples = int(stats.samples) + 1
	if nearest < INF:
		stats.nearest_min = min(float(stats.nearest_min), nearest)
		stats.nearest_max = max(float(stats.nearest_max), nearest)
		stats.nearest_total = float(stats.nearest_total) + nearest
		stats.within_min = min(int(stats.within_min), within_radius)
		stats.within_max = max(int(stats.within_max), within_radius)
		stats.alive_npcs = alive_npcs

func _finish_workload_sample(stats: Dictionary, _player: Node3D, expected_mob_count: int = -1) -> Dictionary:
	var samples := int(stats.samples)
	var start_position: Vector3 = stats.start_position
	var end_position: Vector3 = stats.last_position
	var has_npc_sample := samples > 0 and float(stats.nearest_min) < INF
	return {
		"nearest_npc_min_m": float(stats.nearest_min) if has_npc_sample else -1.0,
		"nearest_npc_mean_m": float(stats.nearest_total) / float(samples) if has_npc_sample else -1.0,
		"nearest_npc_max_m": float(stats.nearest_max) if has_npc_sample else -1.0,
		"observed_npcs_90m_min": int(stats.within_min) if has_npc_sample else 0,
		"observed_npcs_90m_max": int(stats.within_max) if has_npc_sample else 0,
		"alive_npcs": int(stats.alive_npcs),
		"player_sample_travel_m": float(stats.travel),
		"player_sample_endpoint_m": start_position.distance_to(end_position),
		"workload_invalid": samples == 0 or (expected_mob_count != 0 and int(stats.within_max) <= 0),
	}

func _format_workload_metrics(metrics: Dictionary) -> String:
	var nearest_min := "null" if float(metrics.nearest_npc_min_m) < 0.0 else "%.2f" % float(metrics.nearest_npc_min_m)
	var nearest_mean := "null" if float(metrics.nearest_npc_mean_m) < 0.0 else "%.2f" % float(metrics.nearest_npc_mean_m)
	var nearest_max := "null" if float(metrics.nearest_npc_max_m) < 0.0 else "%.2f" % float(metrics.nearest_npc_max_m)
	return " nearest_npc_m=%s/%s/%s observed_npcs_90m=%d/%d alive_npcs=%d player_sample_travel=%.2fm endpoint=%.2fm invalid=%s" % [
		nearest_min,
		nearest_mean,
		nearest_max,
		int(metrics.observed_npcs_90m_min),
		int(metrics.observed_npcs_90m_max),
		int(metrics.alive_npcs),
		float(metrics.player_sample_travel_m),
		float(metrics.player_sample_endpoint_m),
		str(bool(metrics.workload_invalid)).to_lower(),
	]

func _client_telemetry(mobs: Node) -> Dictionary:
	var stride_counts := {}
	var buffer_counts := {}
	for mob in mobs.get_children():
		if not is_instance_valid(mob):
			continue
		var server_state := mob.get_node_or_null("ServerState")
		var sync := server_state.get_node_or_null("StateSynchronizer") if server_state else null
		if sync != null:
			var stride := int(sync.get("npc_snapshot_stride"))
			stride_counts[stride] = int(stride_counts.get(stride, 0)) + 1
		var interpolator := mob.get_node_or_null("TickInterpolator")
		if interpolator != null:
			var snapshot_buffer = interpolator.get("_snapshot_buffer")
			var count := int(snapshot_buffer.get("count")) if snapshot_buffer != null else 0
			buffer_counts[count] = int(buffer_counts.get(count, 0)) + 1
	return {"npc_stride_counts": stride_counts, "interpolator_buffer_counts": buffer_counts}

func _print_client_telemetry(mobs: Node) -> void:
	var telemetry := _client_telemetry(mobs)
	print("[LIVE-PROBE] telemetry npc_stride_counts=%s interpolator_buffer_counts=%s" % [str(telemetry.npc_stride_counts), str(telemetry.interpolator_buffer_counts)])

func _expected_mob_count() -> int:
	var raw := OS.get_environment("NOIKAR_PROFILE_EXPECTED_MOB_COUNT")
	if raw in ["0", "1", "20"]:
		return int(raw)
	if raw.is_empty():
		return -1
	_fail("invalid NOIKAR_PROFILE_EXPECTED_MOB_COUNT: %s" % raw)
	return -1

func _on_node_added(node: Node) -> void:
	# --script is parsed before autoloads are available. Inspect the attached
	# script dynamically so projectile detection cannot break NetworkTime loading.
	var node_script: Script = node.get_script()
	while node_script != null:
		if node_script.resource_path == "res://common/ProjectileEntity.gd":
			_observed_projectile_spawns += 1
			return
		node_script = node_script.get_base_script()

func _wait_until(predicate: Callable, timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await process_frame
	return false

func _closest_mob(player: Node3D, mobs: Node) -> Node3D:
	var closest: Node3D = null
	var closest_distance := INF
	for child in mobs.get_children():
		if child is not Node3D:
			continue
		var distance := player.global_position.distance_squared_to(child.global_position)
		if distance < closest_distance:
			closest = child
			closest_distance = distance
	return closest

func _await_supervisor_release() -> bool:
	var release_file := OS.get_environment("NOIKAR_PROFILE_RELEASE_FILE").strip_edges()
	if release_file.is_empty():
		return true
	var timeout_sec := RELEASE_TIMEOUT_SEC
	var timeout_env := OS.get_environment("NOIKAR_PROFILE_RELEASE_TIMEOUT_SEC").strip_edges()
	if timeout_env.is_valid_float():
		timeout_sec = maxf(0.0, float(timeout_env))
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() <= deadline:
		if FileAccess.file_exists(release_file):
			return true
		await process_frame
	return false

func _close_peer() -> void:
	Input.action_release("move_forward")
	Input.action_release("move_backward")
	Input.action_release("move_left")
	Input.action_release("move_right")
	Input.action_release("shoot")

func _fail(reason: String) -> void:
	_close_peer()
	print("[LIVE-PROBE] FAIL: " + reason)
	quit(1)
