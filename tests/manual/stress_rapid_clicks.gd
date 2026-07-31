extends SceneTree
## Stress test: click CREATE ROOM multiple times in rapid succession while a
## previous flow is still in flight. Reproduces the kind of state corruption
## that could cause "nothing happens" symptoms.

const ITERATIONS := 3
const RAPID_CLICKS := 3
const FLOW_TIMEOUT_SEC := 30.0

var _iter := 0
var _current_menu: CanvasLayer = null
var _noray: Node = null
var _auth_service: Node = null

func _initialize() -> void:
	_noray = load("res://addons/netfox.noray/noray.gd").new()
	_noray.name = "Noray"
	root.add_child(_noray)
	_auth_service = load("res://common/auth_service.gd").new()
	_auth_service.name = "AuthService"
	root.add_child(_auth_service)
	_run.call()

func _ts() -> float:
	return Time.get_ticks_msec() / 1000.0

func _run() -> void:
	for i in range(ITERATIONS):
		_iter = i + 1
		print("\n==== STRESS iter %d/%d ====" % [_iter, ITERATIONS])
		# Boot fresh
		if _current_menu != null and is_instance_valid(_current_menu):
			_current_menu.queue_free()
		if _noray.is_connected_to_host():
			_noray.disconnect_from_host()
		await create_timer(1.0).timeout

		# Load menu and login
		var menu_scene: PackedScene = load("res://scenes/connection_menu.tscn")
		_current_menu = menu_scene.instantiate()
		root.add_child(_current_menu)
		await create_timer(0.5).timeout
		_current_menu.account_edit.text = "debugtest1"
		_current_menu.password_edit.text = "debugpassword123"
		_current_menu._on_enter_lobby_pressed()
		var login_deadline := _ts() + 10.0
		while _ts() < login_deadline and _current_menu.current_state != _current_menu.State.ROOM:
			await create_timer(0.1).timeout
		if _current_menu.current_state != _current_menu.State.ROOM:
			print("[stress] iter %d login failed" % _iter)
			continue

		# Rapid-fire 3 clicks back-to-back
		print("[stress] iter %d firing %d rapid host clicks" % [_iter, RAPID_CLICKS])
		for c in range(RAPID_CLICKS):
			_current_menu._on_host_pressed()
			await create_timer(0.05).timeout

		# Wait for the flow to either complete or hang
		var deadline := _ts() + FLOW_TIMEOUT_SEC
		var done := false
		while _ts() < deadline and not done:
			await create_timer(0.1).timeout
			if not _current_menu._current_oid.is_empty() and _current_menu.multiplayer.has_multiplayer_peer():
				print("[stress] iter %d SUCCESS oid=%s" % [_iter, _current_menu._current_oid])
				done = true
			elif _current_menu.current_state == _current_menu.State.ROOM:
				print("[stress] iter %d FAILED state=ROOM status='%s'" % [
					_iter, _current_menu.status_label.text])
				done = true
		if not done:
			print("[stress] iter %d HANG state=%d status='%s' oid='%s'" % [
				_iter, _current_menu.current_state, _current_menu.status_label.text, _current_menu._current_oid])

		# Teardown
		if _current_menu.multiplayer.has_multiplayer_peer():
			_current_menu.multiplayer.multiplayer_peer.close()
		_current_menu.queue_free()
		_current_menu = null
		await create_timer(2.0).timeout

	print("[stress] all iterations done")
	quit(0)