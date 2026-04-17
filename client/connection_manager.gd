extends CanvasLayer

## Client connection UI and network management.
## Handles hosting and connecting to servers using Godot's multiplayer API and Noray relay/NAT punchthrough.

const DEFAULT_PORT = 7777

@onready var host_button: Button = $Panel/VBox/HostButton
@onready var connect_button: Button = $Panel/VBox/ConnectButton
@onready var address_edit: LineEdit = $Panel/VBox/AddressEdit
@onready var oid_edit: LineEdit = $Panel/VBox/OidEdit
@onready var name_edit: LineEdit = $Panel/VBox/NameEdit
@onready var status_label: Label = $Panel/VBox/StatusLabel
@onready var room_info_label: Label = $RoomInfo
@onready var main_panel: Panel = $Panel

var player_name: String = "Player"
var _active_peer: ENetMultiplayerPeer
var _is_host: bool = false
var _current_oid: String = ""

func _ready() -> void:
	host_button.pressed.connect(_on_host_pressed)
	connect_button.pressed.connect(_on_connect_pressed)
	
	name_edit.text = "Player_" + str(randi() % 1000)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	
	# Connect to Noray signals
	Noray.on_connect_nat.connect(_on_noray_connect_nat)
	Noray.on_connect_relay.connect(_on_noray_connect_relay)
	
	room_info_label.text = "Not Connected"

func _on_host_pressed() -> void:
	print("[DEBUG] Host button pressed")
	# Small safety delay to let the UI finish its click processing
	await get_tree().process_frame
	
	_is_host = false 
	player_name = name_edit.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"
	
	status_label.text = "Connecting to Noray Server..."
	var noray_addr = address_edit.text.strip_edges()
	print("[DEBUG] Connecting to Noray at: %s" % noray_addr)
	
	# Ensure Noray connection
	if not Noray.is_connected_to_host():
		var err = await Noray.connect_to_host(noray_addr)
		if err != OK:
			status_label.text = "Failed to connect to Noray: " + str(err)
			print("[ERROR] Noray connection failed: ", err)
			return
			
	status_label.text = "Requesting Dedicated Server..."
	print("[DEBUG] Requesting host from Noray...")
	Noray.request_host()
	
	print("[DEBUG] Waiting for Noray.on_host_ready signal...")
	var spawned_oid: String = await Noray.on_host_ready
	_current_oid = spawned_oid
	print("[DEBUG] Server ready, OID: %s" % spawned_oid)
	
	status_label.text = "Server Ready! Joining Room ID: " + spawned_oid
	oid_edit.text = spawned_oid
	room_info_label.text = "Room ID: " + spawned_oid
	
	# Wait for OID and PID to be fully registered before connecting
	status_label.text = "Registering as Client for NAT..."
	print("[DEBUG] Registering as host on Noray...")
	Noray.register_host()
	
	if Noray.oid.is_empty():
		print("[DEBUG] Waiting for OID signal...")
		await Noray.on_oid
	if Noray.pid.is_empty():
		print("[DEBUG] Waiting for PID signal...")
		await Noray.on_pid
		
	status_label.text = "Registering Remote Port..."
	print("[DEBUG] Registering remote port on Noray...")
	var err = await Noray.register_remote()
	if err != OK:
		status_label.text = "Failed to register port on Noray: " + str(err)
		print("[ERROR] Port registration failed: ", err)
		return
		
	status_label.text = "Requesting Connection to Dedicated Server..."
	print("[DEBUG] Connecting to NAT OID: %s" % spawned_oid)
	Noray.connect_nat(spawned_oid)

