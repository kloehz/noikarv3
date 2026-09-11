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
@export var ability_q_pressed: bool = false
@export var ability_e_pressed: bool = false
@export var ability_r_pressed: bool = false
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
@export var look_pitch: float = 0.0

# Preview system variables
var is_previewing: bool = false
var preview_type: int = -1
var preview_cancelled: bool = false

var camera_pivot: Node3D
var _server_state: Node
var _ability_component: Node = null
var _perf_probe: Node = null
var _perf_probe_npc_cost_enabled: bool = false
@export var mouse_sensitivity: float = 0.005

func _ready() -> void:
	if Engine.is_editor_hint(): return
	
	_setup_entity()
	var entity_name = entity.name if entity else &"Unknown"
	print("[DEBUG] LogicComponent initializing for entity: %s" % entity_name)
	
	current_velocity = Vector3.ZERO
	camera_pivot = get_parent().get_node_or_null("CameraPivot")
	if entity: 
		look_yaw = entity.rotation.y
		if camera_pivot:
			look_pitch = camera_pivot.rotation.x
		print("[DEBUG] LogicComponent %s: Initial rotation captured" % entity_name)
	
	_server_state = get_parent().get_node_or_null("ServerState")
	_ability_component = get_parent().get_node_or_null("AbilityComponent")
	_setup_perf_probe()

	if not _server_state:
		print("[WARNING] LogicComponent %s: ServerState not found!" % entity_name)
	else:
		print("[DEBUG] LogicComponent %s: ServerState linked" % entity_name)

	# Only human entities own input. Server-driven NPCs receive their intent
	# directly from AI during the authoritative simulation tick.
	if entity and entity.name.is_valid_int():
		NetworkTime.before_tick_loop.connect(_gather_input)

## Sample live Input for the owning human player, once per tick loop.
## RollbackSynchronizer records input_axis/is_shooting/look_yaw and restores
## them for resimulation ticks, so _rollback_tick reads properties only.
func _gather_input() -> void:
	if Engine.is_editor_hint() or not entity: return
	if not entity.name.is_valid_int() or not _is_local_authority(): return

	input_axis = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	is_shooting = Input.is_action_pressed("shoot")
	ability_q_pressed = Input.is_action_just_pressed("ability_q")
	ability_e_pressed = Input.is_action_just_pressed("ability_e")
	ability_r_pressed = Input.is_action_just_pressed("ability_r")

	# Dash trigger (prediction handled by netfox)
	if Input.is_action_just_pressed("dash") and dash_cooldown <= 0 and not is_dashing:
		_start_dash()

func consume_ability_q_intent() -> bool:
	var was_pressed := ability_q_pressed
	ability_q_pressed = false
	return was_pressed

func consume_ability_e_intent() -> bool:
	var was_pressed := ability_e_pressed
	ability_e_pressed = false
	return was_pressed

func consume_ability_r_intent() -> bool:
	var was_pressed := ability_r_pressed
	ability_r_pressed = false
	return was_pressed

func _start_dash() -> void:
	is_dashing = true
	dash_timer = DASH_DURATION
	dash_cooldown = DASH_COOLDOWN_TIME

	# Dash in movement direction, or forward if standing still.
	var move_dir := _input_axis_to_world_direction()
	if input_axis.length() == 0:
		move_dir = -entity.global_transform.basis.z

	dash_direction = move_dir

func _input_axis_to_world_direction() -> Vector3:
	if not entity or input_axis.length() == 0:
		return Vector3.ZERO
	var forward := -entity.global_transform.basis.z
	var right := entity.global_transform.basis.x
	return (forward * -input_axis.y + right * input_axis.x).normalized()

func _input(event: InputEvent) -> void:
	# CRITICAL: Only human-controlled entities should process input.
	# AI entities (pets, mobs) have authority=1 which matches the host's peer ID,
	# so _is_local_authority() alone is NOT enough to filter them out.
	if not entity or not entity.name.is_valid_int(): return
	if not _is_local_authority(): return
			
	# Camera movement (Continuous when mouse is captured)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look_yaw -= event.relative.x * mouse_sensitivity
		look_pitch = clamp(look_pitch - event.relative.y * mouse_sensitivity, deg_to_rad(-60), deg_to_rad(30))
		_apply_camera_aim()

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

