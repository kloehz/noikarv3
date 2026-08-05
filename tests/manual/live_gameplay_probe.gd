extends SceneTree
## Provisions a production room through the real client flow, starts a solo
## match, and exercises replicated player, mob, and projectile movement.
## Run without --headless so GameManager starts as a client.

const FLOW_TIMEOUT_SEC := 45.0
const GAMEPLAY_TIMEOUT_SEC := 20.0

var _main: Node
var _menu: CanvasLayer

func _initialize() -> void:
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

	_menu.account_edit.text = "debugtest1"
	_menu.password_edit.text = "debugpassword123"
	_menu._on_enter_lobby_pressed()
	if not await _wait_until(func() -> bool: return _menu.current_state == _menu.State.ROOM, 15.0):
		_fail("login did not reach ROOM")
		return

	_menu._on_host_pressed()
	if not await _wait_until(func() -> bool: return _menu.current_state == _menu.State.TEAM_LOBBY, FLOW_TIMEOUT_SEC):
		_fail("host flow did not reach authenticated lobby")
		return
	print("[LIVE-PROBE] admitted oid=%s" % _menu._current_oid)

	_menu._on_team_choice_pressed(TeamId.RED)
	if not await _wait_until(func() -> bool: return int(_menu._snapshot.get("team", TeamId.NONE)) == TeamId.RED, 5.0):
		_fail("server did not accept RED team choice")
		return
	_menu._on_lobby_ready_toggled(true)
	if not await _wait_until(func() -> bool: return bool(_menu._snapshot.get("self_lobby_ready", false)), 5.0):
		_fail("server did not accept lobby ready")
		return
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
		player_ref[0] = _main.get_node_or_null("Players/%s" % _menu.multiplayer.get_unique_id()) as Node3D
		return player_ref[0] != null,
		GAMEPLAY_TIMEOUT_SEC):
		_fail("owned player did not spawn")
		return
	var player := player_ref[0]
	var mobs := _main.get_node("Mobs")
	if not await _wait_until(func() -> bool: return mobs.get_child_count() >= 20, GAMEPLAY_TIMEOUT_SEC):
		_fail("initial mob waves did not replicate")
		return
	print("[LIVE-PROBE] spawned player=%s mobs=%d" % [player.name, mobs.get_child_count()])

	var mob_start_positions: Dictionary = {}
	for child in mobs.get_children():
		mob_start_positions[child] = child.global_position
	var player_start := player.global_position
	var logic := player.get_node_or_null("LogicComponent")
	if logic == null:
		_fail("owned player is missing LogicComponent")
		return
	var closest_mob := _closest_mob(player, mobs)
	var target_delta: Vector3 = closest_mob.global_position - player.global_position
	logic.look_yaw = atan2(-target_delta.x, -target_delta.z)
	Input.action_press("move_forward")
	await create_timer(7.0).timeout
	Input.action_release("move_forward")
	var player_distance := player_start.distance_to(player.global_position)

	var max_projectiles := 0
	var max_mob_displacement := 0.0
	closest_mob = _closest_mob(player, mobs)
	target_delta = closest_mob.global_position - player.global_position
	logic.look_yaw = atan2(-target_delta.x, -target_delta.z)
	var combat := player.get_node_or_null("CombatComponent")
	var attack_count_start := int(combat.sync_attack_count) if combat else -1
	Input.action_press("shoot")
	await create_timer(2.0).timeout
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
	var attack_count_end := int(combat.sync_attack_count) if combat else -1
	var player_dead := bool(player.get("sync_is_dead"))

	print("[LIVE-PROBE] movement=%.2fm mob_displacement=%.2fm max_projectiles=%d attacks=%d->%d dead=%s" % [
		player_distance, max_mob_displacement, max_projectiles, attack_count_start,
		attack_count_end, player_dead])
	if player_distance < 1.0:
		_fail("owned player movement did not replicate")
		return
	if max_mob_displacement < 0.1:
		_fail("authoritative mob movement did not replicate")
		return
	if max_projectiles == 0:
		_fail("projectile spawn did not replicate")
		return

	_close_peer()
	print("[LIVE-PROBE] PASS oid=%s" % _menu._current_oid)
	quit(0)

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

func _close_peer() -> void:
	Input.action_release("move_forward")
	Input.action_release("shoot")

func _fail(reason: String) -> void:
	_close_peer()
	print("[LIVE-PROBE] FAIL: " + reason)
	quit(1)
