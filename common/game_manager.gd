extends Node

## Centralized environment detection and networking initialization.
## Uses Netfox for server authority and client prediction.

const DEFAULT_PORT = 7777
const RAW_HEADLESS_BENCHMARK_SCENARIOS: Array[String] = ["A", "B", "C"]
const SERVER_MIN_FPS = 30
const SERVER_MAX_FPS = 60
const SERVER_MAX_FPS_ENV = "NOIKAR_SERVER_MAX_FPS"
var validated_room_creator_account_id := ""
var session: Node
var steam: Node
var editor_playtest: Node
var _runtime_role := "MENU"
enum BootstrapMode { NORMAL, TEST, REJECTED }

static func runtime_role_for(args: Array, dedicated_export: bool, benchmark_client: bool) -> String:
	if dedicated_export or args.has("--server") or args.has("--dedicated"):
		return "DEDICATED"
	if args.has("--client") or benchmark_client:
		return "CLIENT"
	return "MENU"

func _ensure_session() -> void:
	if session != null: return
	session = load("res://common/net/session_service.gd").new()
	session.name = "Session"
	session._world_cleanup = _reset_session_world
	add_child(session)
	EventBus.player_admission_ticket_submitted.connect(session.submit_admission_ticket)

func ensure_steam() -> Node:
	if steam != null: return steam
	steam = load("res://common/net/steam_transport.gd").new()
	steam.name = "SteamTransport"
	steam.configure(session, AuthService)
	steam.host_ready.connect(_admit_steam_host)
	add_child(steam)
	# Tests and dedicated servers never initialize the user's Steam client.
	if should_auto_initialize_steam(OS.get_environment("NOIKAR_TEST_MODE") == "1" or OS.get_environment("NOIKAR_ISOLATED_AUTH_API") == "1", is_dedicated_runtime(), editor_playtest != null, Engine.has_singleton("Steam")):
		steam.initialize()
	steam.accept_launch_invite(OS.get_cmdline_args() + OS.get_cmdline_user_args())
	return steam

static func should_auto_initialize_steam(test_bootstrap: bool, dedicated: bool, vps_test: bool, available: bool) -> bool:
	return available and not test_bootstrap and not dedicated and not vps_test

func _admit_steam_host(identity: Dictionary) -> void:
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	if manager == null or not manager.admit_local_host(identity):
		session.close("Could not admit the local host")
		return
	session.peer_admitted.emit(1, identity)
	EventBus.game_server_authenticated.emit(str(identity.username))

func _reset_session_world() -> void:
	var tree := get_tree()
	var world := tree.current_scene
	if world == null or world.scene_file_path != "res://scenes/main.tscn": return
	validated_room_creator_account_id = ""
	var error := tree.reload_current_scene()
	if error != OK:
		push_error("Could not reset the session world")
		return
	await tree.scene_changed

func is_dedicated_runtime() -> bool:
	return _runtime_role == "DEDICATED" or (session != null and session.role == "DEDICATED")

func should_present_world() -> bool:
	return not is_dedicated_runtime()

func host_player_lan(port: int) -> Dictionary:
	var attempt: int = session.begin_attempt()
	if attempt < 0: return {"accepted": false, "reason": "A session is already active"}
	var created: Dictionary = await AuthService.create_listen_room(session.session_id)
	if not session.is_attempt_current(attempt):
		if created.get("accepted", false): AuthService.close_listen_room(created.room_id, created.room_credential)
		return {"accepted": false, "reason": "Room creation cancelled"}
	if not created.get("accepted", false):
		session.close(str(created.get("reason", "Could not create a room")))
		return {"accepted": false, "reason": str(created.get("reason", "Could not create a room"))}
	session.configure_room(created.room_id, created.room_credential)
	var error: int = session.host_lan(port, created.host_identity)
	if error != OK:
		session.close("Could not listen on the selected port")
		return {"accepted": false, "reason": "Could not listen on the selected port"}
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	if manager == null or not manager.admit_local_host(created.host_identity):
		session.close("Could not admit the local host")
		return {"accepted": false, "reason": "Could not admit the local host"}
	session.peer_admitted.emit(1, created.host_identity)
	EventBus.game_server_authenticated.emit(str(created.host_identity.username))
	return {"accepted": true, "room_id": str(created.room_id)}

