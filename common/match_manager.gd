extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")

@onready var players_container: Node3D = $Players

## Store peer data like names.
var peer_data: Dictionary = {}
var _pending_name: String = ""

func _ready() -> void:
	EventBus.server_started.connect(_on_server_started)
	EventBus.client_connected.connect(_on_client_connected)
	EventBus.client_disconnected.connect(_on_client_disconnected)
	EventBus.player_name_submitted.connect(_on_player_name_submitted)
	EventBus.entity_died.connect(_on_entity_died)
	
	# Listen for successful connection to send pending data
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func _on_entity_died(entity: Node3D) -> void:
	if not multiplayer.is_server(): return
	
	print("[MatchManager] Entity died: ", entity.name, ". Respawning in 3 seconds...")
	
	# Wait for respawn
	await get_tree().create_timer(3.0).timeout
	
	if is_instance_valid(entity) and entity.has_method("respawn"):
		# CALCULATE POSITION ONLY HERE
		var random_pos = Vector3(randf_range(-10, 10), 0.1, randf_range(-10, 10))
		print("[MatchManager] Respawning ", entity.name, " at ", random_pos)
		entity.respawn(random_pos)

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
	
	# Set name if we have it
	if peer_data.has(peer_id):
		player.player_name = peer_data[peer_id]["name"]
	
	# Random position BEFORE adding to child
	# We use 0.1 to be just slightly above ground and avoid stuck physics
	player.position = Vector3(randf_range(-5, 5), 0.1, randf_range(-5, 5))
	
	players_container.add_child(player, true)
	
	print("[MatchManager] Spawned player for peer: ", peer_id, " (", player.player_name, ") at ", player.position)

func _despawn_player(peer_id: int) -> void:
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()
		print("[MatchManager] Despawned player for peer: ", peer_id)
