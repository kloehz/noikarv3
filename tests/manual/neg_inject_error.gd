extends SceneTree
## Negative-path test: feed an `error Failed to provision server` line into
## Noray the same way noray.mjs would when the headless Godot process dies
## before reaching register-server / server-ready. The smoke test should
## surface the error so the UI can roll back instead of hanging on
## `await Noray.on_host_ready` forever.
##
## IMPORTANT: This script does NOT instantiate its own Noray/AuthService —
## those autoloads are loaded by the project automatically. Adding shadow
## copies under /root/Noray would override the autoload and the menu's
## `Noray.*` calls would never see our injected error line.

const ITERATIONS := 2
const TIMEOUT_SEC := 8.0

var _iter := 0
var _current_menu: CanvasLayer = null

func _initialize() -> void:
	_run.call()

func _ts() -> float:
	return Time.get_ticks_msec() / 1000.0

func _run() -> void:
	if not root.has_node("Noray"):
		print("[neg] FAIL: Noray autoload missing — check project.godot")
		quit(1)
		return
	var noray: Node = root.get_node("Noray")
	for i in range(ITERATIONS):
		_iter = i + 1
		print("\n==== NEG iter %d/%d ====" % [_iter, ITERATIONS])
		if _current_menu != null and is_instance_valid(_current_menu):
			_current_menu.queue_free()
		if noray.is_connected_to_host():
			noray.disconnect_from_host()
		await create_timer(1.0).timeout

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
			print("[neg] iter %d login failed" % _iter)
			continue

		print("[neg] iter %d starting host flow" % _iter)
		_current_menu._on_host_pressed()

		# Give the client time to:
		#  - connect to noray
		#  - issue the backend ticket (one HTTP roundtrip)
		#  - write request-host
		#  - enter the race inside _await_host_provisioning
		# Then inject the same error line noray sends on spawn failure.
		# Inject EARLY so we beat the real spawn completion.
		await create_timer(0.4).timeout
		noray._protocol.ingest("error Failed to provision server\n")
		print("[neg] iter %d injected error line (early)" % _iter)

		var deadline := _ts() + TIMEOUT_SEC
		var done := false
		while _ts() < deadline and not done:
			await create_timer(0.1).timeout
			if _current_menu.current_state == _current_menu.State.ROOM:
				print("[neg] iter %d recovered to ROOM status='%s'" % [
					_iter, _current_menu.status_label.text])
				done = true
			elif not _current_menu._current_oid.is_empty():
				print("[neg] iter %d unexpectedly succeeded oid=%s" % [_iter, _current_menu._current_oid])
				done = true
		if not done:
			print("[neg] iter %d HANG state=%d status='%s' oid='%s'" % [
				_iter, _current_menu.current_state, _current_menu.status_label.text, _current_menu._current_oid])

		if _current_menu.multiplayer.has_multiplayer_peer():
			_current_menu.multiplayer.multiplayer_peer.close()
		_current_menu.queue_free()
		_current_menu = null
		await create_timer(2.0).timeout

	print("[neg] all iterations done")
	quit(0)