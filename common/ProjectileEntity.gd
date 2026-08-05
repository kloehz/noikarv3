# res://common/ProjectileEntity.gd
class_name ProjectileEntity
extends CharacterBody3D

## Standalone networked projectile entity.
## Spawned server-side by CombatComponent, replicated via MultiplayerSpawner.
## Projectiles are server-owned. Clients interpolate replicated state but never
## simulate movement, collision, damage, or despawn side effects.
##
## Rollback properties: global_position, velocity

@export var speed: float = 20.0
@export var damage: float = 20.0
@export var knockback: float = 8.0
@export var lifetime: float = 3.0
@export var owner_entity_id: int = -1

var _direction: Vector3 = Vector3.FORWARD
var _lifetime_remaining: float = 3.0
var _has_hit: bool = false
var _owner_entity: Node = null

## World, legacy entity, and all faction entity layers. Entity bodies moved to
## RED/BLUE/NEUTRAL layers, so retaining only the old mask made shots pass
## through valid players and pets.
const TARGET_COLLISION_MASK := 1 | 2 | 16 | 32 | 64

## Initialize the projectile after spawning.
## Called by CombatComponent on the server before adding to the tree.
func initialize(direction: Vector3, p_speed: float, p_damage: float, p_owner_id: int, p_knockback: float = 8.0, p_owner_entity: Node = null) -> void:
	_direction = direction.normalized()
	speed = p_speed
	damage = p_damage
	owner_entity_id = p_owner_id
	knockback = p_knockback
	_owner_entity = p_owner_entity
	_lifetime_remaining = lifetime

func _ready() -> void:
	# Server authority — projectile is controlled by the server
	add_to_group(&"projectiles")
	set_multiplayer_authority(1)
	collision_mask = TARGET_COLLISION_MASK
	_lifetime_remaining = lifetime

	# Set velocity for Netfox rollback sync
	velocity = _direction * speed

	# Orient the projectile to face movement direction (now that we have a
	# global transform inside the tree).
	if _direction.length() > 0.01:
		look_at(global_position + _direction, Vector3.UP)

func _rollback_tick(delta: float, _tick: int, is_fresh: bool) -> void:
	if not multiplayer.is_server() or not is_fresh:
		return
	if _has_hit:
		return
	
	# --- MOVEMENT ---
	# Same NetworkTime.physics_factor wrap as LogicComponent: move_and_slide()
	# integrates over the render frame delta, so scale velocity into per-tick
	# displacement to keep projectile speed framerate-independent.
	velocity = _direction * speed * NetworkTime.physics_factor
	move_and_slide()
	velocity /= NetworkTime.physics_factor
	
	# --- LIFETIME ---
	_lifetime_remaining -= delta
	if _lifetime_remaining <= 0:
		if multiplayer.is_server():
			_despawn()
		return
	
	# --- HIT DETECTION ---
	var collision_count = get_slide_collision_count()
	for i in range(collision_count):
		var collision = get_slide_collision(i)
		var collider = collision.get_collider()
		
		if collider and _try_hit(collider):
			_has_hit = true
			_despawn()
			return

## Try to hit a collider. Returns true if valid hit occurred.
func _try_hit(collider: Node) -> bool:
	# Find hurtbox
	var hurtbox: HurtboxComponent = null
	if collider is HurtboxComponent:
		hurtbox = collider
	elif collider.has_node("HurtboxComponent"):
		hurtbox = collider.get_node("HurtboxComponent")

	if not hurtbox:
		# Hit a wall or non-damageable object — still stop
		return true

	var target = hurtbox.get_parent()

	# Don't hit the owner
	if str(owner_entity_id) == target.name:
		return false

	# Pets cannot damage other pets, but enemy projectiles must still hit
	# pets through their regular CharacterBody3D collision shape.
	if target.is_in_group(&"pets") and _owner_entity and _owner_entity.is_in_group(&"pets"):
		return false

	# Damage attribution must use the shooter, not this temporary projectile.
	# Threat tables are keyed by combat entities, so using `self` would leave
	# mobs with a key they can never resolve to a player or pet target.
	hurtbox.receive_hit_data(int(damage), _owner_entity)
	
	# Apply knockback via ServerState
	if target.has_node("ServerState"):
		var target_state = target.get_node("ServerState")
		var kb_dir = _direction
		kb_dir.y = 0
		kb_dir = kb_dir.normalized()
		target_state.knockback_velocity = kb_dir * knockback
		target_state.knockback_remaining_time = 0.25
	
	return true

func _despawn() -> void:
	if multiplayer.is_server():
		queue_free()
