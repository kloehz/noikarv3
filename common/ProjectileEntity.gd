# res://common/ProjectileEntity.gd
class_name ProjectileEntity
extends CharacterBody3D

## Standalone networked projectile entity.
## Spawned server-side by CombatComponent, replicated via MultiplayerSpawner.
## Projectiles are server-owned. Clients receive spawn-only presentation fields
## and move cosmetically until authoritative despawn. They never run collision,
## damage, knockback, lifetime, or despawn.
## Rollback is intentionally absent: prediction is disabled for projectiles, so
## there is no predicted state to reconcile.

@export var speed: float = 20.0
@export var direction: Vector3 = Vector3.FORWARD
@export var damage: float = 20.0
@export var knockback: float = 8.0
@export var lifetime: float = 3.0
@export var owner_entity_id: int = -1

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
	self.direction = direction.normalized()
	speed = p_speed
	damage = p_damage
	owner_entity_id = p_owner_id
	knockback = p_knockback
	_owner_entity = p_owner_entity
	_lifetime_remaining = lifetime

func _ready() -> void:
	# Server authority — projectile gameplay is controlled by peer 1 only.
	add_to_group(&"projectiles")
	set_multiplayer_authority(1)
	collision_mask = TARGET_COLLISION_MASK
	_lifetime_remaining = lifetime
	velocity = direction * speed
	set_process(not multiplayer.is_server())

	# Orient the projectile to face movement direction (now that we have a
	# global transform inside the tree).
	if direction.length() > 0.01:
		look_at(global_position + direction, Vector3.UP)

	if multiplayer.is_server():
		var tick_callable := Callable(self, "_on_projectile_tick")
		if not NetworkTime.on_tick.is_connected(tick_callable):
			NetworkTime.on_tick.connect(tick_callable)
		if _is_headless_server_runtime():
			_strip_server_presentation.call_deferred()
	else:
		_disable_client_collision()

func _exit_tree() -> void:
	var tick_callable := Callable(self, "_on_projectile_tick")
	if NetworkTime.on_tick.is_connected(tick_callable):
		NetworkTime.on_tick.disconnect(tick_callable)

func _is_headless_server_runtime() -> bool:
	return multiplayer.is_server() and (OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless")

func _strip_server_presentation() -> void:
	var presentation_node := get_node_or_null("MeshInstance3D")
	if presentation_node:
		presentation_node.process_mode = Node.PROCESS_MODE_DISABLED
		remove_child(presentation_node)
		presentation_node.free()

func _disable_client_collision() -> void:
	collision_layer = 0
	collision_mask = 0
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape:
		collision_shape.disabled = true

func _process(delta: float) -> void:
	if multiplayer.is_server():
		return
	position += direction * speed * delta

func _on_projectile_tick(delta: float, _tick: int) -> void:
	if not multiplayer.is_server():
		return
	_simulate_authoritative_tick(delta)

func _simulate_authoritative_tick(delta: float) -> void:
	if _has_hit:
		return
	
	# --- MOVEMENT + HIT DETECTION ---
	velocity = direction * speed
	var collision := move_and_collide(velocity * delta)
	if collision:
		var collider := collision.get_collider()
		if collider and _try_hit(collider):
			_has_hit = true
			_despawn()
			return
	
	# --- LIFETIME ---
	_lifetime_remaining -= delta
	if _lifetime_remaining <= 0:
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
		var kb_dir = direction
		kb_dir.y = 0
		kb_dir = kb_dir.normalized()
		target_state.knockback_velocity = kb_dir * knockback
		target_state.knockback_remaining_time = 0.25
	
	return true

func _despawn() -> void:
	if multiplayer.is_server():
		queue_free()
