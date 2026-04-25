extends CanvasLayer

## Modern Connection Manager with Lobby flow.
## Handles states: LOGIN -> LOBBY -> CONNECTING -> IN_GAME

const DEFAULT_PORT = 7777

# --- UI References ---
@onready var login_panel: Control = $LoginPanel
@onready var lobby_panel: Control = $LobbyPanel
@onready var connecting_panel: Control = $ConnectingPanel
@onready var bg_rect: ColorRect = $Background

@onready var name_edit: LineEdit = $LoginPanel/VBox/NameEdit
@onready var status_label: Label = $ConnectingPanel/VBox/StatusLabel
@onready var room_id_edit: LineEdit = $LobbyPanel/VBox/JoinBox/VBox/RoomIDEdit
@onready var noray_address_edit: LineEdit = $LobbyPanel/VBox/SettingsBox/AddressEdit
@onready var room_info: Label = $HUD/RoomInfo

# --- State ---
var player_name: String = "Player"
var _active_peer: ENetMultiplayerPeer
var _is_host: bool = false
var _current_oid: String = ""

enum State { LOGIN, LOBBY, CONNECTING, IN_GAME }
var current_state: State = State.LOGIN

func _ready() -> void:
	# Signal connections
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	Noray.on_connect_nat.connect(_on_noray_connect_nat)
	Noray.on_connect_relay.connect(_on_noray_connect_relay)
	
	# Initial Setup
	name_edit.text = "Player_" + str(randi() % 1000)
	_switch_state(State.LOGIN)
	
	# Background animation (Subtle pulse)
	var tween = create_tween().set_loops()
	tween.tween_property(bg_rect, "color", Color("1a1a2e"), 4.0)
	tween.tween_property(bg_rect, "color", Color("16213e"), 4.0)

func _switch_state(new_state: State) -> void:
	current_state = new_state

	match new_state:
		State.LOGIN:
			bg_rect.visible = true
			login_panel.visible = true
			lobby_panel.visible = false
			connecting_panel.visible = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		State.LOBBY:
			bg_rect.visible = true
			login_panel.visible = false
			lobby_panel.visible = true
			connecting_panel.visible = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		State.CONNECTING:
			bg_rect.visible = true
			login_panel.visible = false
			lobby_panel.visible = true 
			connecting_panel.visible = true
		State.IN_GAME:
			bg_rect.visible = false # HIDE BLUE BACKGROUND
			login_panel.visible = false
			lobby_panel.visible = false
			connecting_panel.visible = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

# --- UI Actions ---

func _on_enter_lobby_pressed() -> void:
	player_name = name_edit.text.strip_edges()
	if player_name.is_empty(): player_name = "Player"
	_switch_state(State.LOBBY)

func _on_host_pressed() -> void:
	# In this project, "Host" means requesting a dedicated server and joining it.
	# So _is_host is false because WE are still a client of that spawned server.
	_is_host = false 
	_start_noray_flow(true)

func _on_join_pressed() -> void:
	var room_id = room_id_edit.text.strip_edges()
	if room_id.is_empty():
		return
	_current_oid = room_id
	_is_host = false
	_start_noray_flow(false)

# --- Networking Flow ---

func _start_noray_flow(as_host: bool) -> void:
	_switch_state(State.CONNECTING)
	status_label.text = "Conectando a Noray..."
	
	var noray_addr = noray_address_edit.text.strip_edges()
	if noray_addr.is_empty(): noray_addr = "127.0.0.1"
	
	if not Noray.is_connected_to_host():
		var err = await Noray.connect_to_host(noray_addr)
		if err != OK:
			_fail_connection("Error Noray: " + str(err))
			return

	if as_host:
		status_label.text = "Solicitando Servidor Dedicado..."
		Noray.request_host()
		_current_oid = await Noray.on_host_ready
		status_label.text = "Servidor Listo! ID: " + _current_oid
	
	status_label.text = "Registrando puerto NAT..."
	Noray.register_host()
	if Noray.oid.is_empty(): await Noray.on_oid
	if Noray.pid.is_empty(): await Noray.on_pid
	
	var reg_err = await Noray.register_remote()
	if reg_err != OK:
		_fail_connection("Error Registro Puerto")
		return
		
	status_label.text = "Abriendo túnel hacia " + _current_oid + "..."
	Noray.connect_nat(_current_oid)

func _fail_connection(msg: String) -> void:
	status_label.text = msg
	await get_tree().create_timer(3.0).timeout
	if current_state == State.CONNECTING:
		_switch_state(State.LOBBY)

# --- Noray Callbacks ---

func _on_noray_connect_nat(address: String, port: int) -> void:
	_connect_to_peer(address, port)

func _on_noray_connect_relay(address: String, port: int) -> void:
	_connect_to_peer(address, port)

func _connect_to_peer(address: String, port: int) -> void:
	if _is_host:
		# This case is only if we are the ACTUAL server (not used in this UI flow)
		status_label.text = "Handshaking client..."
		if _active_peer: PacketHandshake.over_enet_peer(_active_peer, address, port)
		return

	status_label.text = "Iniciando ENet client..."
	_active_peer = ENetMultiplayerPeer.new()
	
	# RESTORE RETRY LOOP (Crucial for NAT stability)
	var err = ERR_CONNECTION_ERROR
	var retries = 5
	while retries > 0:
		err = _active_peer.create_client(address, port, 0, 0, 0, Noray.local_port)
		if err == OK: break
		retries -= 1
		status_label.text = "Reintentando ENet... (" + str(retries) + ")"
		await get_tree().create_timer(0.2).timeout
	
	if err != OK:
		_fail_connection("Error ENet tras reintentos")
		return

	multiplayer.multiplayer_peer = _active_peer
	PacketHandshake.over_enet_peer(_active_peer, address, port)
	
	# Emit name to server
	EventBus.player_name_submitted.emit(player_name)

# --- Multiplayer Callbacks ---

func _on_connected_to_server() -> void:
	_switch_state(State.IN_GAME)
	room_info.text = "SALA: " + _current_oid
	EventBus.client_connected.emit(multiplayer.get_unique_id())

func _on_connection_failed() -> void:
	_fail_connection("Conexión al servidor fallida")

func _on_peer_connected(id: int) -> void:
	EventBus.client_connected.emit(id)

func _on_peer_disconnected(id: int) -> void:
	EventBus.client_disconnected.emit(id)
	if id == 1: 
		_switch_state(State.LOBBY)
		status_label.text = "Desconectado del servidor"

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_menu"):
		if current_state == State.IN_GAME:
			_switch_state(State.LOBBY)
		elif current_state == State.LOBBY:
			_switch_state(State.IN_GAME)
