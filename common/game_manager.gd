extends Node

## Centralized environment detection and networking initialization.
## Uses Netfox for server authority and client prediction.

const DEFAULT_PORT = 7777
const RAW_HEADLESS_BENCHMARK_SCENARIOS: Array[String] = ["A", "B", "C"]
const SERVER_MIN_FPS = 30
const SERVER_MAX_FPS = 60
const SERVER_MAX_FPS_ENV = "NOIKAR_SERVER_MAX_FPS"
var validated_room_creator_account_id := ""

func _ready() -> void:
	var server_frame_cap := _server_frame_cap_for_environment()
	if server_frame_cap > 0:
		Engine.max_fps = server_frame_cap
	if _is_headless_environment():
		_start_as_server()
	else:
		_start_as_client()

## Detect if running as a dedicated-server export or headless process.
## The dedicated_server feature is an export-only tag; editor runs start as
## clients unless they use a headless display server.
func _is_headless_environment() -> bool:
	if OS.has_feature("editor"):
		return DisplayServer.get_name() == "headless"
	return OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"

func _server_frame_cap_for_environment() -> int:
	return resolve_server_max_fps_override(OS.get_environment(SERVER_MAX_FPS_ENV), _is_headless_environment())

func resolve_server_max_fps_override(raw_value: String, is_server_runtime: bool) -> int:
	if not is_server_runtime:
		return 0
	var normalized_value := raw_value.strip_edges()
	if normalized_value.is_empty():
		return SERVER_MAX_FPS
	if not normalized_value.is_valid_int():
		return SERVER_MAX_FPS
	var requested_fps := normalized_value.to_int()
	if requested_fps < SERVER_MIN_FPS or requested_fps > SERVER_MAX_FPS:
		return SERVER_MAX_FPS
	return requested_fps

static func raw_headless_benchmark_scenario_from_args(args: Array, is_headless_runtime: bool) -> String:
	if not is_headless_runtime:
		return ""
	for arg in args:
		var text := str(arg).strip_edges()
		if text.begins_with("--benchmark="):
			var selected := text.replace("--benchmark=", "").strip_edges().to_upper()
			return selected if RAW_HEADLESS_BENCHMARK_SCENARIOS.has(selected) else ""
	return ""

func _start_as_server() -> void:
	var raw_benchmark_scenario := raw_headless_benchmark_scenario_from_args(OS.get_cmdline_user_args(), _is_headless_environment())
	if not raw_benchmark_scenario.is_empty():
		_start_raw_headless_benchmark_server(raw_benchmark_scenario)
		return

	print("[GameManager] Server environment starting. Connecting to Noray...")
	if DisplayServer.get_name() != "headless":
		print("[WARNING] DisplayServer is not headless, but we are a server. macOS may crash.")
	
	Noray.on_connect_nat.connect(_on_noray_connect_nat)
	Noray.on_connect_relay.connect(_on_noray_connect_relay)
	
	# In production the spawned server must reach noray through the VPS public
	# IP so noray learns a routable game address for clients; registering over
	# loopback would hand clients 127.0.0.1. Local dev defaults to loopback.
	var noray_host := OS.get_environment("NOIKAR_NORAY_HOST")
	if noray_host.is_empty():
		noray_host = "127.0.0.1"
	var err = await Noray.connect_to_host(noray_host)
	if err != OK:
		print("[GameManager] Failed to connect to Noray: ", err)
		return
		
	# The provisioning service forwards the backend-attested, single-use ticket
	# received with Noray's request-host command. It is validated before ENet
	# admission begins, so the raw account ID never crosses Noray.
	var provision_token = ""
	var room_creator_ticket = ""
	var provision_instance_id = ""
	var world_server_credential := OS.get_environment("NOIKAR_WORLD_SERVER_CREDENTIAL")
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--provision-token="):
			provision_token = arg.replace("--provision-token=", "")
		elif arg.begins_with("--room-creator-ticket="):
			room_creator_ticket = arg.replace("--room-creator-ticket=", "")
		elif arg.begins_with("--provision-instance-id="):
			provision_instance_id = arg.replace("--provision-instance-id=", "")
		elif arg.begins_with("--world-server-credential="):
			world_server_credential = arg.replace("--world-server-credential=", "")
	
	if not provision_token.is_empty():
		if room_creator_ticket.is_empty() or provision_instance_id.is_empty() or world_server_credential.is_empty():
			push_error("[GameManager] Refusing provisioned room without ticket, instance binding, or world credential")
			return
		var ticket_identity: Dictionary = await AuthService.validate_room_creator_ticket(room_creator_ticket, provision_instance_id, world_server_credential)
		if not ticket_identity.get("accepted", false):
			push_error("[GameManager] Refusing invalid, expired, or replayed creator ticket")
			return
		validated_room_creator_account_id = str(ticket_identity["account_id"])
		EventBus.room_creator_ticket_validated.emit(validated_room_creator_account_id)
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

func _start_raw_headless_benchmark_server(scenario: String) -> void:
	print("[GameManager] Raw headless benchmark %s starting local ENet server on default port %d" % [scenario, DEFAULT_PORT])
	if DisplayServer.get_name() != "headless":
		print("[WARNING] DisplayServer is not headless, but raw benchmark server bootstrap was requested.")
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(DEFAULT_PORT)
	if err != OK:
		print("[GameManager] Failed to host raw benchmark ENet server: ", err)
		return
	multiplayer.call_deferred("set_multiplayer_peer", peer)
	print("[GameManager] RAW HEADLESS BENCHMARK SERVER STARTED")
	EventBus.call_deferred("emit_signal", "server_started")

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
