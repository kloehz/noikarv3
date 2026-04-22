# res://core/CombatComponent.gd
class_name CombatComponent
extends Node

## Server-authoritative combat component with data-driven attacks.
## Configured at runtime by BaseEntity after loading the CharacterActor.
## Supports MELEE_HITSCAN (dynamic ShapeCast3D) and PROJECTILE (server-spawned).
##
## Rollback properties: current_attack_state, sync_attack_count

signal attack_started

# --- Runtime configuration (set via configure()) ---
var _primary: AttackDefinition
var _secondary: AttackDefinition
var _active_attack: AttackDefinition  # Currently executing attack

# --- Fallback defaults (used if no AttackDefinition is configured) ---
@export var damage: int = 15
@export var knockback_force: float = 12.0

# --- Node references ---
var entity: BaseEntity
var logic: Node
var _melee_shapecast: ShapeCast3D  # Dynamically created for MELEE_HITSCAN

# --- Attack State Machine ---
enum AttackState { READY, STARTUP, ACTIVE, RECOVERY }
var current_attack_state: AttackState = AttackState.READY
var _state_timer: float = 0.0

# --- Cooldown per slot ---
var _primary_cooldown: float = 0.0
var _secondary_cooldown: float = 0.0

# --- Networked Visuals ---
## Counter incremented on each attack start for rollback-safe VFX sync.
@export var sync_attack_count: int = 0
## Local counter used by VisualComponent to detect new attacks.
## NOT a rollback state property — visual-only.
var _local_attack_count: int = 0

func _ready() -> void:
	entity = get_parent() as BaseEntity
	var entity_name = entity.name if entity else &"Unknown"
	
	logic = get_node_or_null("../LogicComponent")
	if not logic:
		print("[CombatComponent] %s: LogicComponent not found" % entity_name)
	
	# If there's a static ShapeCast3D in the scene, use it as fallback
	var static_cast = get_node_or_null("../ShapeCast3D")
	if static_cast and not _melee_shapecast:
		_melee_shapecast = static_cast
		_melee_shapecast.add_exception(get_parent())

## Configure attack slots from AttackDefinition resources.
## Called by BaseEntity after loading the CharacterActor.
func configure(primary: AttackDefinition, secondary: AttackDefinition = null) -> void:
	_primary = primary
	_secondary = secondary
	
	var entity_name = entity.name if entity else &"Unknown"
	
	# Build a ShapeCast3D for melee primary
	if _primary and _primary.attack_type == AttackDefinition.AttackType.MELEE_HITSCAN:
		_setup_melee_shapecast(_primary.shape_data)
		print("[CombatComponent] %s: Configured MELEE primary (dmg=%.0f, radius=%.1f)" % [
			entity_name, _primary.base_damage,
			_primary.shape_data.radius if _primary.shape_data else 0.0
		])
	elif _primary and _primary.attack_type == AttackDefinition.AttackType.PROJECTILE:
		print("[CombatComponent] %s: Configured PROJECTILE primary (dmg=%.0f, speed=%.0f)" % [
			entity_name, _primary.base_damage, _primary.projectile_speed
		])
	elif _primary:
		print("[CombatComponent] %s: Configured primary (type=%d, stub)" % [entity_name, _primary.attack_type])
	
	if _secondary:
		print("[CombatComponent] %s: Secondary attack configured (type=%d)" % [entity_name, _secondary.attack_type])

## Create or reconfigure the dynamic ShapeCast3D from AttackShapeData.
func _setup_melee_shapecast(shape_data: AttackShapeData) -> void:
	if not shape_data:
		return
	
	# Remove old dynamic cast if it exists
	if _melee_shapecast and _melee_shapecast.name == &"DynamicShapeCast":
		_melee_shapecast.queue_free()
		_melee_shapecast = null
	
	# If there's already a static ShapeCast3D in the scene, reconfigure it
	var static_cast = get_node_or_null("../ShapeCast3D")
	if static_cast:
		_configure_shapecast_from_data(static_cast, shape_data)
		_melee_shapecast = static_cast
		return
	
	# Create a new ShapeCast3D dynamically
	var cast = ShapeCast3D.new()
	cast.name = &"DynamicShapeCast"
	_configure_shapecast_from_data(cast, shape_data)
	
	get_parent().add_child(cast)
	_melee_shapecast = cast

