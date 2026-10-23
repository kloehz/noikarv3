extends SceneTree
## Native F5-equivalent acceptance. Uses real isolated VPS login and game traffic.
## No fixtures, Steam certification, server-side damage injection or auth bypass.
var _world: Node
var _menu: Node
var _report := {"ok": false, "transport": "ENet", "account_transport": "SSH", "steam_verified": false}

func _init() -> void:
	call_deferred("run")

func _wait(predicate: Callable, seconds := 20.0) -> bool:
	var until := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < until:
		if is_instance_valid(current_scene) and current_scene != _world:
			_world = current_scene
			_menu = _world.get_node("ConnectionMenu")
		if predicate.call(): return true
		await process_frame
	return false

func _fail(stage: String) -> void:
	_report.stage = stage
	_report.session_reason = root.get_node("GameManager").session.end_reason
	print("F5_VPS_RESULT ", JSON.stringify(_report))
	root.get_node("GameManager").session.close("VPS acceptance ended")
	await create_timer(0.5).timeout
	quit(1)

func run() -> void:
	if OS.get_environment("NOIKAR_VPS_ACCEPTANCE") != "1" or DisplayServer.get_name() == "headless":
		quit(64)
		return
	var manager := root.get_node("GameManager")
	var auth := root.get_node("AuthService")
	_world = load("res://scenes/main.tscn").instantiate()
	root.add_child(_world)
	current_scene = _world
	_menu = _world.get_node("ConnectionMenu")
	if not await _wait(func(): return manager.editor_playtest != null and manager.editor_playtest.ready_for_login(), 25.0):
		await _fail("secure VPS tunnel readiness")
		return
	var username := "vps-test-" + str(Time.get_unix_time_from_system()).replace(".", "-")
	var password := Crypto.new().generate_random_bytes(18).hex_encode()
	_menu.account_edit.text = username
	_menu.password_edit.text = password
	await _menu._on_register_pressed()
	if _menu.current_state != _menu.State.ROOM:
		await _fail("isolated account registration")
		return
	auth.clear_session()
	_menu._switch_state(_menu.State.LOGIN)
	_menu.password_edit.text = password
	await _menu._on_enter_lobby_pressed()
	password = ""
	if _menu.current_state != _menu.State.ROOM:
		await _fail("real account login")
		return
	_report.login = true
	_report.sessions = []
	for iteration in 2:
		await _menu._on_host_pressed()
		if not await _wait(func(): return _menu.current_state == _menu.State.TEAM_LOBBY):
			await _fail("VPS creator admission/team lobby")
			return
		var id: int = root.multiplayer.get_unique_id()
		if manager.session.role != "CLIENT" or id <= 1 or not _menu._snapshot.get("is_host", false):
			await _fail("dedicated authority versus human creator")
			return
		_menu._on_team_choice_pressed(TeamId.RED)
		if not await _wait(func(): return _menu._local_team == TeamId.RED):
			await _fail("server-validated team choice")
			return
		_menu._on_lobby_ready_toggled(true)
		if not await _wait(func(): return _menu._snapshot.get("self_lobby_ready", false)):
			await _fail("server-validated ready")
			return
		_menu._on_start_selection_pressed()
		if not await _wait(func(): return _menu.current_state == _menu.State.CHARACTER_SELECT):
			await _fail("creator selection start")
			return
		_menu._on_character_pressed("warrior")
		_menu._on_selection_ready_toggled(true)
		if not await _wait(func(): return _world.get_node("Players").has_node(str(id)) and manager.session.phase == "playing"):
			await _fail("single human spawn/countdown/playing")
			return
		var player := _world.get_node("Players/" + str(id))
		var combat := player.get_node("CombatComponent")
		var origin: Vector3 = player.global_position
		var attacks: int = combat.sync_attack_count
		Input.action_press("move_forward")
		Input.action_press("shoot")
		await create_timer(1.5).timeout
		Input.action_release("move_forward")
		Input.action_release("shoot")
		var moved: bool = player.global_position.distance_to(origin) > 0.1
		var attacked: bool = combat.sync_attack_count > attacks
		var mobs := await _wait(func(): return _world.get_node("Mobs").get_child_count() > 0)
		_report.sessions.append({"human_peer": id, "human_players": _world.get_node("Players").get_child_count(), "movement": moved, "attack": attacked, "mobs_present": mobs, "camera": player.has_node("CameraPivot/Camera3D")})
		if not moved or not attacked or not mobs:
			await _fail("remote movement/attack/mob replication")
			return
		if iteration == 0:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://docs/evidence/f5-vps-playtest.png")
		_menu._on_leave_room_pressed()
		if not await _wait(func(): return manager.session.phase == "menu"):
			await _fail("room exit and world reset")
			return
		_world = current_scene
		_menu = _world.get_node("ConnectionMenu")
		await create_timer(0.75).timeout
	_report.clock_inactive_after_close = root.get_node("NetworkTime")._state == root.get_node("NetworkTime")._STATE_INACTIVE
	_report.login_preserved = not auth.access_token.is_empty()
	_report.ok = _report.clock_inactive_after_close and _report.login_preserved
	var file := FileAccess.open("res://docs/evidence/f5-vps-playtest.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(_report, "\t") + "\n")
	file.close()
	print("F5_VPS_RESULT ", JSON.stringify(_report))
	quit(0 if _report.ok else 1)
