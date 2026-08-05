# res://common/perf_probe.gd
## Lightweight server performance probe. Activated only when the environment
## variable NOIKAR_PERF_PROBE=1 is set, so production runs carry zero cost.
## Writes a line to STDERR (unbuffered, visible in journald) every few
## seconds with frame vs physics time and entity counts — the data needed
## to decide where the next optimization goes.
extends Node

const INTERVAL_SEC := 5.0

var _timer := 0.0

func _ready() -> void:
	var is_enabled := OS.get_environment("NOIKAR_PERF_PROBE") == "1"
	if not is_enabled or not GameManager._is_headless_environment():
		queue_free()

func _process(delta: float) -> void:
	_timer += delta
	if _timer < INTERVAL_SEC:
		return
	_timer = 0.0
	var frame_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var bodies := 0
	for group in [&"players", &"pets", &"mobs", &"projectiles"]:
		bodies += get_tree().get_nodes_in_group(group).size()
	# stderr bypasses Godot's stdout block buffering on pipes, so journald
	# shows these immediately.
	printerr("[PERF] fps=%.1f frame_ms=%.2f physics_ms=%.2f entities=%d" % [fps, frame_ms, physics_ms, bodies])