func join_player_lan(address: String, port: int, room_id: String) -> Dictionary:
	var attempt: int = session.begin_attempt()
	if attempt < 0: return {"accepted": false, "reason": "A session is already active"}
	var proof: Dictionary = await AuthService.issue_listen_ticket(room_id)
	if not session.is_attempt_current(attempt): return {"accepted": false, "reason": "Room join cancelled"}
	if not proof.get("accepted", false):
		session.close("Could not obtain room admission")
		return {"accepted": false, "reason": "Could not obtain room admission"}
	session.configure_room(room_id)
	if session.join_lan(address, port) != OK:
		session.close("Could not start the LAN connection")
		return {"accepted": false, "reason": "Could not start the LAN connection"}
	return {"accepted": true, "ticket": str(proof.ticket)}

func host_editor_vps() -> Dictionary:
	if editor_playtest == null or not editor_playtest.ready_for_login(): return {"accepted": false, "reason": "The secure VPS test connection is not ready"}
	var attempt: int = session.begin_attempt()
	if attempt < 0: return {"accepted": false, "reason": "A session is already active"}
	var created: Dictionary = await AuthService.create_listen_room(session.session_id)
	if not session.is_attempt_current(attempt):
		if created.get("accepted", false): AuthService.close_listen_room(created.room_id, created.room_credential)
		return {"accepted": false, "reason": "VPS room creation cancelled"}
	if not created.get("accepted", false) or int(created.get("game_port", 0)) != 24580:
		if created.get("accepted", false): AuthService.close_listen_room(created.room_id, created.room_credential)
		session.close(str(created.get("reason", "The isolated VPS room did not become ready")))
		return {"accepted": false, "reason": str(created.get("reason", "The isolated VPS room did not become ready"))}
	session.configure_room(created.room_id, created.room_credential)
	var proof: Dictionary = await AuthService.issue_listen_ticket(created.room_id)
	if not session.is_attempt_current(attempt): return {"accepted": false, "reason": "VPS room join cancelled"}
	if not proof.get("accepted", false):
		session.close("Could not obtain VPS admission")
		return {"accepted": false, "reason": "Could not obtain VPS admission"}
	session.pending_admission_ticket = str(proof.ticket)
	if session.join_lan(editor_playtest.game_host, 24580) != OK:
		session.close("Could not connect to the isolated VPS world")
		return {"accepted": false, "reason": "Could not connect to the isolated VPS world"}
	return {"accepted": true, "room_id": str(created.room_id)}

static func bootstrap_mode_for(args: Array, debug_build: bool) -> int:
	if not args.has("--noikar-test-mode"):
		return BootstrapMode.NORMAL
	return BootstrapMode.TEST if debug_build else BootstrapMode.REJECTED

func _ready() -> void:
	var bootstrap_args: Array = Array(OS.get_cmdline_user_args())
	# GUT rejects unknown application CLI options; its runner uses the same
	# debug-only isolation policy through a child-process environment variable.
	if OS.get_environment("NOIKAR_TEST_MODE") == "1":
		bootstrap_args.append("--noikar-test-mode")
	var bootstrap_mode := bootstrap_mode_for(bootstrap_args, OS.is_debug_build())
	if bootstrap_mode == BootstrapMode.REJECTED:
		printerr("Test bootstrap is unavailable in production exports.")
		get_tree().quit(64)
		return
	_ensure_session()
	if bootstrap_mode == BootstrapMode.TEST:
		return
	_runtime_role = runtime_role_for(Array(OS.get_cmdline_args()) + Array(OS.get_cmdline_user_args()), OS.has_feature("dedicated_server"), BenchmarkProfile.headless_client)
	if not BenchmarkProfile.valid:
		get_tree().quit(64)
		return
	if not BenchmarkProfile.selected_profile.is_empty():
		# All autoload constructors must finish before checking cached Netfox values.
		_start_profiled_runtime.call_deferred()
		return
	var server_frame_cap := _server_frame_cap_for_environment()
	if server_frame_cap > 0:
		Engine.max_fps = server_frame_cap
	if is_dedicated_runtime():
		_start_as_server()
	else:
		_start_as_client()

func _start_profiled_runtime() -> void:
	var is_server := is_dedicated_runtime()
	if not BenchmarkProfile.before_network_start(is_server):
		return
	if is_server:
		_start_as_server()
	else:
		_start_as_client()

## Detect if running as a dedicated-server export or headless process.
## The dedicated_server feature is an export-only tag; editor runs start as
## clients unless they use a headless display server.
static func server_role_for_display(headless: bool, dedicated: bool, benchmark_client: bool) -> bool:
	return dedicated or (headless and not benchmark_client)

