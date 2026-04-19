@tool
# res://core/LogicComponent.gd
class_name LogicComponent
extends Node

@export var entity: CharacterBody3D
@export var max_speed: float = 10.0
@export var acceleration: float = 15.0

@export var current_velocity: Vector3 = Vector3.ZERO
@export var input_axis: Vector2 = Vector2.ZERO
@export var is_shooting: bool = false
@export var summon_type: int = -1 # 0: Attack, 1: Tank, 2: Heal
@export var look_yaw: float = 0.0

var camera_pivot: Node3D
var _server_state: Node
@export var mouse_sensitivity: float = 0.005

func _ready() -> void:
	if Engine.is_editor_hint(): return
	
	_setup_entity()
	var entity_name = entity.name if entity else &"Unknown"
	print("[DEBUG] LogicComponent initializing for entity: %s" % entity_name)
	
	current_velocity = Vector3.ZERO
	if entity: 
		look_yaw = entity.rotation.y
		print("[DEBUG] LogicComponent %s: Initial rotation captured" % entity_name)
	
	camera_pivot = get_parent().get_node_or_null("CameraPivot")
	_server_state = get_parent().get_node_or_null("ServerState")
	
	if not _server_state:
		print("[WARNING] LogicComponent %s: ServerState not found!" % entity_name)
	else:
		print("[DEBUG] LogicComponent %s: ServerState linked" % entity_name)

func _input(event: InputEvent) -> void:
	if not _is_local_authority(): return
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		look_yaw -= event.relative.x * mouse_sensitivity
		if camera_pivot:
			var new_rot_x = camera_pivot.rotation.x - event.relative.y * mouse_sensitivity
			camera_pivot.rotation.x = clamp(new_rot_x, deg_to_rad(-60), deg_to_rad(30))

func _setup_entity() -> void:
	entity = get_parent() as CharacterBody3D

func _rollback_tick(delta: float, _tick: int, _is_fresh: bool) -> void:
	if not entity or entity.get("sync_is_dead"): 
		input_axis = Vector2.ZERO
		return
		
	var is_human = entity.name.is_valid_int()
	
	if is_human and _is_local_authority():
		input_axis = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		is_shooting = Input.is_action_pressed("shoot")
		
		# Summon Inputs
		if Input.is_key_pressed(KEY_1): summon_type = 0
		elif Input.is_key_pressed(KEY_2): summon_type = 1
		elif Input.is_key_pressed(KEY_3): summon_type = 2
		else: summon_type = -1
	elif not is_human and multiplayer.is_server():
		# AI CONTROL: Only on server for non-humans
		var ai = entity.get_node_or_null("AIComponent")
		if ai and ai.has_method("tick"):
			ai.tick(delta)

	# Authoritative Summoning (Server only, for humans)
	if is_human and multiplayer.is_server() and summon_type != -1:
		var match_manager = get_tree().root.find_child("Main", true, false)
		if match_manager and match_manager.has_method("request_spawn_totem"):
			match_manager.request_spawn_totem(entity, summon_type)
			summon_type = -1 # Consume input
	
	_apply_movement(delta)

func _apply_movement(delta: float) -> void:
	if not entity: return
	
	# 0. Authoritative Knockback State from ServerState
	if _server_state and _server_state.knockback_remaining_time > 0:
		current_velocity = _server_state.knockback_velocity
		
		# Server manages the timer
		if multiplayer.is_server():
			_server_state.knockback_remaining_time -= delta
			if _server_state.knockback_remaining_time <= 0:
				_server_state.knockback_velocity = Vector3.ZERO
	else:
		# Normal Input-based movement
		# Rotation
		entity.rotation.y = look_yaw
		
		# Direction
		var move_dir = Vector3.ZERO
		if input_axis.length() > 0:
			var forward = -entity.global_transform.basis.z
			var right = entity.global_transform.basis.x
			move_dir = (forward * -input_axis.y + right * input_axis.x).normalized()
		
		# Basic Velocity
		var target_vel = move_dir * max_speed
		current_velocity = current_velocity.move_toward(target_vel, acceleration * 10.0 * delta)
	
	# APPLY MOVEMENT (Refactored to move_and_slide)
	entity.velocity = current_velocity
	entity.move_and_slide()
	
	# CRITICAL FOR NETFOX: Force transform update so rollback captures the new position
	entity.force_update_transform()
	
	# Sync back velocity for next frame (handles collisions stopping movement)
	current_velocity = entity.velocity

# Removed _clear_server_impulse as it's no longer needed with time-based state

func _is_local_authority() -> bool:
	if not entity: return false
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	return multiplayer.get_unique_id() == owner_id
