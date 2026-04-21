extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")
const SOUL_SCENE = preload("res://scenes/SoulEntity.tscn")
const TOTEM_SCENE = preload("res://scenes/TotemEntity.tscn")
const PET_SCENE = preload("res://scenes/PetEntity.tscn")
const DUMMY_SCENE = preload("res://scenes/TrainingDummy.tscn")
const AI_COMPONENT = preload("res://core/AIComponent.gd")

@onready var players_container: Node3D = $Players

# --- CONFIGURATION: ELITE MOBS ---
@export var elite_respawn_chance: float = 0.4
@export var elite_hp_multiplier: float = 2.5
@export var elite_damage_multiplier: float = 1.6
# --- CONFIGURATION: SERVER AUTO-CLOSE ---
@export var shutdown_delay: float = 30.0 # Wait 30s before closing empty room
# ---------------------------------

var _shutdown_timer: SceneTreeTimer = null

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

func _on_server_started() -> void:
	print("[MatchManager] Match started as server")
	# Spawn local player if not headless
	if not GameManager._is_headless_environment():
		_spawn_player(1)

func _on_client_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client connected: ", peer_id)
	_spawn_player(peer_id)
	_shutdown_timer = null # Reset timer on join

func _on_client_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client disconnected: ", peer_id)
	_despawn_player(peer_id)
	peer_data.erase(peer_id)
	
	# Wait a frame to ensure queue_free() is processed or use robust check
	_check_for_empty_server.call_deferred()

func _check_for_empty_server() -> void:
	if not multiplayer.is_server(): return
	
	# Count human players (nodes with numeric names in Players container)
	var human_count = 0
	for child in players_container.get_children():
		# IMPORTANT: ignore nodes about to be destroyed
		if child.name.is_valid_int() and not child.is_queued_for_deletion():
			human_count += 1
	
	print("[MatchManager] Human player count: ", human_count)
	
	if human_count == 0:
		if _shutdown_timer == null:
			print("[MatchManager] Server is empty. Starting shutdown timer (%ds)..." % shutdown_delay)
			_shutdown_timer = get_tree().create_timer(shutdown_delay)
			_shutdown_timer.timeout.connect(_auto_shutdown)
	elif _shutdown_timer:
		print("[MatchManager] Player joined. Aborting shutdown.")
		_shutdown_timer = null

func _auto_shutdown() -> void:
	# Double check count before actually quitting
	var human_count = 0
	if is_instance_valid(players_container):
		for child in players_container.get_children():
			if child.name.is_valid_int():
				human_count += 1
			
	if human_count == 0:
		print("[MatchManager] ROOM EMPTY. SHUTTING DOWN SERVER TO SAVE RESOURCES.")
		get_tree().quit()

func _on_connected_to_server() -> void:
	if not _pending_name.is_empty():
		_submit_name_to_server.rpc_id(1, _pending_name)

func _on_player_name_submitted(player_name: String) -> void:
	_pending_name = player_name
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
		_submit_name_to_server.rpc_id(1, player_name)

@rpc("any_peer", "call_local", "reliable")
func _submit_name_to_server(player_name: String) -> void:
	var peer_id = multiplayer.get_remote_sender_id()
	print("[MatchManager] Received name from peer ", peer_id, ": ", player_name)
	peer_data[peer_id] = {"name": player_name}
	
	if multiplayer.is_server():
		# Update player if already exists
		var player = players_container.get_node_or_null(str(peer_id))
		if player and player.has_node("ServerState"):
			player.get_node("ServerState").player_name = player_name

func _on_entity_died(entity: Node3D) -> void:
	if not multiplayer.is_server(): return
	
	# Only mobs (Dummies, Elites) and NOT players or Pets spawn souls
	var is_player = entity.name.is_valid_int()
	var is_pet = entity.name.begins_with("PET")
	
	if not is_player and not is_pet:
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
	var elite = DUMMY_SCENE.instantiate()
	
	elite.name = "ELITE_" + str(randi() % 1000)
	elite.global_position = pos
	
	players_container.add_child(elite, true)
	
	# INITIALIZE AI AND STATS (Deferred to ensure _ready is done)
	_setup_elite_logic.call_deferred(elite)

