extends Node
## Opt-in benchmark observer. Never changes simulation, phases, resources or clocks.
## Public signal wall durations overlap: network includes rollback; neither is CPU time.
const MAX_ROWS := 180
const MAX_INTERVALS := 4096
const MONITORS := {
	"network_loop_ms": &"netfox/Network loop duration (ms)",
	"rollback_loop_ms": &"netfox/Rollback loop duration (ms)",
	"network_ticks": &"netfox/Network ticks simulated",
	"rollback_ticks": &"netfox/Rollback ticks simulated",
	"rollback_nodes": &"netfox/Rollback nodes simulated",
}
var _enabled := false
var _network_time: Node
var _rollback: Node
var _client := true
var _index := -1
var _phase_provider: Callable
var _rows := 0
var _row_start := 0
var _process_start := 0
var _physics_start := 0
var _native_start := 0
var _native_total := 0
var _last_tick := 0
var _intervals: Array[float] = []
var _intervals_dropped := 0
var _network_start := 0
var _network_ticks := 0
var _network_calls := 0
var _network_usec := 0
var _catchup_extra := 0
var _network_max_ticks := 0
var _rollback_start := 0
var _rollback_calls := 0
var _rollback_ticks := 0
var _rollback_usec := 0
var _activation := {"actor_load_calls": 0, "actor_load_usec": 0, "actor_load_max_usec": 0,
	"entity_ready_calls": 0, "entity_ready_usec": 0, "entity_ready_max_usec": 0}
var _warmup_until := 0
var _window_index := 0
var _window_count := 3
var _warmup_usec := 10000000
var _window_start := 0
var _window_unix_start := 0
var _window_native_start := 0
var _window_population_start := {}
var _window_population_rows: Array[Dictionary] = []
var _window_stride_start := {}

static func unix_usec() -> int:
	return int(Time.get_unix_time_from_system() * 1000000.0)

func start_client(index: int, phase_provider: Callable) -> void:
	_index = index
	_phase_provider = phase_provider
	_start(true)

func start_server_windows(window_count: int = 3, warmup_seconds: float = 10.0) -> void:
	_window_count = window_count
	_warmup_usec = int(warmup_seconds * 1000000.0)
	_start(false)

func _start(client: bool) -> void:
	_client = client
	_network_time = get_node_or_null("/root/NetworkTime")
	_rollback = get_node_or_null("/root/NetworkRollback")
	if _network_time == null or _rollback == null:
		return
	_enabled = true
	_row_start = Time.get_ticks_usec()
	_process_start = Engine.get_process_frames()
	_physics_start = Engine.get_physics_frames()
	add_to_group(&"benchmark_observer")
	_network_time.on_tick.connect(_on_native_tick)
	_network_time.before_tick_loop.connect(_before_network_loop)
	_network_time.after_tick_loop.connect(_after_network_loop)
	_rollback.before_loop.connect(_before_rollback_loop)
	_rollback.after_process_tick.connect(_on_rollback_tick)
	_rollback.after_loop.connect(_after_rollback_loop)

func _process(_delta: float) -> void:
	if not _enabled:
		return
	var now := Time.get_ticks_usec()
	if not _client:
		_poll_server_windows(now)
	if now - _row_start >= 1000000 and _rows < MAX_ROWS:
		if _client:
			printerr("[PROFILE_CLIENT_OBSERVATION] " + JSON.stringify(take_client_row(now)))
		else:
			var population := _population()
			printerr("[PROFILE_SERVER_OBSERVATION] " + JSON.stringify({"schema": 1, "row": _rows,
				"unix_usec": unix_usec(), "uptime_usec": now, "population": population}))
			if _window_start > 0:
				_window_population_rows.append(population)
			_row_start = now
		_rows += 1
	if _rows >= MAX_ROWS:
		_enabled = false

func _on_native_tick(_delta: float, _tick: int) -> void:
	if not _enabled:
		return
	_native_total += 1
	_network_ticks += 1
	if _client or _window_start > 0:
		var now := Time.get_ticks_usec()
		if _last_tick > 0:
			if _intervals.size() < MAX_INTERVALS:
				_intervals.append((now - _last_tick) / 1000.0)
			else:
				_intervals_dropped += 1
		_last_tick = now

func _before_network_loop() -> void:
	_network_start = Time.get_ticks_usec()
	_network_ticks = 0

func _after_network_loop() -> void:
	if not _enabled:
		return
	_network_calls += 1
	_network_usec += Time.get_ticks_usec() - _network_start
	_catchup_extra += maxi(0, _network_ticks - 1)
	_network_max_ticks = maxi(_network_max_ticks, _network_ticks)

func _before_rollback_loop() -> void:
	_rollback_start = Time.get_ticks_usec()

func _on_rollback_tick(_tick: int) -> void:
	if _enabled:
		_rollback_ticks += 1

func _after_rollback_loop() -> void:
	if _enabled:
		_rollback_calls += 1
		_rollback_usec += Time.get_ticks_usec() - _rollback_start

func record_activation(kind: int, elapsed_usec: int) -> void:
	if not _enabled or not _client:
		return
	var prefix := "actor_load" if kind == 1 else "entity_ready"
	_activation[prefix + "_calls"] += 1
	_activation[prefix + "_usec"] += maxi(0, elapsed_usec)
	_activation[prefix + "_max_usec"] = maxi(_activation[prefix + "_max_usec"], elapsed_usec)