## Apply AttackShapeData parameters to a ShapeCast3D node.
func _configure_shapecast_from_data(cast: ShapeCast3D, data: AttackShapeData) -> void:
	# Create shape based on type
	var shape: Shape3D
	match data.shape_type:
		AttackShapeData.ShapeType.SPHERE:
			var s = SphereShape3D.new()
			s.radius = data.radius
			shape = s
		AttackShapeData.ShapeType.BOX:
			var s = BoxShape3D.new()
			s.size = Vector3(data.radius * 2, data.height, data.length)
			shape = s
		AttackShapeData.ShapeType.CAPSULE:
			var s = CapsuleShape3D.new()
			s.radius = data.radius
			s.height = data.length
			shape = s
	
	cast.shape = shape
	cast.transform.origin = data.offset
	cast.target_position = Vector3.ZERO  # Instant cast, no sweep
	cast.max_results = 8
	cast.collide_with_areas = true
	cast.add_exception(get_parent())

# ============================================================
# ROLLBACK TICK — called by Netfox
# ============================================================

func _rollback_tick(delta: float, _tick: int, is_fresh: bool) -> void:
	if not is_fresh:
		return
	
	# Tick cooldowns
	if _primary_cooldown > 0: _primary_cooldown -= delta
	if _secondary_cooldown > 0: _secondary_cooldown -= delta
	
	_update_attack_state(delta)
	
	# Only owner or server can start attacks
	var owner_id = entity.name.to_int() if entity.name.is_valid_int() else 1
	var is_owner = (multiplayer.get_unique_id() == owner_id)
	
	if (multiplayer.is_server() or is_owner) and current_attack_state == AttackState.READY:
		if logic and logic.get("is_shooting"):
			_try_start_attack(_primary, true)
		# TODO: secondary trigger (e.g. right-click, separate input)

func _update_attack_state(delta: float) -> void:
	if current_attack_state == AttackState.READY:
		return
	
	_state_timer -= delta
	
	if _state_timer <= 0:
		match current_attack_state:
			AttackState.STARTUP:
				current_attack_state = AttackState.ACTIVE
				_state_timer = _active_attack.active_time if _active_attack else 0.3
				_on_attack_active()
			AttackState.ACTIVE:
				current_attack_state = AttackState.RECOVERY
				_state_timer = _active_attack.recovery_time if _active_attack else 0.3
			AttackState.RECOVERY:
				current_attack_state = AttackState.READY
				_active_attack = null

# ============================================================
# ATTACK START
# ============================================================

func _try_start_attack(definition: AttackDefinition, is_primary: bool) -> void:
	# Check cooldown
	if is_primary and _primary_cooldown > 0: return
	if not is_primary and _secondary_cooldown > 0: return
	
	# Use provided definition or fall back
	var attack_def = definition
	if not attack_def:
		# No definition configured — use legacy fallback behavior
		_active_attack = null
		current_attack_state = AttackState.STARTUP
		_state_timer = 0.1
		sync_attack_count += 1
		attack_started.emit()
		return
	
	_active_attack = attack_def
	current_attack_state = AttackState.STARTUP
	_state_timer = attack_def.startup_time
	sync_attack_count += 1
	attack_started.emit()
	
	# Set cooldown
	if is_primary:
		_primary_cooldown = attack_def.cooldown
	else:
		_secondary_cooldown = attack_def.cooldown

# ============================================================
# ATTACK ACTIVE FRAME — Dispatch based on type
# ============================================================

func _on_attack_active() -> void:
	if not multiplayer.is_server():
		return
	
	if _active_attack:
		match _active_attack.attack_type:
			AttackDefinition.AttackType.MELEE_HITSCAN:
				_execute_melee_hitscan(_active_attack)
			AttackDefinition.AttackType.PROJECTILE:
				_execute_projectile(_active_attack)
			AttackDefinition.AttackType.AOE_DELAYED:
				# TODO: Implement AOE_DELAYED attack type
				print("[CombatComponent] AOE_DELAYED is not yet implemented")
	else:
		# Legacy fallback: use the static ShapeCast3D with @export damage
		_execute_melee_legacy()

# ============================================================
# MELEE HITSCAN
# ============================================================

