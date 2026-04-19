extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")
const SOUL_SCENE = preload("res://scenes/SoulEntity.tscn")
const TOTEM_SCENE = preload("res://scenes/TotemEntity.tscn")
const PET_SCENE = preload("res://scenes/PetEntity.tscn")
const AI_COMPONENT = preload("res://core/AIComponent.gd")

@onready var players_container: Node3D = $Players

# --- CONFIGURATION: ELITE MOBS ---
@export var elite_respawn_chance: float = 0.4
@export var elite_hp_multiplier: float = 2.5
@export var elite_damage_multiplier: float = 1.6
# ---------------------------------

## Store peer data like names.
var peer_data: Dictionary = {}
var _pending_name: String = ""

func _ready() -> void:
	if GameManager._is_headless_environment():
		print("[DEBUG] MatchManager: Headless mode detected. Stripping visual nodes from world.")
		_strip_visual_nodes_recursive(get_tree().root)

	EventBus.server_started.connect(_on_server_started)
	EventBus.client_connected.connect(_on_client_connected)
	EventBus.client_disconnected.connect(_on_client_disconnected)
	EventBus.player_name_submitted.connect(_on_player_name_submitted)
	EventBus.entity_died.connect(_on_entity_died)
	
	# Listen for successful connection to send pending data
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	
	# INITIAL AI: Give brains to static dummies if server
	if multiplayer.is_server():
		_initialize_static_ai.call_deferred()

func _initialize_static_ai() -> void:
	var root = get_tree().root.find_child("Main", true, false)
	if not root: return
	
	for child in root.get_children():
		if child is BaseEntity and child.name.begins_with("Dummy"):
			var ai = AI_COMPONENT.new()
			ai.name = "AIComponent"
			child.add_child(ai)
			ai.state = 1 # State.CHASE
			print("[MatchManager] Static AI initialized for %s" % child.name)

func _strip_visual_nodes_recursive(node: Node) -> void:
	if not node: return
	
	var to_remove = []
	for child in node.get_children():
		if child is MeshInstance3D or child is Sprite3D or child is Label3D or child is WorldEnvironment or child is DirectionalLight3D or child is GPUParticles3D or child is CPUParticles3D or child is CSGPrimitive3D:
			to_remove.append(child)
		else:
			_strip_visual_nodes_recursive(child)
	
	for child in to_remove:
		print("[DEBUG] MatchManager removing visual: %s" % child.name)
		child.free()

func _on_entity_died(entity: Node3D) -> void:
	if not multiplayer.is_server(): return
	
	# If a non-player entity (dummy/mob) died, spawn a soul
	if not entity.name.is_valid_int():
		_spawn_soul(entity.global_position)
		
	print("[MatchManager] Entity died: ", entity.name, ". Respawning in 3 seconds...")
	
	# Wait for respawn (Normal respawn logic)
	await get_tree().create_timer(3.0).timeout
	
	if is_instance_valid(entity) and entity.has_method("respawn"):
		var random_pos = Vector3(randf_range(-10, 10), 0.1, randf_range(-10, 10))
		print("[MatchManager] Respawning ", entity.name, " at ", random_pos)
		entity.respawn(random_pos)

func _spawn_soul(pos: Vector3) -> void:
	var soul = SOUL_SCENE.instantiate()
	# SET POSITION BEFORE ADD_CHILD
	soul.global_position = pos 
	players_container.add_child(soul, true)
	
	soul.expired.connect(func(): _on_soul_expired(pos))

func _on_soul_expired(pos: Vector3) -> void:
	if randf() < elite_respawn_chance:
		print("[MatchManager] SOUL EXPIRED - Spawning ELITE MOB at ", pos)
		_spawn_elite_mob(pos)

func _spawn_elite_mob(pos: Vector3) -> void:
	var dummy_scene = load("res://scenes/TrainingDummy.tscn")
	var elite = dummy_scene.instantiate()
	
	elite.name = "ELITE_" + str(randi() % 1000)
	elite.global_position = pos
	
	# Setting stats based on multipliers
	var base_hp = 100
	var elite_hp = int(base_hp * elite_hp_multiplier)
	
	players_container.add_child(elite, true)
	
	# Force apply stats immediately after entering tree
	if is_instance_valid(elite):
		elite.apply_stats(elite_hp)
		
		if elite.has_node("CombatComponent"):
			elite.get_node("CombatComponent").damage = int(15 * elite_damage_multiplier)
		
		# ADD AI Brain AFTER it's in tree
		var ai = AI_COMPONENT.new()
		ai.name = "AIComponent"
		elite.add_child(ai)
		ai.state = 1 # State.CHASE
		
		print("[MatchManager] Elite Mob %s fully initialized with %d HP" % [elite.name, elite_hp])

