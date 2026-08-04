# res://common/BaseEntity.gd
class_name BaseEntity
extends CharacterBody3D

#region
@warning_ignore("unused_signal")
signal health_changed(current: int, maximum: int)
@warning_ignore("unused_signal")
signal died
#endregion

#region Exports
@export var max_health: int = 100
@export var entity_name: String = "Entity"
## Path to the CharacterActor scene for this entity.
## IMPORTANT: Player entities default to Aatrox; selected player identities can
## replace this actor at runtime through ServerState.character_id.
const CHARACTER_ACTOR_PATHS: Dictionary = {
	"warrior": "res://scenes/characters/Aatrox.tscn",
	"ivern_ranger": "res://scenes/characters/IvernRanger.tscn",
}

@export var character_actor_path: String = "res://scenes/characters/Aatrox.tscn"
## Mob entities use Aatrox.tscn (low base_damage) via EnemyEntity.ENEMY_ACTORS mapping.
## Pets use PetDmg.tscn / PetTank.tscn / PetHeal.tscn via PetEntity setup.
#endregion

var character_actor: CharacterActor

## Original collision transforms are retained so model scaling can be applied
## repeatedly without compounding the collider size or offset.
var _collision_shape_base_transforms: Dictionary[int, Transform3D] = {}

#region Network Sync Variables (Proxy properties)
var player_name: String:
	get: return server_state.player_name if server_state else "Player"
	set(v): if server_state and multiplayer.is_server(): server_state.player_name = v
var sync_is_dead: bool:
	get: return server_state.sync_is_dead if server_state else false
	set(v): if server_state and multiplayer.is_server(): server_state.sync_is_dead = v

var sync_health: int:
	get: return server_state.sync_health if server_state else 100
	set(v): if server_state and multiplayer.is_server(): server_state.sync_health = v
#endregion

@onready var server_state = $ServerState

# Static cache to avoid repeated load calls across all instances
static var _actor_scene_cache: Dictionary = {}

func _ready() -> void:
	if not is_inside_tree():
		await ready
		
	# Assign groups for faster AI faction detection
	if name.is_valid_int():
		add_to_group(&"players")
	elif name.begins_with("Dummy") or name.begins_with("ELITE") or name.begins_with("MOB_") or name.begins_with("BOSS_"):
		add_to_group(&"mobs")
	elif name.begins_with("PET"):
		add_to_group(&"pets")
		
	var peer_id = 1 # Default to server
	var is_human = name.is_valid_int()
	
	if is_human:
		peer_id = name.to_int()
		
	print("[DEBUG] BaseEntity %s initialization (peer_id: %d, is_human: %s)" % [name, peer_id, is_human])
	
	# Set authority recursively
	set_multiplayer_authority(peer_id, true)
	
	# ALWAYS load the actor because it contains logic specs (ranges, timings)
	# BaseEntity's load_character_actor now handles headless stripping safely.
	_load_character_actor()
	
	if server_state:
		# Force server authority for the state container recursively
		server_state.set_multiplayer_authority(1, true)
		
		server_state.health_changed.connect(_on_sync_health_changed)
		server_state.death_changed.connect(_on_sync_death_changed)
		server_state.name_changed.connect(func(_n): _update_visuals())
		server_state.character_changed.connect(_on_character_changed)
		
		if multiplayer.is_server():
			server_state.max_health = max_health
			server_state.sync_health = max_health

	# Netfox requires re-processing settings if authority changes after entering tree
	if has_node("RollbackSynchronizer"):
		var rb = get_node("RollbackSynchronizer")
		if rb and rb.has_method("process_settings"):
			rb.process_settings()

	_setup_visuals()
	_setup_netfox()
	_setup_health_component()
	if multiplayer.is_server() and not NetworkTime.after_tick.is_connected(_on_authoritative_tick):
		NetworkTime.after_tick.connect(_on_authoritative_tick)

func _on_sync_health_changed(current: int, maximum: int) -> void:
	# Update local max_health if server changed it
	max_health = maximum
	
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.max_health = maximum
		hc.current_health = current
	
	health_changed.emit(current, maximum)