func _setup_elite_logic(elite: Node3D) -> void:
	if not is_instance_valid(elite): return
	
	var elite_hp = int(100 * elite_hp_multiplier)
	if elite.has_method("apply_stats"):
		elite.apply_stats(elite_hp)
	
	if elite.has_node("CombatComponent"):
		elite.get_node("CombatComponent").damage = int(15 * elite_damage_multiplier)
	
	# ADD AI Brain
	var ai = AI_COMPONENT.new()
	ai.name = "AIComponent"
	elite.add_child(ai)
	ai.state = 1 # State.CHASE
	
	print("[MatchManager] Elite Mob %s initialized with %d HP" % [elite.name, elite_hp])

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
	
	totem.summoned.connect(func(p_type: int, p_souls: int): 
		_on_totem_complete(player.name.to_int(), p_type, p_souls, totem.global_position)
	)
	print("[MatchManager] Totem requested by ", player.name, " in front at ", totem.global_position)

func _on_totem_complete(owner_id: int, type_int: int, souls: int, pos: Vector3) -> void:
	var pet = PET_SCENE.instantiate()
	pet.name = "PET_" + str(randi() % 1000) # Give it a name to distinguish it
	pet.global_position = pos
	
	players_container.add_child(pet, true)
	_setup_pet_logic.call_deferred(pet, owner_id, type_int, souls)

func _setup_pet_logic(pet: Node3D, owner_id: int, type_int: int, souls: int) -> void:
	if not is_instance_valid(pet): return
	
	var type_str = "ATTACK"
	match type_int:
		0: type_str = "ATTACK"
		1: type_str = "TANK"
		2: type_str = "HEAL"
	
	pet.owner_id = owner_id
	pet.pet_type = type_str
	pet.power_level = souls
	
	# Force apply stats based on power_level (souls)
	var base_hp = 100
	if type_str == "TANK": base_hp = 250
	elif type_str == "HEAL": base_hp = 80
	
	var multiplier = 1.0 + (souls * 0.1)
	if pet.has_method("apply_stats"):
		pet.apply_stats(int(base_hp * multiplier))
	
	# ADD AI Brain for Pet
	var ai = AI_COMPONENT.new()
	ai.name = "AIComponent"
	pet.add_child(ai)
	
	if type_str == "HEAL":
		ai.state = 3 # State.FOLLOW_OWNER
	else:
		ai.state = 1 # State.CHASE (Will switch to follow if no targets, handled in AI)
	
	# Find owner node to follow
	var owner_node = players_container.get_node_or_null(str(owner_id))
	if owner_node:
		ai.owner_node = owner_node
		print("[MatchManager] Pet %s (%s) linked to owner %s" % [pet.name, type_str, owner_node.name])
	
	# Ensure authority is correct for AI to run on server
	pet.set_multiplayer_authority(1)
	
	print("[MatchManager] Pet %s fully initialized with %d HP" % [pet.name, pet.get("max_health") if pet.get("max_health") else 0])

func _spawn_player(peer_id: int) -> void:
	# Check if already spawned
	if players_container.has_node(str(peer_id)):
		return
		
	var player = PLAYER_SCENE.instantiate()
	player.name = str(peer_id)
	
	# Spawn at a safe position (away from dummies)
	var spawn_pos = Vector3(randf_range(-5, 5), 0.5, randf_range(5, 10))
	player.global_position = spawn_pos
	
	players_container.add_child(player, true)
	
	# Initial server-side state setup
	if multiplayer.is_server():
		# Setup name from peer data if available
		if peer_data.has(peer_id):
			player.player_name = peer_data[peer_id].name
		
	print("[MatchManager] Spawned player for peer: ", peer_id, " at ", player.position)

func _despawn_player(peer_id: int) -> void:
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()
		print("[MatchManager] Despawned player for peer: ", peer_id)
