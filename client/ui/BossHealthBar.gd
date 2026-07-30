# res://client/ui/BossHealthBar.gd
## Top-center shared boss health bar. Renders two opposing fills (RED from the
## left, BLUE from the right) inside a fixed-width track. Each team fills its
## half proportional to (damage / max_hp), so the visual proportion of each
## fill reflects that team's contribution. When both fills exceed 50 % the
## larger one paints on top of the smaller in the overlap region, giving
## the "dominant team wins the visual" feel requested by the user.
class_name BossHealthBar
extends Control

## Track + fill colors. Match TeamId.color() palette so the bar matches the
## rest of the UI.
@export var track_color: Color = Color(0.08, 0.08, 0.12, 0.85)
@export var track_border_color: Color = Color(0.3, 0.3, 0.4, 0.9)
@export var red_color: Color = Color(0.85, 0.2, 0.2, 0.95)
@export var blue_color: Color = Color(0.2, 0.45, 0.9, 0.95)
## How tall the bar is in pixels (the width is fixed via custom_minimum_size).
@export var bar_height: float = 22.0
## Spacing between the bar and its label.
@export var label_gap: float = 4.0

var _red_pct: float = 0.0
var _blue_pct: float = 0.0
var _boss_label_text: String = ""

func _ready() -> void:
	custom_minimum_size = Vector2(640, bar_height + label_gap + 16)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

## Updates the bar from the latest replicated boss damage counters. The
## larger team is painted last so it visually "wins" any overlap region.
func set_damage(red_damage: int, blue_damage: int, max_hp: int) -> void:
	var denom: float = maxf(float(max_hp), 1.0)
	_red_pct = clampf(float(red_damage) / denom, 0.0, 1.0)
	_blue_pct = clampf(float(blue_damage) / denom, 0.0, 1.0)
	queue_redraw()

## Sets the label rendered above the bar (default "BOSS").
func set_label(text: String) -> void:
	_boss_label_text = text
	queue_redraw()

func _draw() -> void:
	var size: Vector2 = get_size()
	var bar_rect := Rect2(Vector2(0, label_gap + 14), Vector2(size.x, bar_height))
	# Track + border first (background).
	draw_rect(bar_rect, track_color, true)
	draw_rect(bar_rect, track_border_color, false, 1.5)
	# Fills grow from their side toward the center. Anchor right edge of
	# each fill: red's right edge is at red_pct, blue's left edge is at
	# 1 - blue_pct. They overlap in the middle when both > 0.5.
	if _red_pct > 0.0:
		var red_rect := Rect2(
			bar_rect.position,
			Vector2(bar_rect.size.x * _red_pct, bar_rect.size.y)
		)
		draw_rect(red_rect, red_color, true)
	if _blue_pct > 0.0:
		var blue_rect := Rect2(
			Vector2(bar_rect.position.x + bar_rect.size.x * (1.0 - _blue_pct), bar_rect.position.y),
			Vector2(bar_rect.size.x * _blue_pct, bar_rect.size.y)
		)
		draw_rect(blue_rect, blue_color, true)
	# Label.
	var label_pos := Vector2(0, 0)
	draw_string(get_theme_default_font(), label_pos + Vector2(2, 12), _boss_label_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(1, 1, 1, 0.85))
	# Damage % readout on the right edge.
	var pct_text := "RED %d%%  ·  BLUE %d%%" % [int(_red_pct * 100.0), int(_blue_pct * 100.0)]
	draw_string(get_theme_default_font(), label_pos + Vector2(size.x - 4, 12), pct_text,
		HORIZONTAL_ALIGNMENT_RIGHT, size.x - 8, 12,
		Color(1, 1, 1, 0.6))
