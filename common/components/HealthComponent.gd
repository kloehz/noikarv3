# res://common/components/HealthComponent.gd
class_name HealthComponent
extends Node3D

## Health management component for entities.
## Provides signal-based health changes for UI and networking.

signal health_changed(current: int, maximum: int)
signal damaged(amount: int, source: Node)
signal healed(amount: int)
signal died

@export var max_health: int = 100
@export var invincibility_time: float = 0.0

var current_health: int:
	set(value):
		var old := current_health
		current_health = clampi(value, 0, max_health)
		if current_health != old:
			health_changed.emit(current_health, max_health)

var _invincible: bool = false
var _health_label: Label3D

func _ready() -> void:
	current_health = max_health
	_setup_debug_label()

func _setup_debug_label() -> void:
	# Create a debug label for visual health representation in editor
	_health_label = Label3D.new()
	_health_label.visible = true
	_health_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_health_label.no_depth_test = true
	_health_label.position = Vector3(0, 2.5, 0) # Position above
	add_child(_health_label)
	_update_debug_label()

## Take damage from a source. Returns actual damage dealt.
func take_damage(amount: int, source: Node = null) -> int:
	if _invincible or current_health <= 0:
		return 0
	
	var actual := mini(amount, current_health)
	current_health -= actual
	damaged.emit(actual, source)
	_update_debug_label()
	
	print("[Health] %s took %d damage. Health: %d/%d" % [get_parent().name, actual, current_health, max_health])
	
	if current_health <= 0:
		died.emit()
	elif invincibility_time > 0:
		_start_invincibility()
	
	return actual

## Heal the entity. Returns actual healing done.
func heal(amount: int) -> int:
	if current_health <= 0:
		return 0
	
	var actual := mini(amount, max_health - current_health)
	current_health += actual
	if actual > 0:
		healed.emit(actual)
		_update_debug_label()
	return actual

## Reset health to max.
func reset_health() -> void:
	current_health = max_health

## Start invincibility period.
func _start_invincibility() -> void:
	_invincible = true
	await get_tree().create_timer(invincibility_time).timeout
	_invincible = false

## Update debug label text.
func _update_debug_label() -> void:
	if _health_label:
		_health_label.text = "%d/%d" % [current_health, max_health]
