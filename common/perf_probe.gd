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
	npc_cost_recording_enabled = _should_enable_npc_costs(perf_env, is_headless, OS.get_environment(NPC_COST_ENV))
	_reset_npc_cost_accumulators()
	if not _should_enable_probe(perf_env, is_headless):
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
	var metrics := {
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frame_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"players": multiplayer.get_peers().size(),
		"entities": _count_entities(),
		"rollback_events": rollback.events,
		"rollback_avg_ticks": rollback.avg_ticks,
		"rollback_max_ticks": rollback.max_ticks,
		"netfox": _collect_netfox_monitors(),
	}
	if npc_cost_recording_enabled:
		metrics["npc_costs"] = _consume_npc_cost_summary()
	return metrics

func _count_entities() -> int:
	var count := 0
	for group in ENTITY_GROUPS:
		count += get_tree().get_nodes_in_group(group).size()
	return count

func _collect_netfox_monitors() -> Dictionary:
	var values := {}
	for metric_name in NETFOX_MONITORS:
		var monitor_name: StringName = NETFOX_MONITORS[metric_name]
		if Performance.has_custom_monitor(monitor_name):
			values[metric_name] = Performance.get_custom_monitor(monitor_name)
	return values

func _format_perf_line(metrics: Dictionary) -> String:
	var netfox: Dictionary = metrics.get("netfox", {})
	var parts := [
		"[PERF]",
		"fps=%.1f" % metrics.get("fps", 0.0),
		"frame_ms=%.2f" % metrics.get("frame_ms", 0.0),
		"physics_ms=%.2f" % metrics.get("physics_ms", 0.0),
		"players=%d" % metrics.get("players", 0),
		"entities=%d" % metrics.get("entities", 0),
		"rollback_events=%d" % metrics.get("rollback_events", 0),
		"rollback_avg_ticks=%.2f" % metrics.get("rollback_avg_ticks", 0.0),
		"rollback_max_ticks=%d" % metrics.get("rollback_max_ticks", 0),
	]

	for metric_name in NETFOX_MONITORS:
		if netfox.has(metric_name):
			parts.append("%s=%s" % [metric_name, _format_number(netfox[metric_name])])

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