func _on_connect_pressed() -> void:
	_is_host = false
	player_name = name_edit.text.strip_edges()
	if player_name.is_empty():
		player_name = "Player"

	var room_id = oid_edit.text.strip_edges()
	if room_id.is_empty():
		status_label.text = "Room ID is required to connect."
		return
	
	_current_oid = room_id

	status_label.text = "Connecting to Noray Server..."
	
	# Ensure Noray connection
	if not Noray.is_connected_to_host():
		var err = await Noray.connect_to_host(address_edit.text.strip_edges())
		if err != OK:
			status_label.text = "Failed to connect to Noray"
			return
			
	status_label.text = "Registering as Host for NAT..."
	Noray.register_host()
	if Noray.oid.is_empty():
		await Noray.on_oid
	if Noray.pid.is_empty():
		await Noray.on_pid
		
	status_label.text = "Registering Remote Port..."
	var err = await Noray.register_remote()
	if err != OK:
		status_label.text = "Failed to register port on Noray"
		return
		
	status_label.text = "Requesting Connection to Room..."
	Noray.connect_nat(room_id)

func _on_noray_connect_nat(address: String, port: int) -> void:
	print("[ConnectionManager] Noray provided NAT address: ", address, ":", port)
	_connect_to_peer(address, port)

func _on_noray_connect_relay(address: String, port: int) -> void:
	print("[ConnectionManager] Noray provided Relay address: ", address, ":", port)
	_connect_to_peer(address, port)

func _connect_to_peer(address: String, port: int) -> void:
	if _is_host:
		# Host needs to handshake the incoming client to punch the hole
		status_label.text = "Handshaking client at " + address + ":" + str(port)
		if _active_peer:
			PacketHandshake.over_enet_peer(_active_peer, address, port)
		return
		
	status_label.text = "Connecting via ENet to " + address + ":" + str(port)
	
	_active_peer = ENetMultiplayerPeer.new()
	
	# Retry loop for ENet client creation (port might be in TIME_WAIT)
	var err = ERR_CONNECTION_ERROR
	var retries = 5
	while retries > 0:
		err = _active_peer.create_client(address, port, 0, 0, 0, Noray.local_port)
		if err == OK:
			break
		
		retries -= 1
		print("[ConnectionManager] Failed to create ENet client, retrying in 0.2s... (%d left)" % retries)
		await get_tree().create_timer(0.2).timeout

	if err != OK:
		status_label.text = "Failed to connect after retries: " + str(err)
		return

	multiplayer.multiplayer_peer = _active_peer
	
	# Perform handshake to punch through NAT
	if _active_peer:
		PacketHandshake.over_enet_peer(_active_peer, address, port)
	
	EventBus.player_name_submitted.emit(player_name)

func _on_peer_connected(peer_id: int) -> void:
	print("[ConnectionManager] Peer connected: ", peer_id)
	EventBus.client_connected.emit(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	print("[ConnectionManager] Peer disconnected: ", peer_id)
	EventBus.client_disconnected.emit(peer_id)

	# If we are the client and lost connection to the server (peer 1)
	if not multiplayer.is_server() and peer_id == 1:
		_show_menu()
		status_label.text = "Disconnected from server"
		room_info_label.text = "Disconnected"

func _on_connected_to_server() -> void:
	status_label.text = "Connected!"
	room_info_label.text = "Room ID: " + _current_oid
	EventBus.client_connected.emit(multiplayer.get_unique_id())
	_hide_menu()
	print("[ConnectionManager] Connected to server")

func _on_connection_failed() -> void:
	status_label.text = "Connection failed"
	room_info_label.text = "Failed"
	print("[ConnectionManager] Connection failed")
	_show_menu()

func _hide_menu() -> void:
	main_panel.visible = false
	# We don't disable process_mode anymore so we can still handle RoomInfo
	# and toggle menu back with Input

func _show_menu() -> void:
	main_panel.visible = true

func _input(event: InputEvent) -> void:
	var toggle_pressed = event.is_action_pressed("ui_cancel")

	if InputMap.has_action("toggle_menu"):
		toggle_pressed = toggle_pressed or event.is_action_pressed("toggle_menu")

	if toggle_pressed:
		if main_panel.visible:
			_hide_menu()
		else:
			_show_panel_manual() # Re-show panel

func _show_panel_manual() -> void:
	main_panel.visible = true