func request_spawn_totem(player: BaseEntity, type: int) -> void:
	if not multiplayer.is_server(): return
	if not player.server_state or player.server_state.sync_souls <= 0: return
	
	var souls = player.server_state.sync_souls
	player.server_state.sync_souls = 0
	
	var totem = TOTEM_SCENE.instantiate()
	
	# Calculate position in front of player
	var forward = -player.global_transform.basis.z
	totem.global_position = player.global_position + (forward * 2.0)
	
	players_container.add_child(totem, true)
	totem.totem_type = type
	totem.stored_souls = souls
	
	totem.summoned.connect(func(p_type, p_souls): _on_totem_complete(player.name.to_int(), p_type, p_souls, totem.global_position))
	print("[MatchManager] Totem requested by ", player.name, " in front at ", totem.global_position)

func _on_totem_complete(owner_id: int, type: String, souls: int, pos: Vector3) -> void:
	var pet = PET_SCENE.instantiate()
	pet.global_position = pos
	pet.name = "PET_" + str(randi() % 1000) # Give it a name to distinguish it
	
	players_container.add_child(pet, true)
	
	if is_instance_valid(pet):
		pet.owner_id = owner_id
		pet.pet_type = type
		pet.power_level = souls
		
		# Force apply stats based on power_level (souls)
		var base_hp = 100 if type != "TANK" else 200
		var multiplier = 1.0 + (souls * 0.1)
		pet.apply_stats(int(base_hp * multiplier))
		
		# ADD AI Brain for Pet
		var ai = AI_COMPONENT.new()
		ai.name = "AIComponent"
		pet.add_child(ai)
		ai.state = 3 # State.FOLLOW_OWNER
		
		# Find owner node to follow
		var owner_node = players_container.get_node_or_null(str(owner_id))
		if owner_node:
			ai.owner_node = owner_node
			print("[MatchManager] Pet %s linked to owner %s" % [pet.name, owner_node.name])
		
		print("[MatchManager] Pet %s fully initialized with %d HP" % [pet.name, pet.max_health])


func _on_player_name_submitted(player_name: String) -> void:
	if multiplayer.is_server():
		peer_data[1] = {"name": player_name}
		# Update local host name immediately if already spawned
		var player = players_container.get_node_or_null("1")
		if player:
			player.player_name = player_name
	else:
		_pending_name = player_name
		# If already connected, send it now, otherwise wait for signal
		if multiplayer.multiplayer_peer and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			_submit_name_to_server.rpc_id(1, player_name)

func _on_connected_to_server() -> void:
	if not _pending_name.is_empty():
		_submit_name_to_server.rpc_id(1, _pending_name)
		_pending_name = ""

@rpc("any_peer", "reliable")
func _submit_name_to_server(player_name: String) -> void:
	var peer_id = multiplayer.get_remote_sender_id()
	print("[MatchManager] Received name from peer ", peer_id, ": ", player_name)
	peer_data[peer_id] = {"name": player_name}
	
	# If player already spawned, update their name
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		player.player_name = player_name

func _on_server_started() -> void:
	print("[MatchManager] Match started as server")
	# Spawn local player if not dedicated server
	if not GameManager._is_headless_environment():
		_spawn_player(1)

func _on_client_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client connected: ", peer_id)
	_spawn_player(peer_id)

func _on_client_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client disconnected: ", peer_id)
	_despawn_player(peer_id)
	peer_data.erase(peer_id)

func _spawn_player(peer_id: int) -> void:
	# Check if already spawned
	if players_container.has_node(str(peer_id)):
		return

	var player = PLAYER_SCENE.instantiate()
	player.name = str(peer_id)
	player.set_multiplayer_authority(peer_id)
	
	# Random position BEFORE adding to tree
	# We use 0.1 to be just slightly above ground and avoid stuck physics
	player.position = Vector3(randf_range(-5, 5), 0.1, randf_range(-5, 5))
	
	players_container.call_deferred("add_child", player, true)
	
	# Set name AFTER add_child — server_state is @onready and needs to be in tree
	if peer_data.has(peer_id):
		player.set_deferred("player_name", peer_data[peer_id]["name"])
	
	print("[MatchManager] Spawned player for peer: ", peer_id, " (", player.player_name, ") at ", player.position)

func _despawn_player(peer_id: int) -> void:
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()
		print("[MatchManager] Despawned player for peer: ", peer_id)