func _on_sync_death_changed(is_dead: bool) -> void:
	if is_dead:
		# DEATH PENALTY: Lose half of souls if it's a player
		if multiplayer.is_server() and server_state and server_state.sync_souls > 0:
			var lost_souls = server_state.sync_souls / 2
			server_state.sync_souls -= lost_souls
		
		if has_node("VisualComponent"): $VisualComponent.play_death_effect()
		collision_layer = 0
		collision_mask = 0
		if has_node("HurtboxComponent"):
			$HurtboxComponent.monitorable = false
			$HurtboxComponent.monitoring = false
		EventBus.entity_died.emit(self)
	else:
		if has_node("VisualComponent"): $VisualComponent.play_spawn_effect()
		if has_node("HealthComponent"): $HealthComponent.reset_health()
		collision_layer = 1
		collision_mask = 1
		if has_node("HurtboxComponent"):
			$HurtboxComponent.monitorable = true
			$HurtboxComponent.monitoring = true

func _load_character_actor() -> void:
	if character_actor_path.is_empty(): return
	
	var scene: PackedScene
	if _actor_scene_cache.has(character_actor_path):
		scene = _actor_scene_cache[character_actor_path]
	else:
		scene = load(character_actor_path) as PackedScene
		_actor_scene_cache[character_actor_path] = scene
	
	if scene:
		character_actor = scene.instantiate() as CharacterActor
		
		# SECURITY & CRASH FIX: If headless, strip all visual nodes immediately
		# but keep the CharacterActor node alive to read combat specs!
		if GameManager._is_headless_environment():
			print("[DEBUG] Headless environment: Stripping visual nodes from actor %s" % name)
			_strip_visual_nodes(character_actor)
		
		add_child(character_actor)
		# Per-actor facing correction. Imported models in this project ship with
		# +Z as their visible forward, while Godot CharacterBody3D/LogicComponent
		# move along the entity's local -Z. Each actor scene declares its own
		# visual_forward_yaw so the actor's mesh aligns with the movement
		# forward at spawn. We rotate the ACTOR node, never the entity itself,
		# because rotating the entity would invert the AI/chase/look direction
		# that LogicComponent drives through entity.rotation.y.
		if abs(character_actor.visual_forward_yaw) > 0.0001:
			character_actor.rotation.y = character_actor.visual_forward_yaw
		# Ensure authority matches
		if is_instance_valid(character_actor):
			character_actor.set_multiplayer_authority(get_multiplayer_authority(), true)
		
		# --- DATA-DRIVEN COMBAT CONFIGURATION ---
		_configure_combat_from_actor(character_actor)
		_configure_ai_from_actor(character_actor)

## Scales a character model and every collision shape owned by this entity.
## Collider offsets must scale too, otherwise tall models sink their hit volume
## toward the ground when enlarged.
func set_model_scale(scale_factor: float) -> void:
	var applied_scale := maxf(scale_factor, 0.01)
	if is_instance_valid(character_actor):
		character_actor.scale = Vector3.ONE * applied_scale
	for node in find_children("*", "CollisionShape3D", true, false):
		var collision_shape := node as CollisionShape3D
		if collision_shape == null:
			continue
		var instance_id := collision_shape.get_instance_id()
		if not _collision_shape_base_transforms.has(instance_id):
			_collision_shape_base_transforms[instance_id] = collision_shape.transform
		var base_transform: Transform3D = _collision_shape_base_transforms[instance_id]
		collision_shape.transform = Transform3D(
			base_transform.basis.scaled(Vector3.ONE * applied_scale),
			base_transform.origin * applied_scale
		)

## Applies a replicated character identity. The server is the only writer of
## ServerState; clients only react to the synchronized value.
func select_character(character_id: String) -> void:
	if multiplayer.is_server() and server_state:
		server_state.character_id = _validated_character_id(character_id)

func _on_character_changed(character_id: String) -> void:
	var actor_path: String = CHARACTER_ACTOR_PATHS.get(_validated_character_id(character_id), character_actor_path) as String
	if actor_path == character_actor_path and character_actor:
		return
	character_actor_path = actor_path
	if is_instance_valid(character_actor):
		character_actor.queue_free()
		character_actor = null
	_load_character_actor()
	_setup_visuals()

func _validated_character_id(character_id: String) -> String:
	return character_id if CHARACTER_ACTOR_PATHS.has(character_id) else "warrior"

## Read AttackDefinition exports from the Actor and configure CombatComponent.
func _configure_combat_from_actor(actor: CharacterActor) -> void:
	if not actor: return
	var combat = get_node_or_null("CombatComponent")
	if not combat: return
	
	if actor.primary_attack or actor.secondary_attack:
		combat.configure(actor.primary_attack, actor.secondary_attack)
		print("[BaseEntity] %s: Combat configured from actor (%s)" % [name, actor.name])