static func percentile(values: Array[float], quantile: float) -> Variant:
	if values.is_empty():
		return null
	var ordered := values.duplicate()
	ordered.sort()
	return ordered[clampi(ceili(quantile * ordered.size()) - 1, 0, ordered.size() - 1)]

func _last_loop_monitors() -> Dictionary:
	var result := {}
	for key in MONITORS:
		result[key] = Performance.get_custom_monitor(MONITORS[key]) if Performance.has_custom_monitor(MONITORS[key]) else null
	return result

func take_client_row(now: int) -> Dictionary:
	var process_frames := Engine.get_process_frames()
	var physics_frames := Engine.get_physics_frames()
	var seconds := float(now - _row_start) / 1000000.0
	var row := {"schema": 1, "index": _index, "row": _rows, "unix_usec": unix_usec(),
		"uptime_usec": now, "interval_usec": now - _row_start,
		"phase": int(_phase_provider.call()) if _phase_provider.is_valid() else -1,
		"process_frames": process_frames - _process_start, "physics_frames": physics_frames - _physics_start,
		"native_ticks": _native_total - _native_start,
		"effective_process_hz": (process_frames - _process_start) / seconds if seconds > 0 else null,
		"effective_physics_hz": (physics_frames - _physics_start) / seconds if seconds > 0 else null,
		"effective_native_hz": (_native_total - _native_start) / seconds if seconds > 0 else null,
		"max_fps": Engine.max_fps, "physics_hz": Engine.physics_ticks_per_second,
		"native_hz": _network_time.get("tickrate") if _network_time != null else null, "network_loop_calls": _network_calls,
		"network_loop_usec_inclusive": _network_usec, "network_max_ticks_per_loop": _network_max_ticks,
		"catchup_extra_native_ticks": _catchup_extra, "rollback_loop_calls": _rollback_calls,
		"rollback_process_tick_callbacks": _rollback_ticks, "rollback_loop_usec_inclusive": _rollback_usec,
		"native_interval_p95_ms": percentile(_intervals, 0.95), "native_interval_p99_ms": percentile(_intervals, 0.99),
		"native_interval_dropped": _intervals_dropped, "last_loop_monitors": _last_loop_monitors(),
		"players": get_tree().get_nodes_in_group(&"players").size(), "mobs": get_tree().get_nodes_in_group(&"mobs").size(),
		"activation": _activation.duplicate()}
	_row_start = now
	_process_start = process_frames
	_physics_start = physics_frames
	_native_start = _native_total
	_network_calls = 0; _network_usec = 0; _catchup_extra = 0; _network_max_ticks = 0
	_rollback_calls = 0; _rollback_ticks = 0; _rollback_usec = 0
	for key in _activation:
		_activation[key] = 0
	_reset_intervals()
	return row

func _reset_intervals() -> void:
	_intervals.clear()
	_intervals_dropped = 0
	_last_tick = 0

func _population() -> Dictionary:
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	return manager.profile_owner_population() if manager != null else {}

func _strides() -> Dictionary:
	var probe := get_node_or_null("/root/PerfProbe")
	return probe._count_authoritative_npc_stride_counts() if probe != null else {}

func _begin_window(now: int) -> void:
	_window_start = now
	_window_unix_start = unix_usec()
	_window_native_start = _native_total
	_window_population_start = _population()
	_window_population_rows.clear()
	_window_stride_start = _strides()
	_reset_intervals()

func finish_window(now: int, end_unix: int) -> Dictionary:
	var elapsed := now - _window_start
	var ticks := _native_total - _window_native_start
	return {"schema": 1, "index": _window_index, "start_unix_usec": _window_unix_start,
		"end_unix_usec": end_unix, "duration_usec": elapsed, "native_ticks": ticks,
		"native_achieved_hz": float(ticks) * 1000000.0 / elapsed if elapsed > 0 else null,
		"native_interval_p95_ms": percentile(_intervals, 0.95), "native_interval_p99_ms": percentile(_intervals, 0.99),
		"native_interval_samples": _intervals.size(), "native_interval_dropped": _intervals_dropped,
		"population_start": _window_population_start, "population_end": _population(),
		"population_samples": _window_population_rows.duplicate(), "stride_start": _window_stride_start, "stride_end": _strides()}

func _poll_server_windows(now: int) -> void:
	if _warmup_until == 0:
		var start_file := OS.get_environment("NOIKAR_PROFILE_START_FILE")
		if not start_file.is_empty() and FileAccess.file_exists(start_file):
			_warmup_until = now + _warmup_usec
		return
	if now < _warmup_until:
		return
	if _window_start == 0:
		_begin_window(now)
	elif now - _window_start >= 30000000:
		var end_unix := unix_usec()
		printerr("[PROFILE_SERVER_WINDOW] " + JSON.stringify(finish_window(now, end_unix)))
		_window_index += 1
		if _window_index >= _window_count:
			_enabled = false
			return
		_begin_window(now)
		# Consecutive windows share precisely the same observed boundary.
		_window_unix_start = end_unix
