extends Control

@onready var health_bar: ProgressBar = $HealthBar
@onready var catchup_bar: ProgressBar = $CatchupBar

var _health_style: StyleBoxFlat
var _catchup_style: StyleBoxFlat

func _ready() -> void:
	_ensure_init()

func _ensure_init() -> void:
	if _health_style: return
	
	if not health_bar: health_bar = $HealthBar
	if not catchup_bar: catchup_bar = $CatchupBar
	
	# Ensure unique styleboxes for this instance to avoid color bleeding
	_health_style = health_bar.get_theme_stylebox("fill").duplicate()
	_catchup_style = catchup_bar.get_theme_stylebox("fill").duplicate()
	
	# Apply unique overrides
	health_bar.add_theme_stylebox_override("fill", _health_style)
	catchup_bar.add_theme_stylebox_override("fill", _catchup_style)
	
	# Set catchup bar to a "damage shadow" color (light red/white)
	_catchup_style.bg_color = Color(1.0, 1.0, 1.0, 0.7) # Semi-transparent white

func update_health(current: int, maximum: int) -> void:
	_ensure_init()
	if not health_bar: return
	
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
	
	# Dynamic Color based on percentage
	var ratio = float(current) / float(maximum)
	if _health_style:
		if ratio > 0.5:
			_health_style.bg_color = Color(0.2, 0.8, 0.2) # Green
		elif ratio > 0.2:
			_health_style.bg_color = Color(0.9, 0.7, 0.1) # Yellow
		else:
			_health_style.bg_color = Color(0.8, 0.2, 0.2) # Red
