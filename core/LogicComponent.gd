@tool
# res://core/LogicComponent.gd
class_name LogicComponent
extends Node

## Server-side logic component for authoritative physics and movement.
## 
## VECTOR MOVEMENT MATHEMATICS:
## ============================================================
## Instead of using move_and_slide()'s internal motor, we perform
## manual vector integration for deterministic network sync.
##
## The movement calculation follows these steps:
##
## 1. INPUT VECTOR: Get directional input (e.g., from Netfox input buffer)
##    input_dir = Vector3(input_x, 0, input_z).normalized()
##
## 2. TARGET VELOCITY: Scale input by max speed
##    target_vel = input_dir * max_speed
##
## 3. ACCELERATION: Interpolate current velocity toward target
##    Using: current = current.move_toward(target, accel * delta)
##    This provides smooth acceleration without overshoot.
##
## 4. INTEGRATION: Calculate displacement for this frame
##    displacement = current_velocity * delta
##
## 5. COLLISION: Use move_and_collide() to resolve collisions
##    collision = entity.move_and_collide(displacement)
##    If collision occurs:
##      - Extract collision normal from KinematicCollision3D
##      - Slide velocity along normal: vel = vel.slide(normal)
##      - This preserves momentum tangentially
##
## 6. POSITION UPDATE: CharacterBody3D.position updates automatically
##    via move_and_collide() calling internally.
##
## Why move_and_collide over move_and_slide:
## - move_and_slide() has internal state (velocity smoothing, auto-jump)
##   that makes network reconciliation non-deterministic.
## - move_and_collide() gives direct control over the collision response,
##   ensuring identical behavior on server and clients.
## - The collision.normal provides the exact reflection vector needed
##   for proper sliding physics.
##
## DISTANCE-BASED COLLISION:
## Use collision.shape.collide() with transforms to check if two
## bodies would collide before actually moving:
##   transform_a = Transform3D(Basis(), position_a)
##   transform_b = Transform3D(Basis(), position_b)
##   would_collide = shape_a.collide(shape_a_transform, shape_b_transform)
## ============================================================

## Entity this component controls (set via Editor or spawner).
@export var entity: CharacterBody3D

## Maximum movement speed in units/second.
@export var max_speed: float = 5.0

## Acceleration in units/second². Controls how fast we reach max speed.
@export var acceleration: float = 20.0

## Friction/deceleration when no input is given.
@export var friction: float = 15.0

## Current velocity (synchronized).
@export var current_velocity: Vector3 = Vector3.ZERO

## Current input vector (synchronized).
@export var input_vector: Vector3 = Vector3.ZERO

## Is the player shooting? (synchronized).
@export var is_shooting: bool = false

## Current horizontal rotation (synchronized).
@export var look_yaw: float = 0.0

## Cached collision shape for distance checks.
var _collision_shape: CollisionShape3D

## Camera pivot node for rotation.
@onready var camera_pivot: Node3D = get_parent().get_node_or_null("CameraPivot")

## Mouse sensitivity for camera rotation.
@export var mouse_sensitivity: float = 0.005

func _ready() -> void:
	# In tool mode, we still want to function in editor for debugging
	if Engine.is_editor_hint():
		return
	
	_setup_entity()
	if entity:
		look_yaw = entity.rotation.y

func _input(event: InputEvent) -> void:
	# Only handle input if we are the local authority
	if not _is_local_authority():
		return
		
	# TPS Camera: Update rotation values
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		# Horizontal: Accumulate in look_yaw
		look_yaw -= event.relative.x * mouse_sensitivity
		
		# Vertical: Apply to pivot (visual only, no need to sync)
		if camera_pivot:
			var new_rotation_x = camera_pivot.rotation.x - event.relative.y * mouse_sensitivity
			camera_pivot.rotation.x = clamp(new_rotation_x, deg_to_rad(-60), deg_to_rad(30))

## Set up entity reference and cache collision shape.
func _setup_entity() -> void:
	if not entity:
		entity = get_parent() as CharacterBody3D
	
	if entity and entity.has_node("CollisionShape3D"):
		_collision_shape = entity.get_node("CollisionShape3D")

## Netfox Rollback Tick.
## Runs on both server and clients (for prediction).
func _rollback_tick(delta: float, _tick: int, _is_fresh: bool) -> void:
	if _is_local_authority():
		_process_movement_input()
	
	# Apply synchronized rotation
	if entity:
		entity.rotation.y = look_yaw
		
	_apply_movement(delta)

## Process movement input.
func _process_movement_input() -> void:
	input_vector = _get_input_direction()
	is_shooting = Input.is_action_pressed("shoot")

## Get input direction relative to the entity's local orientation.
func _get_input_direction() -> Vector3:
	# WASD vector: x is left/right, y is up/down (forward/back)
	var raw_input = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	
	# Since we rotate the ENTITY body with the mouse, 
	# we just need to move relative to its LOCAL axes.
	# In Godot: -Z is local Forward, +X is local Right.
	var dir = Vector3.ZERO
	dir += -entity.transform.basis.z * -raw_input.y # Forward/Back
	dir += entity.transform.basis.x * raw_input.x  # Right/Left
	
	# Keep it strictly horizontal
	dir.y = 0
	return dir.normalized()

## Apply movement using move_and_collide for deterministic physics.
func _apply_movement(delta: float) -> void:
	if not entity or not entity.is_inside_tree():
		return
	
	if input_vector.length() > 0.0:
		# Accelerate toward target velocity
		var target_vel := input_vector.normalized() * max_speed
		current_velocity = current_velocity.move_toward(target_vel, acceleration * delta)
	else:
		# Decelerate when no input
		current_velocity = current_velocity.move_toward(Vector3.ZERO, friction * delta)
	
	# Calculate displacement for this frame
	var displacement := current_velocity * delta
	
	# Perform collision detection and resolution
	var collision: KinematicCollision3D = entity.move_and_collide(displacement)
	
	if collision:
		current_velocity = current_velocity.slide(collision.get_normal())
		_entity_collided.emit(collision)

## Check if current context has local authority for input.
func _is_local_authority() -> bool:
	return entity and entity.is_multiplayer_authority()

## Check if a collision would occur at a given position without moving.
## Useful for AI pathfinding and raycasting alternatives.
func check_distance_collision(to_position: Vector3) -> bool:
	if not _collision_shape or not entity:
		return false
	
	var shape := _collision_shape.shape
	if not shape:
		return false
	
	var current_transform := entity.global_transform
	var test_transform := Transform3D(Basis(), to_position)
	
	return shape.collide(current_transform, shape, test_transform)

## Server authority check - mirrors NetworkManager.is_server() logic.
func _is_server_authority() -> bool:
	# In single-player (no multiplayer context), we act as server
	if multiplayer == null:
		return true
	return multiplayer.is_server()

## Signal emitted when entity collides with something.
signal _entity_collided(collision: KinematicCollision3D)