func _is_headless_environment() -> bool:
	# The legacy helper is a presentation query, never listen-host authority.
	if session != null and session.role in ["LISTEN_HOST", "CLIENT"]:
		return false
	if _runtime_role == "CLIENT": return false
	if is_dedicated_runtime(): return true
	# A validated benchmark headless CLIENT retains normal client scene/controllers.
	if BenchmarkProfile.valid and BenchmarkProfile.headless_client:
		return server_role_for_display(DisplayServer.get_name() == "headless", OS.has_feature("dedicated_server"), true)
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
	if OS.get_cmdline_user_args().has("--vps-playtest-server"):
		_start_vps_playtest_server()
		return
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
	var err = await Noray.connect_to_host(noray_host, 24691) if BenchmarkProfile.remote_transport else await Noray.connect_to_host(noray_host)
	if err != OK:
		print("[GameManager] Failed to connect to Noray: ", err)
		return
		
	# The provisioning service forwards the backend-attested, single-use ticket
	# received with Noray's request-host command. It is validated before ENet
	# admission begins, so the raw account ID never crosses Noray.
	var provision_token = OS.get_environment("NOIKAR_PROVISION_TOKEN") if BenchmarkProfile.remote_transport else ""
	var room_creator_ticket = OS.get_environment("NOIKAR_ROOM_CREATOR_TICKET") if BenchmarkProfile.remote_transport else ""
	var provision_instance_id = OS.get_environment("NOIKAR_PROVISION_INSTANCE_ID") if BenchmarkProfile.remote_transport else ""
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
	
	if BenchmarkProfile.remote_transport and provision_token.is_empty():
		push_error("[GameManager] Benchmark remote room requires normal creator provisioning")
		return
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
		if BenchmarkProfile.remote_transport:
			print("[GameManager] Registering creator-bound benchmark server")
		else:
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
		err = await Noray.register_remote(24693, 8, 0.1, 24690) if BenchmarkProfile.remote_transport else await Noray.register_remote()
		if err == OK:
			break
		retries -= 1
		print("[GameManager] Failed to register port, retrying... (%d left)" % retries)
		await get_tree().create_timer(1.0).timeout
		
	if BenchmarkProfile.remote_transport and err != OK:
		push_error("[GameManager] Benchmark remote UDP registration failed")
		return
	# Final server initialization
	var port = Noray.local_port
	var peer = ENetMultiplayerPeer.new()

	print("[GameManager] Creating ENet server on port: %d" % port)
	err = peer.create_server(port, BenchmarkProfile.player_limit) if BenchmarkProfile.player_limit in [10, 20] else peer.create_server(port)

	if err != OK:
		print("[GameManager] Failed to host ENet server: ", err)
		return

	if BenchmarkProfile.remote_transport:
		printerr("[PROFILE_TRANSPORT] " + JSON.stringify({"server_bind_port": port, "enet_error": int(err), "creator_ticket_validated": not validated_room_creator_account_id.is_empty()}))
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

func _start_vps_playtest_server() -> void:
	# Isolated debug deployment only. Normal dedicated/prod startup is unchanged.
	var raw := OS.get_environment("NOIKAR_VPS_PLAYTEST_BOOTSTRAP")
	OS.set_environment("NOIKAR_VPS_PLAYTEST_BOOTSTRAP", "")
	var data = JSON.parse_string(raw) if raw.length() <= 2048 else null
	if not OS.is_debug_build() or not is_dedicated_runtime() or not data is Dictionary or data.size() != 4 or not data.get("host_identity") is Dictionary or not session._valid_identity(data.host_identity) or not data.get("room_id") is String or data.room_id.is_empty() or not data.get("room_credential") is String or len(data.room_credential) < 32 or not (data.get("port") is int or data.get("port") is float) or int(data.port) != 24580:
		printerr("Invalid isolated VPS room bootstrap")
		get_tree().quit(64)
		return
	validated_room_creator_account_id = str(data.host_identity.account_id)
	session.configure_room(str(data.room_id), str(data.room_credential))
	session.peer_admitted.connect(func(_id, _identity): print("VPS_PLAYTEST_ADMITTED"))
	# Let the existing main scene install its roster/spawners before authority starts.
	await get_tree().process_frame
	var endpoint := ENetMultiplayerPeer.new()
	if endpoint.create_server(int(data.port), 6) != OK or session.attach_dedicated(endpoint) != OK:
		endpoint.close()
		printerr("Could not start isolated VPS room transport")
		get_tree().quit(1)
		return
	print("VPS_PLAYTEST_READY")

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
	var profile = load("res://common/net/editor_vps_playtest.gd").new()
	add_child(profile)
	if profile.load_profile(): editor_playtest = profile
	else: profile.queue_free()
	# Client shows connection UI
	# The actual connection is handled by ConnectionManager
	EventBus.client_ready.emit()
	print("[GameManager] Client environment ready")
