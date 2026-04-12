extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")

@onready var players_container: Node3D = $Players

## Store peer data like names.
var peer_data: Dictionary = {}

func _ready() -> void:
	EventBus.server_started.connect(_on_server_started)
	EventBus.client_connected.connect(_on_client_connected)
	EventBus.client_disconnected.connect(_on_client_disconnected)
	EventBus.player_name_submitted.connect(_on_player_name_submitted)

func _on_player_name_submitted(player_name: String) -> void:
	if multiplayer.is_server():
		peer_data[1] = {"name": player_name}
	else:
		_submit_name_to_server.rpc_id(1, player_name)

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
	
	players_container.add_child(player, true)
	
	# Random position for now
	player.global_position = Vector3(randf_range(-5, 5), 1, randf_range(-5, 5))
	
	print("[MatchManager] Spawned player for peer: ", peer_id, " (", player.player_name, ")")

func _despawn_player(peer_id: int) -> void:
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		player.queue_free()
		print("[MatchManager] Despawned player for peer: ", peer_id)
