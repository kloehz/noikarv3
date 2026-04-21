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
@export var is_dashing: bool = false
@export var summon_type: int = -1 # 0: Attack, 1: Tank, 2: Heal

# Dash settings
const DASH_SPEED_MULT: float = 3.0
const DASH_DURATION: float = 0.2
const DASH_COOLDOWN_TIME: float = 1.2

var dash_timer: float = 0.0
var dash_cooldown: float = 0.0
var dash_direction: Vector3 = Vector3.ZERO
@export var look_yaw: float = 0.0

# Preview system variables
var is_previewing: bool = false
var preview_type: int = -1
var preview_cancelled: bool = false

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
			
	# Camera movement (Continuous when mouse is captured)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look_yaw -= event.relative.x * mouse_sensitivity
		if camera_pivot:
			var new_rot_x = camera_pivot.rotation.x - event.relative.y * mouse_sensitivity
			camera_pivot.rotation.x = clamp(new_rot_x, deg_to_rad(-60), deg_to_rad(30))

	# Hold-to-Preview Logic
	_handle_preview_input(event)

func _handle_preview_input(event: InputEvent) -> void:
	# Right click cancels preview
	if is_previewing and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			preview_cancelled = true
			is_previewing = false
			preview_type = -1
			print("[Logic] Summon cancelled by right-click")

	# Detect keys 1, 2, 3
	var keys = {
		KEY_1: 0,
		KEY_2: 1,
		KEY_3: 2
	}
	
	for key in keys:
		if event is InputEventKey and event.keycode == key:
			if event.pressed and not is_previewing:
				is_previewing = true
				preview_type = keys[key]
				preview_cancelled = false
				print("[Logic] Previewing summon type: ", preview_type)
			elif not event.pressed and is_previewing and preview_type == keys[key]:
				# Key released, confirm summon if not cancelled
				if not preview_cancelled:
					print("[Logic] Intentando invocar tipo %d. Buscando MatchManager..." % preview_type)
					
					# 1. Try Group
					var mm = get_tree().get_first_node_in_group(&"match_manager")
					# 2. Try Absolute Path
					if not mm: mm = get_node_or_null("/root/Main")
					# 3. Try Hierarchy
					if not mm: mm = get_parent().get_parent().get_parent()
					
					if mm and mm.has_method("spawn_totem_rpc"):
						print("[Logic] MatchManager encontrado. Enviando RPC...")
						mm.spawn_totem_rpc.rpc_id(1, preview_type)
					else:
						print("[Logic ERROR] ¡No se pudo encontrar el MatchManager para invocar!")
				is_previewing = false
				preview_type = -1

func _setup_entity() -> void:
	entity = get_parent() as CharacterBody3D

func _rollback_tick(delta: float, _tick: int, _is_fresh: bool) -> void:
	if not entity or entity.get("sync_is_dead"): 
		input_axis = Vector2.ZERO
		return
	
	# Handle Stun
	if _server_state and _server_state.is_stunned:
		input_axis = Vector2.ZERO
		is_shooting = false
		if multiplayer.is_server():
			_server_state.stun_remaining_time -= delta
			if _server_state.stun_remaining_time <= 0:
				_server_state.is_stunned = false
		_apply_movement(delta)
		return
		
	var is_human = entity.name.is_valid_int()
	
	if is_human and _is_local_authority():
		input_axis = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		is_shooting = Input.is_action_pressed("shoot")
		
		# Dash trigger (Prediction handled by Netfox)
		if Input.is_action_just_pressed("dash") and dash_cooldown <= 0 and not is_dashing:
			is_dashing = true
			dash_timer = DASH_DURATION
			dash_cooldown = DASH_COOLDOWN_TIME
			
			# Dash in movement direction, or forward if standing still
			var move_dir = Vector3.ZERO
			if input_axis.length() > 0:
				var forward = -entity.global_transform.basis.z
				var right = entity.global_transform.basis.x
				move_dir = (forward * -input_axis.y + right * input_axis.x).normalized()
			else:
				move_dir = -entity.global_transform.basis.z
			
			dash_direction = move_dir

	elif not is_human and multiplayer.is_server():
		# AI CONTROL: Only on server for non-humans
		var ai = entity.get_node_or_null("AIComponent")
		if ai and ai.has_method("tick"):
			ai.tick(delta)

	# --- Dash & Cooldown Management ---
	if dash_timer > 0:
		dash_timer -= delta
		if dash_timer <= 0:
			is_dashing = false
			
	if dash_cooldown > 0:
		dash_cooldown -= delta
		
	# Sync dash state to ServerState for visuals
	if _server_state and multiplayer.is_server():
		_server_state.sync_is_dashing = is_dashing

	# Authoritative Summoning input consumed
	if is_human and summon_type != -1:
		summon_type = -1 
	
	_apply_movement(delta)

func _apply_movement(delta: float) -> void:
	if not entity: return
	
	if _server_state and _server_state.is_stunned:
		current_velocity = current_velocity.move_toward(Vector3.ZERO, acceleration * 10.0 * delta)
	# 0. DASH Logic (Predictive)
	elif is_dashing:
		current_velocity = dash_direction * (max_speed * DASH_SPEED_MULT)
	# 1. Authoritative Knockback State from ServerState
	elif _server_state and _server_state.knockback_remaining_time > 0:
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
	var old_pos = entity.global_position
	entity.velocity = current_velocity
	entity.move_and_slide()
	
	# CRITICAL FOR NETFOX: Force transform update so rollback captures the new position
	# Optimization: Only force update if position actually changed or if it's the server
	if old_pos.distance_squared_to(entity.global_position) > 0.0001 or multiplayer.is_server():
		entity.force_update_transform()
	
	# Sync back velocity for next frame (handles collisions stopping movement)
	current_velocity = entity.velocity

# Removed _clear_server_impulse as it's no longer needed with time-based state

func _is_local_authority() -> bool:
	if not entity: return false
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	return multiplayer.get_unique_id() == owner_id