func _rollback_tick(delta: float, tick: int, is_fresh: bool) -> void:
	_simulate_tick(delta, tick, is_fresh)

func simulate_authoritative_tick(delta: float, tick: int) -> void:
	_simulate_tick(delta, tick)

func _simulate_tick(delta: float, _tick: int, is_fresh: bool = true) -> void:
	if not entity or entity.get("sync_is_dead"): 
		input_axis = Vector2.ZERO
		return
	# RollbackSynchronizer dispatches every rollback-aware descendant itself.
	# Entity-root grace guards cannot stop this component, so enforce grace here
	# before AI, dash, or movement mutates simulated state.
	if entity.has_method("is_spawn_grace_active") and entity.is_spawn_grace_active():
		input_axis = Vector2.ZERO
		is_shooting = false
		current_velocity = Vector3.ZERO
		return
	
	if is_fresh and _ability_component and multiplayer.is_server():
		if _ability_component.has_method("server_tick"):
			_ability_component.server_tick(delta)
		if _ability_component.has_method("server_process_intents"):
			_ability_component.server_process_intents(self)
		if _server_state and _server_state.has_method("sync_ability_r_state"):
			_server_state.sync_ability_r_state(
				float(_ability_component.get("r_window_remaining")),
				float(_ability_component.get("r_cooldown_remaining"))
			)

	if _server_state and _server_state.is_stunned:
		input_axis = Vector2.ZERO
		is_shooting = false
		is_dashing = false
		dash_timer = 0.0
		dash_direction = Vector3.ZERO
		current_velocity = Vector3.ZERO
		entity.velocity = Vector3.ZERO
		if is_fresh and multiplayer.is_server() and _server_state.has_method("tick_stun"):
			_server_state.tick_stun(delta)
		_apply_movement(delta)
		return
		
	var is_human = entity.name.is_valid_int()

	# Live Input sampling happens in _gather_input() (before_tick_loop).
	# Here we only read input_axis/is_shooting/look_yaw, which netfox records
	# and restores for resimulation ticks.
	if not is_human and multiplayer.is_server():
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
	
	if not is_human and multiplayer.is_server():
		if _perf_probe_npc_cost_enabled:
			var started_usec := Time.get_ticks_usec()
			_apply_npc_movement(delta, true)
			_perf_probe.record_npc_cost(&"movement", Time.get_ticks_usec() - started_usec)
		else:
			_apply_npc_movement(delta)
	else:
		_apply_movement(delta)

func _process(_delta: float) -> void:
	if Engine.is_editor_hint(): return
	if not entity or not entity.name.is_valid_int(): return
	if not _is_local_authority(): return
	# Mouse look is sampled in real time from Input events, but the entity yaw
	# is only applied inside rollback ticks — at 30Hz the camera visibly
	# steps. Apply it every render frame; netfox still records look_yaw per
	# tick and the tick copy stays authoritative for the simulation.
	entity.rotation.y = look_yaw
	_apply_camera_aim()

func _setup_perf_probe() -> void:
	_perf_probe = get_node_or_null("/root/PerfProbe")
	_perf_probe_npc_cost_enabled = _perf_probe != null and not _perf_probe.is_queued_for_deletion() and _perf_probe.get("npc_cost_recording_enabled") == true

