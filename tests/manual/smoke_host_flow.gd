extends SceneTree
## Headless smoke test for the host flow.
## Drives ConnectionManager._on_host_pressed() against the running backend +
## noray, mirroring what the Create Room button does. Quits the process after
## one complete iteration and quits with a process-level pass/fail result.

const ITERATIONS := 1
const ITERATION_TIMEOUT_SEC := 45.0
const SETTLE_DELAY_SEC := 1.0

var _iter := 0
var _phase := "init"
var _phase_started_at := 0.0
var _fail_reason := ""
var _current_main: Node = null
var _current_menu: CanvasLayer = null
var _noray: Node = null
var _auth_service: Node = null

func _initialize() -> void:
	print("==================================================")
	print("[smoke] starting %d host-flow iterations" % ITERATIONS)
	print("==================================================")
	# Autoloads are loaded by the project even when running with --script.
	# Resolve them explicitly so we drive the same instance the menu uses.
	if not root.has_node("Noray"):
		var noray_script: Script = load("res://addons/netfox.noray/noray.gd")
		if noray_script == null:
			push_error("[smoke] could not load noray.gd")
			quit(1)
			return
		_noray = noray_script.new()
		_noray.name = "Noray"
		root.add_child(_noray)
	else:
		_noray = root.get_node("Noray")

	_iteration = func() -> void: _run_iteration()
	_iteration.call()

func _ts() -> float:
	return Time.get_ticks_msec() / 1000.0

func _enter_phase(name: String) -> void:
	_phase = name
	_phase_started_at = _ts()
	print("[smoke] iter=%d -> %s" % [_iter, name])

func _run_iteration() -> void:
	_iter += 1
	if _iter > ITERATIONS:
		print("[smoke] DONE — all %d iterations completed without a hang" % ITERATIONS)
		quit(0)
		return

	_enter_phase("boot")
	if _noray != null and is_instance_valid(_noray):
		_noray.disconnect_from_host()
	await create_timer(SETTLE_DELAY_SEC).timeout

	_enter_phase("load_menu")
	var main_scene: PackedScene = load("res://scenes/main.tscn") as PackedScene
	if main_scene == null:
		_fail("could not load main.tscn")
		return
	_current_main = main_scene.instantiate()
	root.add_child(_current_main)
	await create_timer(0.5).timeout
	_current_menu = _current_main.get_node_or_null("ConnectionMenu") as CanvasLayer
	if _current_menu == null:
		_fail("main.tscn is missing ConnectionMenu")
		return

	_enter_phase("login")
	_current_menu.account_edit.text = "debugtest1"
	_current_menu.password_edit.text = "debugpassword123"
	_current_menu._on_enter_lobby_pressed()
	var login_deadline := _ts() + 15.0
	while _ts() < login_deadline:
		await create_timer(0.1).timeout
		if _current_menu == null or not is_instance_valid(_current_menu):
			_fail("menu freed during login")
			return
		if _current_menu.current_state == _current_menu.State.ROOM:
			break
	if _current_menu.current_state != _current_menu.State.ROOM:
		_fail("login did not reach ROOM state (status=%s)" % _current_menu.login_status.text)
		return
	print("[smoke] iter=%d login OK" % _iter)

	_enter_phase("host_pressed")
	_current_menu._on_host_pressed()

	var flow_deadline := _ts() + ITERATION_TIMEOUT_SEC
	while _ts() < flow_deadline:
		await create_timer(0.1).timeout
		if _current_menu == null or not is_instance_valid(_current_menu):
			_fail("menu freed during host flow")
			return
		if _current_menu.current_state == _current_menu.State.ROOM:
			var reason: String = _current_menu.status_label.text
			_fail("host flow dropped back to ROOM. status_label='%s' room_status='%s'" % [
				reason, _current_menu.room_status.text])
			return
		if _current_menu.current_state == _current_menu.State.TEAM_LOBBY \
				and not _current_menu._current_oid.is_empty() \
				and _current_menu.multiplayer.has_multiplayer_peer():
			print("[smoke] iter=%d host flow OK oid=%s" % [_iter, _current_menu._current_oid])
			break

	if _current_menu.current_state != _current_menu.State.TEAM_LOBBY:
		_fail("host flow never reached authenticated lobby after %.1fs (state=%d status=%s)" % [
			ITERATION_TIMEOUT_SEC, _current_menu.current_state, _current_menu.status_label.text])
		return

	_enter_phase("teardown")
	print("[smoke] DONE — all %d iterations completed without a hang" % ITERATIONS)
	quit(0)

func _fail(reason: String) -> void:
	_fail_reason = reason
	print("[smoke] FAIL on iter=%d at phase=%s: %s" % [_iter, _phase, reason])
	if _current_menu != null and is_instance_valid(_current_menu):
		print("[smoke] DEBUG state=%d status_label='%s' room_status='%s' oid='%s' has_peer=%s" % [
			_current_menu.current_state,
			_current_menu.status_label.text,
			_current_menu.room_status.text,
			_current_menu._current_oid,
			_current_menu.multiplayer.has_multiplayer_peer(),
		])
	quit(1)

var _iteration: Callable
