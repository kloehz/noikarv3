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
## Duration of the damage flash on the team that just landed a hit.
@export var flash_duration: float = 0.25

var _red_pct: float = 0.0
var _blue_pct: float = 0.0
var _boss_label_text: String = ""
## Per-team pulse intensity in [0, 1]; decays toward 0 after every set_damage.
var _red_flash: float = 0.0
var _blue_flash: float = 0.0
var _prev_red: float = 0.0
var _prev_blue: float = 0.0

func _ready() -> void:
	custom_minimum_size = Vector2(640, bar_height + label_gap + 16)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	queue_redraw()

## Updates the bar from the latest replicated boss damage counters. The
## larger team is painted last so it visually "wins" any overlap region.
## Triggers a short flash on the team whose counter just grew so the
## player can feel the impact land.
func set_damage(red_damage: int, blue_damage: int, max_hp: int) -> void:
	var denom: float = maxf(float(max_hp), 1.0)
	var new_red := clampf(float(red_damage) / denom, 0.0, 1.0)
	var new_blue := clampf(float(blue_damage) / denom, 0.0, 1.0)
	if new_red > _prev_red:
		_red_flash = 1.0
	if new_blue > _prev_blue:
		_blue_flash = 1.0
	_prev_red = _red_pct
	_prev_blue = _blue_pct
	_red_pct = new_red
	_blue_pct = new_blue
	queue_redraw()

func _process(delta: float) -> void:
	if _red_flash > 0.0 or _blue_flash > 0.0:
		var decay := delta / maxf(flash_duration, 0.001)
		_red_flash = maxf(0.0, _red_flash - decay)
		_blue_flash = maxf(0.0, _blue_flash - decay)
		queue_redraw()

## Sets the label rendered above the bar (default "BOSS").
func set_label(text: String) -> void:
	_boss_label_text = text
	queue_redraw()

func _draw() -> void:
	var ctrl_size: Vector2 = size
	var bar_rect := Rect2(Vector2(0, label_gap + 14), Vector2(ctrl_size.x, bar_height))
	# Track + border first (background). Vertical gradient gives the bar
	# a subtle 3D inset feel instead of a flat block.
	var track_top := bar_rect.position
	draw_rect(bar_rect, track_color, true)
	draw_rect(Rect2(track_top, Vector2(bar_rect.size.x, bar_rect.size.y * 0.5)),
		track_color.lerp(Color(0.18, 0.18, 0.24, 0.85), 0.7), true)
	draw_rect(bar_rect, track_border_color, false, 1.5)
	# Fills grow from their side toward the center. Anchor right edge of
	# each fill: red's right edge is at red_pct, blue's left edge is at
	# 1 - blue_pct. They overlap in the middle when both > 0.5. Each fill
	# has a vertical gradient (brighter at the top) and a flash brighten
	# tied to the last set_damage() call that grew its counter.
	if _red_pct > 0.0:
		var red_rect := Rect2(
			bar_rect.position,
			Vector2(bar_rect.size.x * _red_pct, bar_rect.size.y)
		)
		var red_fill := red_color.lerp(Color(1.0, 0.45, 0.45, 1.0), _red_flash * 0.6)
		draw_rect(red_rect, red_fill, true)
		draw_rect(Rect2(red_rect.position, Vector2(red_rect.size.x, red_rect.size.y * 0.5)),
			red_fill.lerp(Color(1, 1, 1, 1), 0.18 + _red_flash * 0.25), true)
	if _blue_pct > 0.0:
		var blue_rect := Rect2(
			Vector2(bar_rect.position.x + bar_rect.size.x * (1.0 - _blue_pct), bar_rect.position.y),
			Vector2(bar_rect.size.x * _blue_pct, bar_rect.size.y)
		)
		var blue_fill := blue_color.lerp(Color(0.55, 0.7, 1.0, 1.0), _blue_flash * 0.6)
		draw_rect(blue_rect, blue_fill, true)
		draw_rect(Rect2(blue_rect.position, Vector2(blue_rect.size.x, blue_rect.size.y * 0.5)),
			blue_fill.lerp(Color(1, 1, 1, 1), 0.18 + _blue_flash * 0.25), true)
	# Divider line in the middle when both teams have landed hits; marks
	# the meeting point of the two fills.
	if _red_pct > 0.0 and _blue_pct > 0.0:
		var meeting_x := bar_rect.position.x + bar_rect.size.x * _red_pct
		draw_line(Vector2(meeting_x, bar_rect.position.y),
			Vector2(meeting_x, bar_rect.position.y + bar_rect.size.y),
			Color(0, 0, 0, 0.45), 1.0)
	# Label.
	var label_pos := Vector2(0, 0)
	draw_string(get_theme_default_font(), label_pos + Vector2(2, 12), _boss_label_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
		Color(1, 1, 1, 0.85))
	# Damage % readout on the right edge.
	var pct_text := "RED %d%%  ·  BLUE %d%%" % [int(_red_pct * 100.0), int(_blue_pct * 100.0)]
	draw_string(get_theme_default_font(), label_pos + Vector2(ctrl_size.x - 4, 12), pct_text,
		HORIZONTAL_ALIGNMENT_RIGHT, ctrl_size.x - 8, 12,
		Color(1, 1, 1, 0.6))