func _apply_movement(delta: float) -> void:
	if not entity: return
	_apply_camera_aim()
	
	# 0. DASH Logic (Predictive)
	if is_dashing:
		current_velocity = dash_direction * (max_speed * DASH_SPEED_MULT)
	# 1. Authoritative Knockback State from ServerState — temporarily disabled for playtesting
	# elif _server_state and _server_state.knockback_remaining_time > 0:
	# 	current_velocity = _server_state.knockback_velocity
	#
	# 	# Server manages the timer
	# 	if multiplayer.is_server():
	# 		_server_state.knockback_remaining_time -= delta
	# 		if _server_state.knockback_remaining_time <= 0:
	# 			_server_state.knockback_velocity = Vector3.ZERO
	else:
		# Normal Input-based movement
		# Rotation
		entity.rotation.y = look_yaw
		
		# Direction
		var move_dir := _input_axis_to_world_direction()
		
		# Basic Velocity
		var target_vel = move_dir * max_speed
		current_velocity = current_velocity.move_toward(target_vel, acceleration * 10.0 * delta)
	
	# APPLY MOVEMENT (Refactored to move_and_slide)
	# Wrap with NetworkTime.physics_factor: netfox ticks run from _process
	# (sync_to_physics=false), so move_and_slide() integrates over the RENDER
	# frame delta. Scaling velocity by physics_factor converts per-frame
	# integration into per-tick integration, making real-world speed
	# framerate-independent on clients and on the uncapped-FPS headless server.
	var old_pos = entity.global_position
	entity.velocity = current_velocity * NetworkTime.physics_factor
	entity.move_and_slide()

	# CRITICAL FOR NETFOX: Force transform update so rollback captures the new position
	# Optimization: Only force update if position actually changed or if it's the server
	if old_pos.distance_squared_to(entity.global_position) > 0.0001 or multiplayer.is_server():
		entity.force_update_transform()

	# Sync back velocity for next frame (handles collisions stopping movement)
	current_velocity = entity.velocity / NetworkTime.physics_factor

func _apply_npc_movement(delta: float, record_npc_movement_children: bool = false) -> void:
	if not entity: return
	if input_axis != Vector2.ZERO or current_velocity != Vector3.ZERO or is_dashing or camera_pivot != null or entity.rotation.y != look_yaw:
		if record_npc_movement_children:
			_apply_timed_npc_movement(delta)
		else:
			_apply_movement(delta)
		return

	entity.velocity = Vector3.ZERO
	if record_npc_movement_children:
		var slide_started_usec := Time.get_ticks_usec()
		entity.move_and_slide()
		_perf_probe.record_npc_cost(&"movement_slide", Time.get_ticks_usec() - slide_started_usec)
		var flush_started_usec := Time.get_ticks_usec()
		entity.force_update_transform()
		_perf_probe.record_npc_cost(&"movement_flush", Time.get_ticks_usec() - flush_started_usec)
	else:
		entity.move_and_slide()
		entity.force_update_transform()
	current_velocity = entity.velocity / NetworkTime.physics_factor

func _apply_timed_npc_movement(delta: float) -> void:
	var prepare_started_usec := Time.get_ticks_usec()
	_apply_camera_aim()

	# 0. DASH Logic (Predictive)
	if is_dashing:
		current_velocity = dash_direction * (max_speed * DASH_SPEED_MULT)
	else:
		# Normal Input-based movement
		entity.rotation.y = look_yaw
		var move_dir := _input_axis_to_world_direction()
		var target_vel = move_dir * max_speed
		current_velocity = current_velocity.move_toward(target_vel, acceleration * 10.0 * delta)
	_perf_probe.record_npc_cost(&"movement_prepare", Time.get_ticks_usec() - prepare_started_usec)

	var old_pos = entity.global_position
	entity.velocity = current_velocity * NetworkTime.physics_factor
	var slide_started_usec := Time.get_ticks_usec()
	entity.move_and_slide()
	_perf_probe.record_npc_cost(&"movement_slide", Time.get_ticks_usec() - slide_started_usec)

	if old_pos.distance_squared_to(entity.global_position) > 0.0001 or multiplayer.is_server():
		var flush_started_usec := Time.get_ticks_usec()
		entity.force_update_transform()
		_perf_probe.record_npc_cost(&"movement_flush", Time.get_ticks_usec() - flush_started_usec)

	current_velocity = entity.velocity / NetworkTime.physics_factor

# Removed _clear_server_impulse as it's no longer needed with time-based state

func _is_local_authority() -> bool:
	if not entity: return false
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	return multiplayer.get_unique_id() == owner_id

func get_aim_direction() -> Vector3:
	return -Basis.from_euler(Vector3(look_pitch, look_yaw, 0.0)).z.normalized()

func _apply_camera_aim() -> void:
	if camera_pivot:
		camera_pivot.rotation.x = look_pitch
