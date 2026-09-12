# res://common/perf_probe.gd
## Lightweight server performance probe. Activated only when the environment
## variable NOIKAR_PERF_PROBE=1 is set and the process is headless, so client and
## production runs carry zero cost. Emits one aggregate line per interval; CPU/RSS
## and bandwidth require external process or ENet-specific sampling and are
## reported explicitly as unavailable instead of fabricated.
extends Node

const INTERVAL_SEC := 5.0
const NPC_COST_ENV := "NOIKAR_PERF_PROBE_NPC_COST"
const NPC_COST_TIMERS := [&"ai", &"movement", &"movement_prepare", &"movement_slide", &"movement_flush", &"combat"]
const NPC_COST_COUNTERS := [&"target_scan", &"avoidance"]
const ENTITY_GROUPS := [&"players", &"pets", &"mobs", &"projectiles"]
const BENCHMARK_SCENARIOS := {
	"A": {"players": 0, "mobs": 0, "ai_decisions": true, "requires_client_probe": false},
	"B": {"players": 0, "mobs": 20, "ai_decisions": false, "requires_client_probe": false},
	"C": {"players": 0, "mobs": 20, "ai_decisions": true, "requires_client_probe": false},
	"D": {"players": 1, "mobs": 0, "ai_decisions": true, "requires_client_probe": true},
	"E": {"players": 1, "mobs": 20, "ai_decisions": true, "requires_client_probe": true},
	"F": {"players": 1, "mobs": 20, "ai_decisions": true, "requires_client_probe": true},
}
const NETFOX_MONITORS := {
	"network_loop_ms": &"netfox/Network loop duration (ms)",
	"rollback_loop_ms": &"netfox/Rollback loop duration (ms)",
	"network_ticks": &"netfox/Network ticks simulated",
	"rollback_ticks": &"netfox/Rollback ticks simulated",
	"rollback_tick_ms": &"netfox/Rollback tick duration (ms)",
	"rollback_nodes": &"netfox/Rollback nodes simulated",
	"rollback_nodes_per_tick": &"netfox/Rollback nodes simulated per tick (avg)",
	"full_state_props": &"netfox/Full state properties count",
	"sent_state_props": &"netfox/Sent state properties count",
	"sent_state_ratio": &"netfox/Sent state properties ratio",
}

var _timer := 0.0
var _rollback_ticks_in_loop := 0
var _rollback_events := 0
var _rollback_ticks_total := 0
var _rollback_ticks_max := 0
var _rollback_signals_connected := false
var npc_cost_recording_enabled := false
var _npc_costs := {}
var _npc_counters := {}

func _ready() -> void:
	var perf_env := OS.get_environment("NOIKAR_PERF_PROBE")
	var is_headless := GameManager._is_headless_environment()
	var benchmark_scenario := benchmark_scenario_from_args(OS.get_cmdline_user_args())
	npc_cost_recording_enabled = _should_enable_npc_costs(perf_env, is_headless, OS.get_environment(NPC_COST_ENV))
	_reset_npc_cost_accumulators()
	if _has_benchmark_arg(OS.get_cmdline_user_args()) and benchmark_scenario.is_empty():
		printerr("[BENCHMARK] invalid --benchmark selection; expected one of A,B,C,D,E,F")
	if not _should_enable_probe(perf_env, is_headless) and not _should_enable_benchmark(benchmark_scenario, is_headless):
		queue_free()
		return

	# PerfProbe is autoloaded before Netfox. Defer signal hookup until the full
	# autoload list exists, but keep reporting interval aggregation local.
	call_deferred("_connect_rollback_signals")

func _process(delta: float) -> void:
	_timer += delta
	if _timer < INTERVAL_SEC:
		return
	_timer = 0.0
	# stderr bypasses Godot's stdout block buffering on pipes, so journald shows
	# these immediately. Reporting is interval-based; no per-tick logging.
	printerr(_format_perf_line(_collect_metrics()))

func _should_enable_probe(env_value: String, is_headless: bool) -> bool:
	return env_value == "1" and is_headless

func _should_enable_benchmark(scenario: String, is_headless: bool) -> bool:
	return not scenario.is_empty() and is_headless

func benchmark_scenario_from_args(args: Array) -> String:
	for arg in args:
		var text := str(arg).strip_edges()
		if text.begins_with("--benchmark="):
			var selected := text.replace("--benchmark=", "").strip_edges().to_upper()
			return selected if BENCHMARK_SCENARIOS.has(selected) else ""
	return ""

func benchmark_config_for_scenario(scenario: String) -> Dictionary:
	return (BENCHMARK_SCENARIOS.get(scenario.to_upper(), {}) as Dictionary).duplicate()

