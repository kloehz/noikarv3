extends SceneTree

## Runtime verification for tickrate-speed-calibration:
## measured real-world speed / max_speed ratio must stay in [0.9, 1.1]
## regardless of render framerate (framerate-independent rollback movement).
##
## Connects a scripted client to a running headless server, injects a
## constant forward input facing away from the mob spawn area, and measures
## horizontal speed from per-tick displacements at several Engine.max_fps
## caps. The desynced-FPS runs (40 and 144) are MANDATORY: at tickrate==fps
## a missing NetworkTime.physics_factor wrap is masked by coincidence
## (factor == 1.0), so only desynced runs prove the wrap is present.
##
## Usage (run WITHOUT --headless; headless makes GameManager self-detect
## as server and no player spawns):
##   Godot --path . --script tests/manual/runtime_movement_test.gd -- --server-port=PORT

const EXPECTED_SPEED := 10.0
const ACCEL_TICKS := 20
const MEASURE_TICKS := 90
const RATIO_MIN := 0.9
const RATIO_MAX := 1.1
## FPS caps to cover: 40/144 are desynced from tickrate 60 on purpose;
## 60 is the tickrate==fps coincidence case; 75 matches the native
## display refresh of the reference verification machine.
const FPS_MATRIX: Array[int] = [40, 60, 75, 144]

var _player: Node3D = null
var _mp: MultiplayerAPI
var _nt: Node # NetworkTime autoload (dynamic: not visible at compile time in --script)
var _tick_count := 0

func _init() -> void:
	call_deferred("_run")

## Count ticks with a persistent connection. Awaiting on_tick directly is
## unreliable at fps < tickrate: netfox emits on_tick multiple times within
## a single frame (catch-up ticks), and a signal-await sampler resumes only
## once per frame, aliasing the measurement to Nx speed.
func _count_tick(_delta: float, _tick: int) -> void:
	_tick_count += 1

## Wait until at least n ticks elapsed (frame-poll based, multi-tick safe).
func _wait_ticks(n: int) -> void:
	var target := _tick_count + n
	var deadline := Time.get_ticks_msec() + 20000
	while _tick_count < target and Time.get_ticks_msec() < deadline:
		await process_frame

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
	_nt.on_tick.connect(_count_tick)

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

	var expected_speed := EXPECTED_SPEED
	var logic := _find_logic()
	if logic:
		logic.look_yaw = PI
		if logic.get("max_speed") != null:
			expected_speed = logic.max_speed
		print("[RT-TEST] look_yaw set to PI (flee direction); max_speed=%.1f" % expected_speed)

	# Let time-sync and spawn settle (~1s)
	var tickrate: int = max(1, _nt.tickrate)
	print("[RT-TEST] tickrate=%d" % tickrate)
	await _wait_ticks(tickrate)

	# Disable vsync so Engine.max_fps actually governs the render rate;
	# otherwise the display refresh masks the desynced-FPS passes.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	# Measure per-tick displacements at each FPS cap.
	var failed := false
	var results: Array[Dictionary] = []
	for fps in FPS_MATRIX:
		var result := await _measure_pass(fps, tickrate, expected_speed)
		results.append(result)
		if result.ratio < RATIO_MIN or result.ratio > RATIO_MAX:
			failed = true

	Input.action_release("move_forward")

	print("[RT-TEST] ---- fps matrix (band [%.2f, %.2f]) ----" % [RATIO_MIN, RATIO_MAX])
	for r in results:
		var status := "PASS" if r.ratio >= RATIO_MIN and r.ratio <= RATIO_MAX else "FAIL"
		print("[RT-TEST] fps=%3d speed=%.3f ratio=%.2f (frame p50=%.3f p75=%.3f p90=%.3f) %s" % [r.fps, r.speed, r.ratio, r.p50, r.p75, r.p90, status])

	if failed:
		print("[RT-TEST] FAIL: speed/max_speed ratio outside [%.2f, %.2f] in at least one run" % [RATIO_MIN, RATIO_MAX])
		quit(1)
	else:
		print("[RT-TEST] PASS: framerate-independent movement at tickrate %d" % tickrate)
		quit(0)

## Measure steady-state speed for MEASURE_TICKS ticks under the given FPS cap.
## Sampling is per frame but normalized by the tick counter, so frames running
## 0, 1, or N catch-up ticks all yield correct per-tick speeds.
func _measure_pass(fps: int, tickrate: int, expected_speed: float) -> Dictionary:
	Engine.max_fps = fps
	# Let the new frame rate stabilize before sampling.
	var settle_deadline := Time.get_ticks_msec() + 500
	while Time.get_ticks_msec() < settle_deadline:
		await process_frame

	# Inject constant forward input and reach steady speed
	Input.action_press("move_forward")
	await _wait_ticks(ACCEL_TICKS)

	var speeds: Array[float] = []
	var sampled_ticks := 0
	var total_displacement := 0.0
	var prev_pos: Vector3 = _player.global_position
	var prev_ticks := _tick_count
	var deadline := Time.get_ticks_msec() + 20000
	while sampled_ticks < MEASURE_TICKS and Time.get_ticks_msec() < deadline:
		await process_frame
		var ticks_now := _tick_count
		var ticks_delta := ticks_now - prev_ticks
		var pos: Vector3 = _player.global_position
		var d := pos - prev_pos
		d.y = 0.0
		prev_pos = pos
		prev_ticks = ticks_now
		total_displacement += d.length()
		if ticks_delta > 0:
			speeds.append(d.length() * float(tickrate) / float(ticks_delta))
			sampled_ticks += ticks_delta
		if _player.get("sync_is_dead"):
			print("[RT-TEST] WARN: player died during measurement (fps=%d)" % fps)
			break

	if sampled_ticks < 30:
		print("[RT-TEST] FAIL: insufficient clean samples (%d ticks) at fps=%d" % [sampled_ticks, fps])
		quit(1)
		return {}

	# Assert on aggregate speed over the whole window. Per-frame attribution of
	# displacement lags by one frame (node transform syncs from the physics
	# server at frame end), which distorts per-frame samples at fps < tickrate
	# (multi-tick frames) but cancels out over the window.
	speeds.sort()
	var p50: float = speeds[int(speeds.size() * 0.50)]
	var p75: float = speeds[int(speeds.size() * 0.75)]
	var p90: float = speeds[int(speeds.size() * 0.90)]
	var aggregate_speed := total_displacement * float(tickrate) / float(sampled_ticks)
	return {"fps": fps, "p50": p50, "p75": p75, "p90": p90, "speed": aggregate_speed, "ratio": aggregate_speed / expected_speed}

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