## Read suggested ranges from the Actor and configure AIComponent.
func _configure_ai_from_actor(actor: CharacterActor) -> void:
	if not actor: return
	var ai = get_node_or_null("AIComponent")
	if not ai: return
	
	ai.attack_range = actor.suggested_attack_range
	ai.detection_range = actor.suggested_detection_range
	ai.follow_distance = actor.suggested_follow_distance
	print("[BaseEntity] %s: AI configured from actor (atk_range=%.1f)" % [name, actor.suggested_attack_range])

func _strip_visual_nodes(node: Node) -> void:
	if not node: return
	var to_remove = []
	for child in node.get_children():
		if child is MeshInstance3D or child is Sprite3D or child is Decal or child is GPUParticles3D or child is CPUParticles3D or child is Label3D:
			to_remove.append(child)
		else:
			_strip_visual_nodes(child)
	for child in to_remove:
		child.queue_free()

func _setup_visuals() -> void:
	if GameManager._is_headless_environment(): return
	
	if has_node("VisualComponent"):
		$VisualComponent.entity = self
		$VisualComponent.setup_with_actor(character_actor)
		_update_visuals()
		
		# FORCE UI Update for health
		var hc = get_node_or_null("HealthComponent")
		if hc:
			_on_sync_health_changed(hc.current_health, hc.max_health)
	
	var is_local_player = (name == str(multiplayer.get_unique_id()))
	var camera = get_node_or_null("CameraPivot/Camera3D")
	if camera:
		if is_local_player: camera.make_current()
		else:
			camera.current = false
			camera.hide()

func _setup_netfox() -> void:
	var interpolator = get_node_or_null("TickInterpolator")
	var owner_id = name.to_int() if name.is_valid_int() else 1
	if interpolator and multiplayer.get_unique_id() == owner_id:
		interpolator.enabled = false

func _setup_health_component() -> void:
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.health_changed.connect(func(c, m): 
			if multiplayer.is_server() and server_state:
				server_state.sync_health = c
			health_changed.emit(c, m)
		)
		hc.healed.connect(func(amount):
			if multiplayer.is_server() and server_state:
				server_state.sync_heal_amount = amount
				server_state.sync_heal_sequence += 1
		)
		hc.damaged.connect(func(amount, source):
			if multiplayer.is_server() and server_state:
				server_state.sync_damage_amount = amount
				server_state.sync_damage_source = source
				server_state.sync_damage_sequence += 1
		)
		hc.died.connect(func():
			if multiplayer.is_server() and server_state:
				server_state.sync_is_dead = true
		)

func respawn(new_position: Vector3) -> void:
	if not multiplayer.is_server(): return
	global_position = new_position
	if server_state:
		server_state.sync_is_dead = false
		server_state.sync_health = max_health

func apply_stats(new_hp: int) -> void:
	max_health = new_hp
	if server_state:
		server_state.max_health = new_hp
		server_state.sync_health = new_hp
	
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.max_health = new_hp
		hc.reset_health()

func _update_visuals() -> void:
	if has_node("VisualComponent"): $VisualComponent.update_name(player_name)

## Linear threat decay rate (per second). Applied on NetworkTime.after_tick
## so aggro follows the authoritative simulation clock.
## At 5.0/sec a single 100-damage hit decays to zero in 20s, but two
## rapid hits keep the mob locked on while the player is active.
const THREAT_DECAY_PER_SECOND: float = 5.0

## Per-entity fractional decay accumulator. A tick contributes less than one
## point at the configured rate, so retain the fraction until it is due.
var _threat_decay_accumulator: float = 0.0

## Server-only aggro decay. The victim owns its threat table; each entry fades
## on a network tick and is replicated through ServerState.
func _on_authoritative_tick(_delta: float, _tick: int) -> void:
	if not multiplayer.is_server():
		return
	if server_state == null:
		return
	if server_state.sync_threat_table.is_empty():
		# Reset accumulator so a fresh threat spike starts from a clean
		# fractional carry-over; otherwise the partial tick left over
		# from the previous burst would apply to the next hit's decay.
		_threat_decay_accumulator = 0.0
		return
	if NetworkTime.tickrate <= 0:
		return
	_threat_decay_accumulator += THREAT_DECAY_PER_SECOND / float(NetworkTime.tickrate)
	var decay: int = int(_threat_decay_accumulator)
	if decay <= 0:
		return
	_threat_decay_accumulator -= float(decay)
	server_state.decay_threat(decay)

func _is_server_authority() -> bool:
	return multiplayer == null or multiplayer.is_server()