func _has_benchmark_arg(args: Array) -> bool:
	for arg in args:
		if str(arg).strip_edges().begins_with("--benchmark="):
			return true
	return false

func _should_enable_npc_costs(perf_env_value: String, is_headless: bool, cost_env_value: String) -> bool:
	return _should_enable_probe(perf_env_value, is_headless) and cost_env_value == "1"

func _set_npc_cost_recording_for_tests(enabled: bool) -> void:
	npc_cost_recording_enabled = enabled
	_reset_npc_cost_accumulators()

func _reset_npc_cost_accumulators() -> void:
	_npc_costs.clear()
	for metric_name in NPC_COST_TIMERS:
		_npc_costs[metric_name] = {"total_usec": 0, "calls": 0, "max_usec": 0}
	_npc_counters.clear()
	for counter_name in NPC_COST_COUNTERS:
		_npc_counters[counter_name] = {"visits": 0}

func record_npc_cost(metric_name: StringName, elapsed_usec: int) -> void:
	if not npc_cost_recording_enabled or not _npc_costs.has(metric_name):
		return
	var bucket: Dictionary = _npc_costs[metric_name]
	bucket.total_usec += maxi(elapsed_usec, 0)
	bucket.calls += 1
	bucket.max_usec = maxi(bucket.max_usec, elapsed_usec)

func record_npc_counter(counter_name: StringName, count: int = 1) -> void:
	if not npc_cost_recording_enabled or not _npc_counters.has(counter_name):
		return
	var bucket: Dictionary = _npc_counters[counter_name]
	bucket.visits += maxi(count, 0)

func _consume_npc_cost_summary() -> Dictionary:
	var summary := {}
	for metric_name in NPC_COST_TIMERS:
		var bucket: Dictionary = _npc_costs.get(metric_name, {"total_usec": 0, "calls": 0, "max_usec": 0})
		summary[metric_name] = bucket.duplicate()
	for counter_name in NPC_COST_COUNTERS:
		var bucket: Dictionary = _npc_counters.get(counter_name, {"visits": 0})
		summary[counter_name] = bucket.duplicate()
	_reset_npc_cost_accumulators()
	return summary

func _connect_rollback_signals() -> void:
	if _rollback_signals_connected or not is_inside_tree() or not has_node("/root/NetworkRollback"):
		return
	var rollback := get_node("/root/NetworkRollback")
	if not rollback.before_loop.is_connected(_on_rollback_before_loop):
		rollback.before_loop.connect(_on_rollback_before_loop)
	if not rollback.after_process_tick.is_connected(_on_rollback_after_process_tick):
		rollback.after_process_tick.connect(_on_rollback_after_process_tick)
	if not rollback.after_loop.is_connected(_on_rollback_after_loop):
		rollback.after_loop.connect(_on_rollback_after_loop)
	_rollback_signals_connected = true

func _on_rollback_before_loop() -> void:
	_rollback_ticks_in_loop = 0

func _on_rollback_after_process_tick(_tick: int) -> void:
	_rollback_ticks_in_loop += 1

func _on_rollback_after_loop() -> void:
	_record_rollback_loop(_rollback_ticks_in_loop)

func _record_rollback_loop(resimulated_ticks: int) -> void:
	if resimulated_ticks <= 0:
		return
	_rollback_events += 1
	_rollback_ticks_total += resimulated_ticks
	_rollback_ticks_max = maxi(_rollback_ticks_max, resimulated_ticks)

func _consume_rollback_summary() -> Dictionary:
	var avg_ticks := 0.0
	if _rollback_events > 0:
		avg_ticks = float(_rollback_ticks_total) / float(_rollback_events)
	var summary := {
		"events": _rollback_events,
		"avg_ticks": avg_ticks,
		"max_ticks": _rollback_ticks_max,
	}
	_rollback_events = 0
	_rollback_ticks_total = 0
	_rollback_ticks_max = 0
	return summary

