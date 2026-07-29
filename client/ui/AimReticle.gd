class_name AimReticle
extends Control

var charge_progress: float = 0.0:
	set(value):
		charge_progress = clamp(value, 0.0, 1.0)
		queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var center := size * 0.5
	var gap: float = lerpf(13.0, 5.0, charge_progress)
	var arm := 8.0
	var color := Color(0.6 + charge_progress * 0.4, 0.85 + charge_progress * 0.15, 1.0, 0.95)
	draw_line(center + Vector2(-gap - arm, 0), center + Vector2(-gap, 0), color, 2.0)
	draw_line(center + Vector2(gap, 0), center + Vector2(gap + arm, 0), color, 2.0)
	draw_line(center + Vector2(0, -gap - arm), center + Vector2(0, -gap), color, 2.0)
	draw_line(center + Vector2(0, gap), center + Vector2(0, gap + arm), color, 2.0)
	draw_arc(center, 4.0 + charge_progress * 5.0, 0.0, TAU, 24, color, 1.5)
