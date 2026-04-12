extends CanvasLayer

## Client connection UI and network management.
## Handles hosting and connecting to servers using Godot's multiplayer API.

const DEFAULT_PORT = 7777

@onready var host_button: Button = $Panel/VBox/HostButton
@onready var connect_button: Button = $Panel/VBox/ConnectButton
@onready var address_edit: LineEdit = $Panel/VBox/AddressEdit
@onready var name_edit: LineEdit = $Panel/VBox/NameEdit
@onready var status_label: Label = $Panel/VBox/StatusLabel

var player_name: String = "Player"

func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	connect_button.pressed.connect(_on_connect_pressed)
	
	# Load saved name if any (optional, let's keep it simple for now)
	name_edit.text = "Player_" + str(randi() % 1000)

	# Listen for network events
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func _on_host_pressed() -> void:
	player_name = name_edit.text.strip_edges()
	if player_name.is_empty():
		player_name = "Host"
	
	status_label.text = "Starting server..."

	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_server(DEFAULT_PORT)

	if err != OK:
		status_label.text = "Failed to host: " + str(err)
		return

	multiplayer.multiplayer_peer = peer
	EventBus.server_started.emit()
	EventBus.player_name_submitted.emit(player_name)
	_hide_menu()
	print("[ConnectionManager] Server started on port ", DEFAULT_PORT)

func _on_connect_pressed() -> void:
	player_name = name_edit.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"

	var address = address_edit.text.strip_edges()
	if address.is_empty():
		address = "localhost"

	status_label.text = "Connecting to " + address + "..."

	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(address, DEFAULT_PORT)

	if err != OK:
		status_label.text = "Failed to connect: " + str(err)
		return

	multiplayer.multiplayer_peer = peer
	EventBus.player_name_submitted.emit(player_name)

func _on_peer_connected(peer_id: int) -> void:
	print("[ConnectionManager] Peer connected: ", peer_id)
	EventBus.client_connected.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	print("[ConnectionManager] Peer disconnected: ", peer_id)
	EventBus.client_disconnected.emit(peer_id)

	# If we are the client and lost connection to the server (peer 1)
	# or if we are the host and something happened
	if not multiplayer.is_server() and peer_id == 1:
		_show_menu()
		status_label.text = "Disconnected from server"

func _on_connected_to_server() -> void:
	status_label.text = "Connected!"
	EventBus.client_connected.emit(multiplayer.get_unique_id())
	_hide_menu()
	print("[ConnectionManager] Connected to server")

func _on_connection_failed() -> void:
	status_label.text = "Connection failed"
	print("[ConnectionManager] Connection failed")
	_show_menu()

func _hide_menu() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_DISABLED

func _show_menu() -> void:
	visible = true
	process_mode = Node.PROCESS_MODE_INHERIT

func _input(event: InputEvent) -> void:
	var toggle_pressed = event.is_action_pressed("ui_cancel")

	if InputMap.has_action("toggle_menu"):
		toggle_pressed = toggle_pressed or event.is_action_pressed("toggle_menu")

	if toggle_pressed:
		if visible:
			_hide_menu()
		else:
			_show_menu()