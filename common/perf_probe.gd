# res://common/perf_probe.gd
## Lightweight server performance probe. Activated only when the environment
## variable NOIKAR_PERF_PROBE=1 is set and the process is headless, so client and
## production runs carry zero cost. Emits one aggregate line per interval; CPU/RSS
## and bandwidth require external process or ENet-specific sampling and are
## reported explicitly as unavailable instead of fabricated.
extends Node

const INTERVAL_SEC := 5.0
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

func _ready() -> void:
	if not _should_enable_probe(OS.get_environment("NOIKAR_PERF_PROBE"), GameManager._is_headless_environment()):
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
	return {
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

	parts.append("bandwidth_rx_kbps=na")
	parts.append("bandwidth_tx_kbps=na")
	parts.append("cpu=external")
	parts.append("rss=external")
	return " ".join(parts)

func _format_number(value: Variant) -> String:
	if value is float:
		return "%.2f" % value
	return str(value)
