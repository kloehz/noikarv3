class_name PetRoleIcon
extends Control

const ROLE_COLORS := {
	"ATTACK": Color("ef6b5b"),
	"TANK": Color("5d9fe8"),
	"HEAL": Color("62d39b"),
}

@export var pet_type := "ATTACK":
	set(value):
		pet_type = value
		queue_redraw()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

static func color_for(role: String) -> Color:
	return ROLE_COLORS.get(role, Color.WHITE) as Color

func _draw() -> void:
	var center := size * 0.5
	var icon_size := minf(size.x, size.y) * 0.72
	var color := color_for(pet_type)
	match pet_type:
		"TANK":
			_draw_shield(center, icon_size, color)
		"HEAL":
			_draw_heart(center, icon_size, color)
		_:
			_draw_sword(center, icon_size, color)

func _draw_sword(center: Vector2, icon_size: float, color: Color) -> void:
	var half := icon_size * 0.5
	var blade := PackedVector2Array([
		center + Vector2(-half * 0.14, -half),
		center + Vector2(half * 0.18, -half * 0.67),
		center + Vector2(half * 0.05, half * 0.12),
		center + Vector2(-half * 0.18, half * 0.32),
	])
	draw_colored_polygon(blade, color)
	draw_line(center + Vector2(-half * 0.44, half * 0.12), center + Vector2(half * 0.3, half * 0.52), color, maxf(3.0, icon_size * 0.13), true)
	draw_line(center + Vector2(-half * 0.19, half * 0.42), center + Vector2(half * 0.25, half * 0.75), color, maxf(3.0, icon_size * 0.13), true)

func _draw_shield(center: Vector2, icon_size: float, color: Color) -> void:
	var half := icon_size * 0.5
	var shield := PackedVector2Array([
		center + Vector2(-half * 0.76, -half * 0.66),
		center + Vector2(half * 0.76, -half * 0.66),
		center + Vector2(half * 0.64, half * 0.21),
		center + Vector2(0, half * 0.86),
		center + Vector2(-half * 0.64, half * 0.21),
	])
	draw_colored_polygon(shield, color)
	draw_polyline(PackedVector2Array([shield[0], shield[1], shield[2], shield[3], shield[4], shield[0]]), Color.WHITE.darkened(0.45), maxf(2.0, icon_size * 0.06), true)

func _draw_heart(center: Vector2, icon_size: float, color: Color) -> void:
	var half := icon_size * 0.5
	var radius := half * 0.48
	draw_circle(center + Vector2(-radius * 0.82, -radius * 0.28), radius, color)
	draw_circle(center + Vector2(radius * 0.82, -radius * 0.28), radius, color)
	draw_colored_polygon(PackedVector2Array([
		center + Vector2(-half * 0.94, -half * 0.16),
		center + Vector2(half * 0.94, -half * 0.16),
		center + Vector2(0, half * 0.9),
	]), color)
