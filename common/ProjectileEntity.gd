# res://common/ProjectileEntity.gd
class_name ProjectileEntity
extends CharacterBody3D

## Standalone networked projectile entity.
## Spawned server-side by CombatComponent, replicated via MultiplayerSpawner.
## Movement and hit detection run inside _rollback_tick() for Netfox compatibility.
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

## Initialize the projectile after spawning.
## Called by CombatComponent on the server before adding to the tree.
func initialize(direction: Vector3, p_speed: float, p_damage: float, p_owner_id: int, p_knockback: float = 8.0) -> void:
	_direction = direction.normalized()
	speed = p_speed
	damage = p_damage
	owner_entity_id = p_owner_id
	knockback = p_knockback
	_lifetime_remaining = lifetime
	
	# Orient the projectile to face movement direction
	if _direction.length() > 0.01:
		look_at(global_position + _direction, Vector3.UP)

func _ready() -> void:
	# Server authority — projectile is controlled by the server
	set_multiplayer_authority(1)
	_lifetime_remaining = lifetime
	
	# Set velocity for Netfox rollback sync
	velocity = _direction * speed

func _rollback_tick(delta: float, _tick: int, is_fresh: bool) -> void:
	if _has_hit:
		return
	
	# --- MOVEMENT ---
	velocity = _direction * speed
	move_and_slide()
	
	# --- LIFETIME ---
	_lifetime_remaining -= delta
	if _lifetime_remaining <= 0:
		if multiplayer.is_server():
			_despawn()
		return
	
	# --- HIT DETECTION (Server only) ---
	if not is_fresh or not multiplayer.is_server():
		return
	
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
	
	# Don't hit owner's pets
	if target.is_in_group(&"pets") and target.get("owner_id") == owner_entity_id:
		return false
	
	# Don't hit friendly pets (if projectile is from a pet)
	# The owner_entity_id for pet projectiles is the pet's owner (player)
	# so the check above covers this case.
	
	# Apply damage
	hurtbox.receive_hit_data(int(damage), self)
	
	# Apply knockback via ServerState
	if target.has_node("ServerState"):
		var target_state = target.get_node("ServerState")
		var kb_dir = _direction
		kb_dir.y = 0
		kb_dir = kb_dir.normalized()
		target_state.knockback_velocity = kb_dir * knockback
		target_state.knockback_remaining_time = 0.25
	
	print("[Projectile] Hit %s for %.0f damage" % [target.name, damage])
	return true

func _despawn() -> void:
	if multiplayer.is_server():
		queue_free()
