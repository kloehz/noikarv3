# res://common/BaseEntity.gd
class_name BaseEntity
extends CharacterBody3D

# regions
@warning_ignore("unused_signal")
signal health_changed(current: int, maximum: int)
signal died
#endregion

#region Exports
@export var max_health: int = 100
@export var entity_name: String = "Entity"
@export var character_actor_path: String = "res://scenes/characters/Aatrox.tscn"
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

func _ready() -> void:
	if not is_inside_tree():
		await ready
		
	print("[DEBUG] BaseEntity %s initialization started (peer_id: %d)" % [name, multiplayer.get_unique_id()])
	
	var peer_id = name.to_int() if name.is_valid_int() else 1
	
	# Set authority recursively for all nodes in the character
	print("[DEBUG] BaseEntity %s setting authority to %d" % [name, peer_id])
	set_multiplayer_authority(peer_id, true)
	
	_load_character_actor()
	
	if server_state:
		print("[DEBUG] BaseEntity %s configuring server_state" % name)
		# Force server authority for the state container recursively
		server_state.set_multiplayer_authority(1, true)
		
		server_state.health_changed.connect(_on_sync_health_changed)
		server_state.death_changed.connect(_on_sync_death_changed)
		server_state.name_changed.connect(func(_n): _update_visuals())
		
		if multiplayer.is_server():
			server_state.max_health = max_health
			server_state.sync_health = max_health
	else:
		print("[WARNING] BaseEntity %s: ServerState not found!" % name)

	# Netfox requires re-processing settings if authority changes after entering tree
	if has_node("RollbackSynchronizer"):
		var rb = get_node("RollbackSynchronizer")
		if rb and rb.has_method("process_settings"):
			print("[DEBUG] BaseEntity %s processing RollbackSynchronizer settings" % name)
			rb.process_settings()

	_setup_visuals()
	_setup_netfox()
	_setup_health_component()
	
	# SECURITY & CRASH FIX: Strip visual nodes from BaseEntity itself in headless mode
	if GameManager._is_headless_environment():
		print("[DEBUG] Headless environment: Stripping visual nodes from BaseEntity root: %s" % name)
		_strip_visual_nodes(self)
	
	print("[DEBUG] BaseEntity %s initialization complete" % name)

func _on_sync_health_changed(current: int, maximum: int) -> void:
	var hc = get_node_or_null("HealthComponent")
	var old_health = hc.current_health if hc else 100
	
	if current < old_health:
		print("[BaseEntity] %s took damage! %d -> %d" % [name, old_health, current])
		EventBus.entity_damaged.emit(self, old_health - current, null)

	if hc: hc.current_health = current
	health_changed.emit(current, maximum)

func _on_sync_death_changed(is_dead: bool) -> void:
	if is_dead:
		# DEATH PENALTY: Lose half of souls if it's a player
		if multiplayer.is_server() and server_state and server_state.sync_souls > 0:
			var lost_souls = server_state.sync_souls / 2
			print("[BaseEntity] %s DIED - Losing %d souls" % [name, lost_souls])
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
	
	var scene = load(character_actor_path) as PackedScene
	if scene:
		character_actor = scene.instantiate() as CharacterActor
		
		# SECURITY & CRASH FIX: If headless, strip all visual nodes immediately
		if GameManager._is_headless_environment():
			print("[DEBUG] Headless environment detected. Stripping visual nodes from %s" % name)
			_strip_visual_nodes(character_actor)
		
		add_child(character_actor)
		# Ensure authority matches
		character_actor.set_multiplayer_authority(get_multiplayer_authority(), true)
		print("[BaseEntity] Character actor loaded: ", character_actor_path)

func _strip_visual_nodes(node: Node) -> void:
	if not node: return
	
	# Create a list of children to remove to avoid modifying the collection while iterating
	var to_remove = []
	for child in node.get_children():
		if child is MeshInstance3D or child is Sprite3D or child is Decal or child is GPUParticles3D or child is CPUParticles3D:
			to_remove.append(child)
		else:
			_strip_visual_nodes(child)
	
	for child in to_remove:
		print("[DEBUG] Removing visual node immediately: %s" % child.name)
		child.free() # Immediate removal to prevent any engine processing

func _setup_visuals() -> void:
	if GameManager._is_headless_environment(): return
	
	if has_node("VisualComponent"):
		$VisualComponent.entity = self
		$VisualComponent.setup_with_actor(character_actor)
		_update_visuals()
	
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
				print("[BaseEntity] Server updating sync_health for %s to %d" % [name, c])
				server_state.sync_health = c
			health_changed.emit(c, m)
		)
		hc.died.connect(func(): 
			if multiplayer.is_server() and server_state:
				print("[BaseEntity] Server detected death for %s" % name)
				server_state.sync_is_dead = true
		)

func respawn(new_position: Vector3) -> void:
	if not multiplayer.is_server(): return
	global_position = new_position
	if server_state:
		server_state.sync_is_dead = false
		server_state.sync_health = max_health

## Apply new base stats from the server
func apply_stats(new_hp: int) -> void:
	max_health = new_hp
	if server_state:
		server_state.max_health = new_hp
		server_state.sync_health = new_hp
	
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.max_health = new_hp
		hc.reset_health()
	
	print("[BaseEntity] Stats applied to %s: HP %d" % [name, new_hp])

func _update_visuals() -> void:
	if has_node("VisualComponent"): $VisualComponent.update_name(player_name)

func _is_server_authority() -> bool:
	return multiplayer == null or multiplayer.is_server()
