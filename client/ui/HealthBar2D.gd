extends Control

@onready var health_bar: ProgressBar = $HealthBar
@onready var catchup_bar: ProgressBar = $CatchupBar
@onready var hp_text: Label = $HPText

var _health_style: StyleBoxFlat
var _catchup_style: StyleBoxFlat
var _is_first_update: bool = true

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

	# Apply unique overrides
	health_bar.add_theme_stylebox_override("fill", _health_style)
	catchup_bar.add_theme_stylebox_override("fill", _catchup_style)

	# PURE WHITE for the catchup (damage shadow)
	_catchup_style.bg_color = Color(1.0, 1.0, 1.0, 1.0)
	_catchup_style.border_width_left = 0
	_catchup_style.border_width_top = 0
	_catchup_style.border_width_right = 0
	_catchup_style.border_width_bottom = 0

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
		_update_color(current, maximum)
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
	else:
		# Healing: just move catchup bar instantly
		catchup_bar.value = current

	_update_color(current, maximum)

func _update_color(current: int, maximum: int) -> void:
	var ratio = float(current) / float(maximum)
	if _health_style:
		if ratio > 0.5:
			_health_style.bg_color = Color(0.2, 0.8, 0.2) # Green
		elif ratio > 0.2:
			_health_style.bg_color = Color(0.9, 0.7, 0.1) # Yellow
		else:
			_health_style.bg_color = Color(0.8, 0.2, 0.2) # Red
