extends SceneTree

## Runtime verification for rollback-integrity-baseline task 5.1:
## one input -> exactly one movement per tick (no double-tick).
##
## Connects a scripted client to a running headless server, injects a
## constant forward input facing away from the mob spawn area, and
## measures horizontal speed from per-tick displacements (p75).
## Expected ~max_speed (10.0). A LogicComponent double-tick yields ~2x.
##
## Usage:
##   Godot --path . --script tests/manual/runtime_movement_test.gd -- --server-port=PORT

const EXPECTED_SPEED := 10.0
const ACCEL_TICKS := 20
const MEASURE_TICKS := 90

var _player: Node3D = null
var _mp: MultiplayerAPI
var _nt: Node # NetworkTime autoload (dynamic: not visible at compile time in --script)

func _init() -> void:
	call_deferred("_run")

func _tick_wait() -> void:
	await _nt.on_tick

func _run() -> void:
	await process_frame
	await process_frame

	var port := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server-port="):
			port = int(arg.get_slice("=", 1))
	if port == 0:
		print("[RT-TEST] FAIL: missing --server-port=")
		quit(1)
		return

	# Load main scene so MultiplayerSpawner paths exist for replication.
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	root.add_child(main_scene.instantiate())
	await process_frame
	_mp = get_multiplayer()
	_nt = root.get_node_or_null("NetworkTime")
	if _nt == null:
		print("[RT-TEST] FAIL: NetworkTime autoload not found")
		quit(1)
		return

	print("[RT-TEST] Connecting to 127.0.0.1:%d ..." % port)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client("127.0.0.1", port)
	if err != OK:
		print("[RT-TEST] FAIL: create_client err=%d" % err)
		quit(1)
		return
	_mp.multiplayer_peer = peer

	if not await _wait_connection(10.0):
		print("[RT-TEST] FAIL: connection timeout/failure")
		quit(1)
		return
	print("[RT-TEST] connected_to_server, peer id=%d" % _mp.get_unique_id())

	# Wait for our player to spawn (numeric node name == our peer id)
	var deadline := Time.get_ticks_msec() + 10000
	while _player == null and Time.get_ticks_msec() < deadline:
		_player = _find_player()
		if _player == null:
			await process_frame
	if _player == null:
		print("[RT-TEST] FAIL: no player spawned within 10s")
		quit(1)
		return
	print("[RT-TEST] Player spawned: %s at %s" % [_player.name, str(_player.global_position)])

	# Face away from mobs (mobs at z<0; spawn at z>0 -> run toward +Z)
	var logic := _find_logic()
	if logic:
		logic.look_yaw = PI
		print("[RT-TEST] look_yaw set to PI (flee direction)")

	# Let time-sync and spawn settle (~1s)
	var tickrate: int = max(1, _nt.tickrate)
	for i in range(tickrate):
		await _tick_wait()

	# Inject constant forward input and reach steady speed
	Input.action_press("move_forward")
	for i in range(ACCEL_TICKS):
		await _tick_wait()

	# Measure per-tick displacements
	var speeds: Array[float] = []
	var prev_pos: Vector3 = _player.global_position
	for i in range(MEASURE_TICKS):
		await _tick_wait()
		var pos: Vector3 = _player.global_position
		var d := pos - prev_pos
		d.y = 0.0
		speeds.append(d.length() * float(tickrate))
		prev_pos = pos
		if _player.get("sync_is_dead"):
			print("[RT-TEST] WARN: player died during measurement")
			break

	Input.action_release("move_forward")
	print("[RT-TEST] sampled %d ticks at tickrate=%d" % [speeds.size(), tickrate])

	if speeds.size() < 30:
		print("[RT-TEST] FAIL: insufficient clean samples (%d)" % speeds.size())
		quit(1)
		return

	speeds.sort()
	var p50: float = speeds[int(speeds.size() * 0.50)]
	var p75: float = speeds[int(speeds.size() * 0.75)]
	var p90: float = speeds[int(speeds.size() * 0.90)]
	var ratio := p75 / EXPECTED_SPEED
	print("[RT-TEST] speed p50=%.3f p75=%.3f p90=%.3f expected=%.3f" % [p50, p75, p90, EXPECTED_SPEED])
	print("[RT-TEST] ratio(p75/expected)=%.2f" % ratio)

	if p75 < EXPECTED_SPEED * 0.3:
		print("[RT-TEST] FAIL: no movement (blocked? input not sampled? died?)")
		quit(1)
	elif ratio > 1.5:
		print("[RT-TEST] FAIL: DOUBLE-TICK detected (ratio %.2f)" % ratio)
		quit(1)
	else:
		print("[RT-TEST] PASS: single-tick movement (ratio %.2f)" % ratio)
		quit(0)

func _wait_connection(timeout_sec: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var status: int = _mp.multiplayer_peer.get_connection_status()
		if status == MultiplayerPeer.CONNECTION_CONNECTED:
			return true
		if status == MultiplayerPeer.CONNECTION_DISCONNECTED:
			return false
		await process_frame
	return false

func _find_player() -> Node3D:
	var main := root.get_node_or_null("Main")
	if main == null:
		return null
	var players := main.get_node_or_null("Players")
	if players == null:
		return null
	var my_id: int = _mp.get_unique_id()
	for child in players.get_children():
		if child.name.is_valid_int() and child.name.to_int() == my_id:
			return child
	return null

func _find_logic() -> Node:
	if _player == null:
		return null
	for child in _player.get_children():
		if child.has_method("_rollback_tick") and "input_axis" in child:
			return child
	return null
