extends Node

## Centralized environment detection and networking initialization.
## Uses Netfox for server authority and client prediction.

const DEFAULT_PORT = 7777

func _ready() -> void:
	if _is_headless_environment():
		_start_as_server()
	else:
		_start_as_client()

## Detect if running as a dedicated server or headless.
func _is_headless_environment() -> bool:
	return OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"

func _start_as_server() -> void:
	print("[GameManager] Server environment starting. Connecting to Noray...")
	Noray.on_connect_nat.connect(_on_noray_connect_nat)
	Noray.on_connect_relay.connect(_on_noray_connect_relay)
	
	var err = await Noray.connect_to_host("127.0.0.1")
	if err != OK:
		print("[GameManager] Failed to connect to Noray: ", err)
		return
		
	# Parse provision token from command line if spawned by Noray
	var provision_token = ""
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--provision-token="):
			provision_token = arg.replace("--provision-token=", "")
	
	if not provision_token.is_empty():
		print("[GameManager] Registering Spawned Server with token: ", provision_token)
		Noray.register_server(provision_token)
	else:
		print("[GameManager] Registering Host manually...")
		Noray.register_host()
	
	if Noray.oid.is_empty():
		await Noray.on_oid
	if Noray.pid.is_empty():
		await Noray.on_pid
		
	print("[GameManager] Registering Remote Port (with retries)...")
	var retries = 3
	while retries > 0:
		err = await Noray.register_remote()
		if err == OK:
			break
		retries -= 1
		print("[GameManager] Failed to register port, retrying... (%d left)" % retries)
		await get_tree().create_timer(1.0).timeout
		
	# Final server initialization
	var port = Noray.local_port
	var peer = ENetMultiplayerPeer.new()

	print("[GameManager] Creating ENet server on port: %d" % port)
	err = peer.create_server(port)

	if err != OK:
		print("[GameManager] Failed to host ENet server: ", err)
		return

	# CRITICAL: In some Godot 4.x versions, setting the peer immediately 
	# can cause a crash if the scene tree is still busy.
	multiplayer.call_deferred("set_multiplayer_peer", peer)

	print("[GameManager] SERVER STARTED SUCCESSFULLY")
	EventBus.call_deferred("emit_signal", "server_started")
	if not provision_token.is_empty():
		print("[GameManager] Notifying backend that server is ready...")
		Noray.server_ready()
		
	print("==================================================")
	print("[GameManager] HEADLESS SERVER READY")
	print("[GameManager] ROOM ID (OID): ", Noray.oid)
	print("==================================================")

func _on_noray_connect_nat(address: String, port: int) -> void:
	if multiplayer.is_server():
		print("[GameManager] Handshaking client at ", address, ":", port)
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			PacketHandshake.over_enet_peer(multiplayer.multiplayer_peer as ENetMultiplayerPeer, address, port)

func _on_noray_connect_relay(address: String, port: int) -> void:
	if multiplayer.is_server():
		print("[GameManager] Handshaking relay client at ", address, ":", port)
		if multiplayer.multiplayer_peer is ENetMultiplayerPeer:
			PacketHandshake.over_enet_peer(multiplayer.multiplayer_peer as ENetMultiplayerPeer, address, port)

func _start_as_client() -> void:
	# Client shows connection UI
	# The actual connection is handled by ConnectionManager
	EventBus.client_ready.emit()
	print("[GameManager] Client environment ready")