func _collect_metrics() -> Dictionary:
	var rollback := _consume_rollback_summary()
	var scenario := benchmark_scenario_from_args(OS.get_cmdline_user_args())
	var benchmark_config := benchmark_config_for_scenario(scenario)
	var entity_counts := _count_entities_by_group()
	var metrics := {
		"scenario": scenario,
		"uptime_sec": float(Time.get_ticks_msec()) / 1000.0,
		"configured_players": int(benchmark_config.get("players", 0)),
		"configured_mobs": int(benchmark_config.get("mobs", 0)),
		"live_players": entity_counts.get("players", multiplayer.get_peers().size()),
		"live_mobs": entity_counts.get("mobs", 0),
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frames": Engine.get_frames_drawn(),
		"frame_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"max_fps": Engine.max_fps,
		"players": multiplayer.get_peers().size(),
		"entities": _sum_entity_counts(entity_counts),
		"entity_counts": entity_counts,
		"rollback_events": rollback.events,
		"rollback_avg_ticks": rollback.avg_ticks,
		"rollback_max_ticks": rollback.max_ticks,
		"rollback_nodes_observable": _count_nodes_named("RollbackSynchronizer"),
		"snapshot_nodes_observable": _count_snapshot_sync_nodes(),
		"synchronized_entities_observable": _count_synchronized_entities(),
		"netfox": _collect_netfox_monitors(),
	}
	if not scenario.is_empty():
		metrics["npc_authoritative_stride_counts"] = _count_authoritative_npc_stride_counts()
	if npc_cost_recording_enabled:
		metrics["npc_costs"] = _consume_npc_cost_summary()
	return metrics

func _count_entities() -> int:
	return _sum_entity_counts(_count_entities_by_group())

func _count_entities_by_group() -> Dictionary:
	var counts := {}
	for group in ENTITY_GROUPS:
		counts[String(group)] = get_tree().get_nodes_in_group(group).size()
	return counts

func _sum_entity_counts(counts: Dictionary) -> int:
	var count := 0
	for value in counts.values():
		count += int(value)
	return count

func _count_nodes_named(child_name: String) -> int:
	var count := 0
	for group in ENTITY_GROUPS:
		for node in get_tree().get_nodes_in_group(group):
			if node.get_node_or_null(child_name) != null:
				count += 1
	return count

func _count_snapshot_sync_nodes() -> int:
	var count := 0
	for group in ENTITY_GROUPS:
		for node in get_tree().get_nodes_in_group(group):
			if node.get_node_or_null("StateSynchronizer") != null or node.get_node_or_null("ServerState") != null:
				count += 1
	return count

func _count_synchronized_entities() -> int:
	var count := 0
	for group in ENTITY_GROUPS:
		for node in get_tree().get_nodes_in_group(group):
			if node.get_node_or_null("RollbackSynchronizer") != null or node.get_node_or_null("StateSynchronizer") != null or node.get_node_or_null("ServerState") != null:
				count += 1
	return count

func _count_authoritative_npc_stride_counts() -> Dictionary:
	var counts := {}
	for mob in get_tree().get_nodes_in_group(&"mobs"):
		var sync := mob.get_node_or_null("ServerState/StateSynchronizer")
		if sync == null:
			_increment_count(counts, "missing")
			continue
		var stride := _authoritative_stride_for_sync(sync)
		if stride <= 0:
			_increment_count(counts, "unknown")
			continue
		_increment_count(counts, str(stride))
	return counts

func _authoritative_stride_for_sync(sync: Node) -> int:
	if sync.has_method("get_effective_snapshot_stride"):
		return maxi(1, int(sync.call("get_effective_snapshot_stride")))
	var configured_stride = sync.get("npc_snapshot_stride")
	if configured_stride != null:
		return maxi(1, int(configured_stride))
	if sync.has_meta("npc_snapshot_stride"):
		return maxi(1, int(sync.get_meta("npc_snapshot_stride")))
	var server_state := sync.get_parent()
	if server_state != null:
		var server_stride = server_state.get("npc_snapshot_stride")
		if server_stride != null:
			return maxi(1, int(server_stride))
		if server_state.has_meta("npc_snapshot_stride"):
			return maxi(1, int(server_state.get_meta("npc_snapshot_stride")))
	return 0

func _increment_count(counts: Dictionary, key: String) -> void:
	counts[key] = int(counts.get(key, 0)) + 1

func _collect_netfox_monitors() -> Dictionary:
	var values := {}
	for metric_name in NETFOX_MONITORS:
		var monitor_name: StringName = NETFOX_MONITORS[metric_name]
		if Performance.has_custom_monitor(monitor_name):
			values[metric_name] = Performance.get_custom_monitor(monitor_name)
	return values