func _execute_melee_hitscan(attack_def: AttackDefinition) -> void:
	if not _melee_shapecast:
		push_error("[CombatComponent] %s: No ShapeCast3D for melee attack!" % entity.name)
		return
	
	_melee_shapecast.force_shapecast_update()
	
	if _melee_shapecast.is_colliding():
		var hit_count = _melee_shapecast.get_collision_count()
		var final_damage = attack_def.base_damage
		if attack_def.shape_data:
			final_damage *= attack_def.shape_data.damage_multiplier
		
		for i in range(hit_count):
			var collider = _melee_shapecast.get_collider(i)
			_handle_hit(collider, int(final_damage), attack_def.knockback_force)

## Legacy fallback for entities without AttackDefinition
func _execute_melee_legacy() -> void:
	if not _melee_shapecast:
		return
	
	_melee_shapecast.force_shapecast_update()
	
	if _melee_shapecast.is_colliding():
		var hit_count = _melee_shapecast.get_collision_count()
		for i in range(hit_count):
			var collider = _melee_shapecast.get_collider(i)
			_handle_hit(collider, damage, knockback_force)

# ============================================================
# PROJECTILE
# ============================================================

func _execute_projectile(attack_def: AttackDefinition) -> void:
	if not attack_def.projectile_scene:
		push_error("[CombatComponent] %s: No projectile_scene in AttackDefinition!" % entity.name)
		return
	
	# Spawn direction: entity's forward vector
	var direction = -entity.global_transform.basis.z.normalized()
	
	# Spawn position: slightly in front of entity at chest height
	var spawn_pos = entity.global_position + Vector3(0, 1, 0) + direction * 1.0
	
	var projectile = attack_def.projectile_scene.instantiate()
	projectile.global_position = spawn_pos
	
	# Owner ID for faction check
	var owner_id: int
	if entity.name.is_valid_int():
		owner_id = entity.name.to_int()
	elif entity.get("owner_id"):
		owner_id = entity.get("owner_id")
	else:
		owner_id = 1
	
	# Initialize projectile
	if projectile.has_method("initialize"):
		projectile.initialize(
			direction,
			attack_def.projectile_speed,
			attack_def.base_damage,
			owner_id,
			attack_def.knockback_force
		)
	
	# Add to scene tree — MultiplayerSpawner handles replication
	var projectiles_container = get_tree().root.find_child("Projectiles", true, false)
	if projectiles_container:
		projectiles_container.add_child(projectile, true)
	else:
		# Fallback: add to same parent as Players
		var players = get_tree().root.find_child("Players", true, false)
		if players and players.get_parent():
			players.get_parent().add_child(projectile, true)
		else:
			get_tree().root.add_child(projectile, true)
	
	print("[CombatComponent] %s fired projectile (dmg=%.0f, speed=%.0f)" % [
		entity.name, attack_def.base_damage, attack_def.projectile_speed
	])

# ============================================================
# HIT HANDLING — shared by all attack types
# ============================================================

func _handle_hit(collider: Node, hit_damage: int, hit_knockback: float) -> void:
	# Find the hurtbox
	var hurtbox = collider as HurtboxComponent
	if not hurtbox and collider.has_node("HurtboxComponent"):
		hurtbox = collider.get_node("HurtboxComponent")
	
	if hurtbox:
		var target = hurtbox.get_parent()
		
		# === FACTION CHECKS ===
		# Don't hit yourself
		if target == entity: return
		
		# If I am a pet, don't hit my owner or sibling pets
		if entity.is_in_group(&"pets"):
			var my_owner_id = entity.get("owner_id")
			if str(my_owner_id) == target.name: return
			if target.is_in_group(&"pets") and target.get("owner_id") == my_owner_id: return
		
		# If I am a player, don't hit my own pets
		if entity.name.is_valid_int():
			if target.is_in_group(&"pets") and str(target.get("owner_id")) == entity.name: return
		
		# === APPLY DAMAGE ===
		hurtbox.receive_hit_data(hit_damage, entity)
		
		# === APPLY KNOCKBACK via ServerState ===
		if target.has_node("ServerState"):
			var target_state = target.get_node("ServerState")
			var kb_dir = (target.global_position - entity.global_position).normalized()
			kb_dir.y = 0  # Keep horizontal
			target_state.knockback_velocity = kb_dir * hit_knockback
			target_state.knockback_remaining_time = 0.25
