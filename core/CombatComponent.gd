# res://core/CombatComponent.gd
class_name CombatComponent
extends Node

## Handles authoritative hit detection using ShapeCast3D.
## Follows the "Noikar Rule": ShapeCast for volume-based combat.

signal attack_started

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

enum AttackState { READY, STARTUP, ACTIVE, RECOVERY }
var current_attack_state: AttackState = AttackState.READY
var _last_emitted_state: AttackState = AttackState.READY

var _state_timer: float = 0.0

@export var startup_time: float = 0.1  # Timing para que baje la espada
@export var active_time: float = 0.3   # Tiempo que dura la esfera visible
@export var recovery_time: float = 0.3 # Cooldown

func _rollback_tick(delta: float, _tick: int, is_fresh: bool) -> void:
	# Detect state change for visuals ONLY on fresh ticks
	if is_fresh:
		if current_attack_state == AttackState.STARTUP and _last_emitted_state != AttackState.STARTUP:
			attack_started.emit()
		_last_emitted_state = current_attack_state

	if not is_fresh:
		return
	
	_update_attack_state(delta)
	
	# ONLY the authority (owner) or the server triggers the attack start
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	var is_owner = (multiplayer.get_unique_id() == owner_id)
	
	if (multiplayer.is_server() or is_owner) and current_attack_state == AttackState.READY:
		if logic and logic.get("is_shooting"):
			_start_attack()

func _update_attack_state(delta: float) -> void:
	if current_attack_state == AttackState.READY:
		return
		
	_state_timer -= delta
	
	if _state_timer <= 0:
		match current_attack_state:
			AttackState.STARTUP:
				current_attack_state = AttackState.ACTIVE
				_state_timer = active_time
				_on_attack_active()
			AttackState.ACTIVE:
				current_attack_state = AttackState.RECOVERY
				_state_timer = recovery_time
			AttackState.RECOVERY:
				current_attack_state = AttackState.READY

func _start_attack() -> void:
	current_attack_state = AttackState.STARTUP
	_state_timer = startup_time

func _on_attack_active() -> void:
	# Damage is server-authoritative
	if multiplayer.is_server():
		# Sync shapecast position with the attack point
		var forward = -entity.global_transform.basis.z
		var attack_pos = entity.global_position + (forward * 3.0) + Vector3(0, 1.2, 0)
		
		if entity.character_actor:
			var socket = entity.character_actor.get_socket("WeaponMain")
			if socket:
				attack_pos = socket.global_position + (forward)
		
		shapecast.global_position = attack_pos
		shapecast.force_shapecast_update()
		
		if shapecast.is_colliding():
			var hit_count = shapecast.get_collision_count()
			print("[Combat] HIT! Count: ", hit_count)
			for i in range(hit_count):
				var collider = shapecast.get_collider(i)
				_handle_hit(collider)

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
