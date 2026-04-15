# res://core/CombatComponent.gd
class_name CombatComponent
extends Node

## Handles authoritative hit detection using ShapeCast3D.
## Follows the "Noikar Rule": ShapeCast for volume-based combat.

@export var damage: int = 15
@export var fire_rate: float = 0.3
@export var knockback_force: float = 12.0

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
	
	# ONLY the authority (owner) or the server triggers the attack logic
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	var is_owner = (multiplayer.get_unique_id() == owner_id)
	
	if multiplayer.is_server() or is_owner:
		if logic and logic.get("is_shooting"):
			_try_attack()

func _try_attack() -> void:
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - _last_fire_time >= fire_rate:
		_last_fire_time = current_time
		_perform_attack()

func _perform_attack() -> void:
	# Damage is server-authoritative
	if multiplayer.is_server():
		# Visual feedback for everyone else
		_show_attack_effects.rpc()
		
		# Force update the shapecast
		shapecast.force_shapecast_update()
		
		if shapecast.is_colliding():
			var hit_count = shapecast.get_collision_count()
			for i in range(hit_count):
				var collider = shapecast.get_collider(i)
				_handle_hit(collider)
	
	# Local visual feedback for the attacking player (Prediction)
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	if not multiplayer.is_server() and multiplayer.get_unique_id() == owner_id:
		_show_attack_effects()

func _handle_hit(collider: Node) -> void:
	print("[Combat] Server hit collider: ", collider.name)
	
	# Check for Hurtbox in the collider or its children
	var hurtbox = collider as HurtboxComponent
	if not hurtbox and collider.has_node("HurtboxComponent"):
		hurtbox = collider.get_node("HurtboxComponent")
		
	if hurtbox:
		# PROTECTION: Don't hit yourself!
		if hurtbox.get_parent() == entity:
			return
			
		var target = hurtbox.get_parent()
		print("[Combat] Valid Hurtbox found on: ", target.name)
		
		# APPLY DAMAGE
		hurtbox.receive_hit_data(damage, entity)
		
		# APPLY KNOCKBACK (Server only)
		if target.has_node("ServerState"):
			var target_state = target.get_node("ServerState")
			# Calculate direction from attacker to target
			var kb_dir = (target.global_position - entity.global_position).normalized()
			kb_dir.y = 0 # Keep it horizontal
			
			# Use state-based knockback for a longer, more consistent push
			target_state.knockback_velocity = kb_dir * knockback_force
			target_state.knockback_remaining_time = 0.25 # Lasts for 0.25 seconds
			print("[Combat] Server applied state-based knockback to: ", target.name)
	else:
		print("[Combat] No Hurtbox found on collider.")

@rpc("any_peer", "call_local", "unreliable")
func _show_attack_effects() -> void:
	if entity.has_node("VisualComponent"):
		entity.get_node("VisualComponent").play_shoot_effect()
