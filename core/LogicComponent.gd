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
@export var look_yaw: float = 0.0

@onready var camera_pivot: Node3D = get_parent().get_node_or_null("CameraPivot")
@onready var _server_state = get_parent().get_node_or_null("ServerState")
@export var mouse_sensitivity: float = 0.005

func _ready() -> void:
	if Engine.is_editor_hint(): return
	_setup_entity()
	current_velocity = Vector3.ZERO
	if entity: look_yaw = entity.rotation.y

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
		
	if _is_local_authority():
		input_axis = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		is_shooting = Input.is_action_pressed("shoot")
		if is_shooting:
			print("[Logic] Shooting input detected on Client for: ", entity.name)
	
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
	
	# Apply movement using the character body's native move_and_collide for stability
	entity.move_and_collide(current_velocity * delta)

# Removed _clear_server_impulse as it's no longer needed with time-based state

func _is_local_authority() -> bool:
	if not entity: return false
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	return multiplayer.get_unique_id() == owner_id
