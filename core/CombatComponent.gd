# res://core/CombatComponent.gd
class_name CombatComponent
extends Node

## Handles authoritative hit detection using ShapeCast3D.
## Follows the "Noikar Rule": ShapeCast for volume-based combat.

@export var damage: int = 15
@export var fire_rate: float = 0.3

@onready var entity: BaseEntity = get_parent()
@onready var logic: Node = get_parent().get_node("LogicComponent")
@onready var shapecast: ShapeCast3D = get_parent().get_node("ShapeCast3D")

var _last_fire_time: float = 0.0

func _ready() -> void:
	if not shapecast:
		push_error("CombatComponent: ShapeCast3D not found!")

func _rollback_tick(_delta: float, _tick: int, is_fresh: bool) -> void:
	if not is_fresh:
		return
		
	if logic and logic.get("is_shooting"):
		_try_attack()

func _try_attack() -> void:
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - _last_fire_time >= fire_rate:
		_last_fire_time = current_time
		_perform_attack()

func _perform_attack() -> void:
	# Visual feedback for everyone
	_show_attack_effects.rpc()
	
	# Authoritative Hit Detection (Server Only)
	if multiplayer.is_server():
		# Force update the shapecast to ensure accuracy during rollback
		shapecast.force_shapecast_update()
		
		if shapecast.is_colliding():
			# ShapeCast can hit multiple objects, we process all of them
			var hit_count = shapecast.get_collision_count()
			for i in range(hit_count):
				var collider = shapecast.get_collider(i)
				_handle_hit(collider)

func _handle_hit(collider: Node) -> void:
	# Check for Hurtbox in the collider or its children
	var hurtbox = collider as HurtboxComponent
	if not hurtbox and collider.has_node("HurtboxComponent"):
		hurtbox = collider.get_node("HurtboxComponent")
		
	if hurtbox:
		print("[Combat] ShapeCast hit: ", collider.name)
		hurtbox.receive_hit_data(damage, entity)

@rpc("call_local", "unreliable")
func _show_attack_effects() -> void:
	if entity.has_node("VisualComponent"):
		entity.get_node("VisualComponent").play_shoot_effect() # Reuse current VFX
