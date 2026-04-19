extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")
const SOUL_SCENE = preload("res://scenes/SoulEntity.tscn")

@onready var players_container: Node3D = $Players

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
	add_child(soul, true)
	soul.global_position = pos
	
	soul.expired.connect(func(): _on_soul_expired(pos))

func _on_soul_expired(pos: Vector3) -> void:
	# 40% chance is already handled by SoulEntity emitting expired ONLY if it decides to try respawn
	# Actually, let's move the 40% chance here for cleaner management
	if randf() < 0.4:
		print("[MatchManager] SOUL EXPIRED - Spawning ELITE MOB at ", pos)
		_spawn_elite_mob(pos)

func _spawn_elite_mob(pos: Vector3) -> void:
	var dummy_scene = load("res://scenes/TrainingDummy.tscn")
	var elite = dummy_scene.instantiate()
	add_child(elite, true)
	elite.global_position = pos
	elite.name = "ELITE_" + str(randi() % 1000)
	
	# Set elite stats (wait a frame for components to initialize)
	await get_tree().process_frame
	if elite.has_node("ServerState"):
		var state = elite.get_node("ServerState")
		state.max_health = 200
		state.sync_health = 200
	if elite.has_node("CombatComponent"):
		elite.get_node("CombatComponent").damage = 25
	
	print("[MatchManager] Elite Mob spawned with 200HP / 25DMG")

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
