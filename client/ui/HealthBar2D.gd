extends Control

@onready var health_bar: ProgressBar = $HealthBar
@onready var catchup_bar: ProgressBar = $CatchupBar
@onready var hp_text: Label = $HPText

var _health_style: StyleBoxFlat
var _catchup_style: StyleBoxFlat
var _is_first_update: bool = true
var _flash_overlay: ColorRect
## Color used to lerp the fill so the transition between green/yellow/red is smooth.
var _current_color: Color = Color(0.2, 0.8, 0.2)
var _target_color: Color = Color(0.2, 0.8, 0.2)

func _ready() -> void:
	_ensure_init()

func _ensure_init() -> void:
	if _health_style: return

	if not health_bar: health_bar = $HealthBar
	if not catchup_bar: catchup_bar = $CatchupBar
	if not hp_text: hp_text = $HPText

	# Create unique copies for this specific health bar
	_health_style = health_bar.get_theme_stylebox("fill").duplicate()
	_catchup_style = catchup_bar.get_theme_stylebox("fill").duplicate()

	# Rounded fill so the bar reads as polished instead of a flat rectangle.
	_health_style.corner_radius_top_left = 4
	_health_style.corner_radius_top_right = 4
	_health_style.corner_radius_bottom_right = 4
	_health_style.corner_radius_bottom_left = 4
	_catchup_style.corner_radius_top_left = 4
	_catchup_style.corner_radius_top_right = 4
	_catchup_style.corner_radius_bottom_right = 4
	_catchup_style.corner_radius_bottom_left = 4

	# Apply unique overrides
	health_bar.add_theme_stylebox_override("fill", _health_style)
	catchup_bar.add_theme_stylebox_override("fill", _catchup_style)

	# PURE WHITE for the catchup (damage shadow)
	_catchup_style.bg_color = Color(1.0, 1.0, 1.0, 0.85)
	_catchup_style.border_width_left = 0
	_catchup_style.border_width_top = 0
	_catchup_style.border_width_right = 0
	_catchup_style.border_width_bottom = 0

	# Flash overlay covers the whole bar with a white tint that fades out
	# after each damage tick, giving the bar a visible "hit" reaction.
	_flash_overlay = ColorRect.new()
	_flash_overlay.name = "FlashOverlay"
	_flash_overlay.color = Color(1, 1, 1, 0)
	_flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_flash_overlay)

func update_health(current: int, maximum: int) -> void:
	_ensure_init()
	if not health_bar: return

	# Update text
	if hp_text:
		hp_text.text = "%d / %d" % [current, maximum]

	# Snap values instantly on the very first update to avoid "filling up" animation
	if _is_first_update:
		health_bar.max_value = maximum
		catchup_bar.max_value = maximum
		health_bar.value = current
		catchup_bar.value = current
		_is_first_update = false
		_current_color = _color_for_ratio(float(current) / float(maximum))
		_target_color = _current_color
		_update_color()
		return

	# Detect damage to trigger the catchup effect
	var is_damage = current < health_bar.value

	health_bar.max_value = maximum
	catchup_bar.max_value = maximum

	# Immediate update for the main bar
	health_bar.value = current

	# Smooth update for the "catchup" bar
	if is_damage:
		var tween = create_tween()
		tween.tween_property(catchup_bar, "value", current, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		_play_damage_flash()
	else:
		# Healing: just move catchup bar instantly
		catchup_bar.value = current

	_target_color = _color_for_ratio(float(current) / float(maximum))
	_update_color()

func _process(delta: float) -> void:
	# Smooth color transitions between health tiers (green -> yellow -> red)
	# instead of a hard step, and decay the damage flash.
	if _current_color != _target_color:
		_current_color = _current_color.lerp(_target_color, clampf(delta * 8.0, 0.0, 1.0))
		if _current_color.is_equal_approx(_target_color):
			_current_color = _target_color
		if _health_style:
			_health_style.bg_color = _current_color
	if _flash_overlay and _flash_overlay.color.a > 0.0:
		var a := _flash_overlay.color.a
		a = maxf(0.0, a - delta * 3.5)
		_flash_overlay.color = Color(1, 1, 1, a)

func _update_color() -> void:
	if _health_style:
		_health_style.bg_color = _current_color

func _play_damage_flash() -> void:
	if not _flash_overlay: return
	_flash_overlay.color = Color(1, 1, 1, 0.55)

func _color_for_ratio(ratio: float) -> Color:
	if ratio > 0.5:
		return Color(0.25, 0.85, 0.35) # Green
	elif ratio > 0.2:
		return Color(0.95, 0.75, 0.15) # Yellow
	else:
		return Color(0.9, 0.25, 0.25) # Red
