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
## IMPORTANT: Player entities default to PlayerHero.tscn (high base_damage).
## Mob entities use Aatrox.tscn (low base_damage) via EnemyEntity.ENEMY_ACTORS mapping.
## Pets use PetDmg.tscn / PetTank.tscn / PetHeal.tscn via PetEntity setup.
@export var character_actor_path: String = "res://scenes/characters/PlayerHero.tscn"
#endregion

var character_actor: CharacterActor

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
	elif name.begins_with("Dummy") or name.begins_with("ELITE") or name.begins_with("MOB_"):
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
		# Compensate for models imported with +Z as forward (Godot expects -Z)
		character_actor.rotation.y = PI
		# Ensure authority matches
		if is_instance_valid(character_actor):
			character_actor.set_multiplayer_authority(get_multiplayer_authority(), true)
		
		# --- DATA-DRIVEN COMBAT CONFIGURATION ---
		_configure_combat_from_actor(character_actor)
		_configure_ai_from_actor(character_actor)

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

func _rollback_tick(delta: float, tick: int, is_fresh: bool) -> void:
	if has_node("LogicComponent"):
		$LogicComponent._rollback_tick(delta, tick, is_fresh)

func _is_server_authority() -> bool:
	return multiplayer == null or multiplayer.is_server()