func _format_perf_line(metrics: Dictionary) -> String:
	var netfox: Dictionary = metrics.get("netfox", {})
	var scenario := str(metrics.get("scenario", ""))
	var parts := []
	if scenario.is_empty():
		parts.append("[PERF]")
	else:
		parts.append("[BENCHMARK]")
		parts.append("scenario=%s" % scenario)
		parts.append("uptime_sec=%.1f" % metrics.get("uptime_sec", 0.0))
		parts.append("configured_players=%d" % metrics.get("configured_players", 0))
		parts.append("configured_mobs=%d" % metrics.get("configured_mobs", 0))
		parts.append("live_players=%d" % metrics.get("live_players", 0))
		parts.append("live_mobs=%d" % metrics.get("live_mobs", 0))
	parts.append("fps=%.1f" % metrics.get("fps", 0.0))
	parts.append("frames=%d" % metrics.get("frames", 0))
	parts.append("frame_ms=%.2f" % metrics.get("frame_ms", 0.0))
	parts.append("physics_ms=%.2f" % metrics.get("physics_ms", 0.0))
	parts.append("physics_ticks_per_second=%d" % metrics.get("physics_ticks_per_second", 0))
	parts.append("max_fps=%d" % metrics.get("max_fps", 0))
	parts.append("players=%d" % metrics.get("players", 0))
	parts.append("entities=%d" % metrics.get("entities", 0))
	parts.append("rollback_events=%d" % metrics.get("rollback_events", 0))
	parts.append("rollback_avg_ticks=%.2f" % metrics.get("rollback_avg_ticks", 0.0))
	parts.append("rollback_max_ticks=%d" % metrics.get("rollback_max_ticks", 0))
	parts.append("rollback_nodes_observable=%d" % metrics.get("rollback_nodes_observable", 0))
	parts.append("snapshot_nodes_observable=%d" % metrics.get("snapshot_nodes_observable", 0))
	parts.append("synchronized_entities_observable=%d" % metrics.get("synchronized_entities_observable", 0))

	for metric_name in NETFOX_MONITORS:
		if netfox.has(metric_name):
			parts.append("%s=%s" % [metric_name, _format_number(netfox[metric_name])])

	if metrics.has("npc_authoritative_stride_counts"):
		parts.append("npc_authoritative_stride_counts=%s" % _format_int_count_dict(metrics.npc_authoritative_stride_counts))

	if metrics.has("npc_costs"):
		_append_npc_cost_parts(parts, metrics.npc_costs)

	parts.append("bandwidth_rx_kbps=na")
	parts.append("bandwidth_tx_kbps=na")
	parts.append("cpu=external")
	parts.append("rss=external")
	return " ".join(parts)

func _append_npc_cost_parts(parts: Array, npc_costs: Dictionary) -> void:
	# Inclusive timers contain their nested child timings. Child movement timers
	# measure instrumentation spans, not independent full CPU attribution.
	# Enable at runtime with NOIKAR_PERF_PROBE=1 NOIKAR_PERF_PROBE_NPC_COST=1.
	_append_npc_timer_parts(parts, "npc_ai_inclusive", npc_costs.get("ai", {}))
	_append_npc_timer_parts(parts, "npc_movement_inclusive", npc_costs.get("movement", {}))
	_append_npc_timer_parts(parts, "npc_movement_prepare_child", npc_costs.get("movement_prepare", {}))
	_append_npc_timer_parts(parts, "npc_movement_slide_child", npc_costs.get("movement_slide", {}))
	_append_npc_timer_parts(parts, "npc_movement_flush_child", npc_costs.get("movement_flush", {}))
	_append_npc_timer_parts(parts, "npc_combat", npc_costs.get("combat", {}))
	parts.append("npc_target_scan_visits=%d" % npc_costs.get("target_scan", {}).get("visits", 0))
	parts.append("npc_avoidance_visits=%d" % npc_costs.get("avoidance", {}).get("visits", 0))

func _append_npc_timer_parts(parts: Array, prefix: String, bucket: Dictionary) -> void:
	parts.append("%s_total_usec=%d" % [prefix, bucket.get("total_usec", 0)])
	parts.append("%s_calls=%d" % [prefix, bucket.get("calls", 0)])
	parts.append("%s_max_usec=%d" % [prefix, bucket.get("max_usec", 0)])

func _format_number(value: Variant) -> String:
	if value is float:
		return "%.2f" % value
	return str(value)

func _format_int_count_dict(counts: Dictionary) -> String:
	var numeric_keys := []
	var extra_keys := []
	for key in counts.keys():
		var key_text := str(key)
		if key_text.is_valid_int():
			numeric_keys.append(key_text)
		else:
			extra_keys.append(key_text)
	numeric_keys.sort_custom(func(a, b): return int(a) < int(b))
	extra_keys.sort()
	var entries := []
	for key in numeric_keys + extra_keys:
		entries.append("%s:%d" % [key, _int_count_value(counts, key)])
	return "{%s}" % ",".join(entries)

func _int_count_value(counts: Dictionary, key: String) -> int:
	if counts.has(key):
		return int(counts[key])
	if key.is_valid_int() and counts.has(int(key)):
		return int(counts[int(key)])
	return 0
