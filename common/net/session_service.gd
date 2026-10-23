extends Node
## Peer lifecycle only. MatchManager remains the account/team/gameplay authority.
const Lan := preload("res://common/net/enet_transport.gd")
const PROTOCOL_VERSION := 1
const MAX_PLAYERS := 6
const MAX_PLAYERS_PER_TEAM := 3
const ORIGINAL_HOST := 1

signal transport_started(transport_name: String)
signal session_ended(reason: String)
signal phase_changed(phase: String)
signal peer_admitted(peer_id: int, identity: Dictionary)

var role := "MENU"
var phase := "menu"
var session_id := ""
var generation := 0
var transport := ""
var room_id := ""
var end_reason := ""
var original_host_peer_id := ORIGINAL_HOST
var _room_credential := ""
var _peer: MultiplayerPeer
var _bindings: Array[Dictionary] = []
var _world_cleanup: Callable
var _pending_admissions: Dictionary = {}
var _admission_serial := 0
var peer_membership_validator: Callable
var pending_admission_ticket := ""
static var _addon_fingerprint := ""

func _ready() -> void:
	EventBus.phase_changed.connect(_on_match_phase_changed)

func _on_match_phase_changed(match_phase: int) -> void:
	if _peer == null or phase in ["menu", "closing"]: return
	if match_phase == MatchState.Phase.LOBBY:
		set_phase("lobby")
	elif match_phase in [MatchState.Phase.CHARACTER_SELECT, MatchState.Phase.COUNTDOWN]:
		set_phase("loading")
	else:
		set_phase("playing")

func configure_room(id: String, credential: String = "") -> void:
	if phase not in ["menu", "connecting"] or _peer != null: return
	room_id = id
	_room_credential = credential

func begin_attempt() -> int:
	if phase != "menu" or not _can_attach(): return -1
	generation += 1
	session_id = Crypto.new().generate_random_bytes(16).hex_encode()
	end_reason = ""
	set_phase("connecting")
	return generation

func is_attempt_current(ticket: int) -> bool:
	return generation == ticket and phase == "connecting" and _peer == null

func host_lan(port: int, identity: Dictionary) -> Error:
	if not _can_attach(): return ERR_ALREADY_IN_USE
	if not _valid_identity(identity): return ERR_INVALID_PARAMETER
	var result := Lan.host(port)
	if result.error != OK: return result.error
	var error := attach_host(result.peer, "enet", identity)
	if error != OK: result.peer.close()
	return error

func join_lan(address: String, port: int) -> Error:
	if not _can_attach(): return ERR_ALREADY_IN_USE
	var result := Lan.join(address, port)
	if result.error != OK: return result.error
	var error := attach_client(result.peer, "enet")
	if error != OK: result.peer.close()
	return error

func attach_host(peer: MultiplayerPeer, transport_name: String, identity: Dictionary) -> Error:
	if not _can_attach(): return ERR_ALREADY_IN_USE
	if not _valid_identity(identity): return ERR_INVALID_PARAMETER
	if peer == null or peer is OfflineMultiplayerPeer or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return ERR_INVALID_PARAMETER
	if peer.get_unique_id() != ORIGINAL_HOST: return ERR_INVALID_PARAMETER
	_attach(peer, transport_name, "LISTEN_HOST")
	set_phase("lobby")
	_bridge_server_started.call_deferred(generation)
	return OK

func attach_client(peer: MultiplayerPeer, transport_name: String) -> Error:
	if not _can_attach(): return ERR_ALREADY_IN_USE
	if peer == null or peer is OfflineMultiplayerPeer or peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return ERR_INVALID_PARAMETER
	_attach(peer, transport_name, "CLIENT")
	set_phase("connecting")
	_watch_connection(generation)
	return OK

func attach_dedicated(peer: MultiplayerPeer) -> Error:
	if not _can_attach(): return ERR_ALREADY_IN_USE
	if peer == null or peer is OfflineMultiplayerPeer or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED or peer.get_unique_id() != ORIGINAL_HOST:
		return ERR_INVALID_PARAMETER
	_attach(peer, "enet", "DEDICATED")
	set_phase("lobby")
	_bridge_server_started.call_deferred(generation)
	return OK

func _valid_identity(identity: Dictionary) -> bool:
	return identity.size() == 2 and identity.get("account_id") is String and identity.get("username") is String and not identity.account_id.is_empty() and not identity.username.is_empty()

func _can_attach() -> bool:
	return is_inside_tree() and phase in ["menu", "connecting"] and _peer == null and (multiplayer.multiplayer_peer == null or multiplayer.multiplayer_peer is OfflineMultiplayerPeer)

func _bind(event: Signal, callback: Callable) -> void:
	event.connect(callback)
	_bindings.append({"event": event, "callback": callback})

func _attach(peer: MultiplayerPeer, name_of_transport: String, next_role: String) -> void:
	generation += 1
	if session_id.is_empty(): session_id = Crypto.new().generate_random_bytes(16).hex_encode()
	role = next_role
	transport = name_of_transport
	_peer = peer
	var api := multiplayer as SceneMultiplayer
	api.auth_timeout = 10.0
	api.auth_callback = _on_auth_data.bind(generation)
	_bind(api.peer_authenticating, _on_authenticating.bind(generation))
	_bind(api.peer_connected, _on_peer_connected.bind(generation))
	_bind(api.peer_disconnected, _on_peer_disconnected.bind(generation))
	_bind(api.peer_authentication_failed, _on_authentication_failed.bind(generation))
	_bind(api.connected_to_server, _on_transport_connected.bind(generation))
	_bind(api.connection_failed, _on_transport_failed.bind(generation))
	_bind(api.server_disconnected, _on_transport_failed.bind(generation))
	multiplayer.multiplayer_peer = peer
	transport_started.emit(transport)

func is_host() -> bool:
	return role in ["LISTEN_HOST", "DEDICATED"] and phase not in ["menu", "closing"]

func is_current(ticket: int) -> bool:
	return ticket == generation and phase not in ["menu", "closing"] and _peer != null and multiplayer.multiplayer_peer == _peer

func set_phase(next_phase: String) -> void:
	if next_phase not in ["menu", "connecting", "lobby", "loading", "playing", "closing"] or next_phase == phase:
		return
	phase = next_phase
	phase_changed.emit(phase)

func _bridge_server_started(ticket: int) -> void:
	if is_current(ticket) and is_host(): EventBus.server_started.emit()

func _on_transport_connected(ticket: int) -> void:
	if not is_current(ticket) or role != "CLIENT": return
	set_phase("lobby")
	EventBus.client_connected.emit(multiplayer.get_unique_id())
	if not pending_admission_ticket.is_empty():
		var admission := pending_admission_ticket
		pending_admission_ticket = ""
		submit_admission_ticket(admission)

func _on_transport_failed(ticket: int) -> void:
	if is_current(ticket): close("Connection ended")

func _on_authentication_failed(id: int, ticket: int) -> void:
	if is_current(ticket) and role == "CLIENT" and id == ORIGINAL_HOST:
		close("Incompatible or unreachable host")

func _watch_connection(ticket: int) -> void:
	await get_tree().create_timer(12.0).timeout
	if is_current(ticket) and phase == "connecting": close("Connection timed out")

func _on_peer_connected(id: int, ticket: int) -> void:
	if is_current(ticket) and is_host(): EventBus.client_connected.emit(id)

func _on_peer_disconnected(id: int, ticket: int) -> void:
	if is_current(ticket): _pending_admissions.erase(id)

func _on_authenticating(id: int, ticket: int) -> void:
	if not is_current(ticket): return
	if role == "CLIENT" and id != ORIGINAL_HOST:
		_reject_auth.call_deferred(id, ticket)
		return
	(multiplayer as SceneMultiplayer).send_auth(id, JSON.stringify(compatibility_metadata()).to_utf8_buffer())

func _on_auth_data(id: int, data: PackedByteArray, ticket: int) -> void:
	if not is_current(ticket): return
	var metadata = JSON.parse_string(data.get_string_from_utf8()) if data.size() <= 2048 else null
	var api := multiplayer as SceneMultiplayer
	if not metadata is Dictionary or not is_compatible(metadata) or (role == "CLIENT" and id != ORIGINAL_HOST) or not _member_allowed(id):
		_reject_auth.call_deferred(id, ticket)
		return
	api.complete_auth(id)

func _reject_auth(id: int, ticket: int) -> void:
	if is_current(ticket) and (multiplayer as SceneMultiplayer).get_authenticating_peers().has(id):
		(multiplayer as SceneMultiplayer).disconnect_peer(id)

func compatibility_metadata() -> Dictionary:
	if _addon_fingerprint.is_empty():
		var entries: Array[String] = []
		for folder in ["netfox", "netfox.internals", "netfox.extras", "netfox.noray"]:
			_fingerprint_files("res://addons/" + folder, entries)
		var manifest: Resource = load("res://common/net/netfox_build_manifest.tres") if ResourceLoader.exists("res://common/net/netfox_build_manifest.tres") else null
		_addon_fingerprint = resolve_addon_fingerprint(entries, manifest)
	var version := Engine.get_version_info()
	var engine_build := "%s.%s.%s.%s.%s" % [version.major, version.minor, version.status, version.build, str(version.hash).left(9)]
	return {"protocol": PROTOCOL_VERSION, "engine": engine_build, "engine_hash": version.hash, "addons": _addon_fingerprint}

static func resolve_addon_fingerprint(entries: Array[String], manifest: Resource) -> String:
	if not entries.is_empty():
		entries.sort()
		return "\n".join(entries).sha256_text()
	# Exported GDScript is tokenized/remapped. The build carries a source digest;
	# never substitute an empty-directory hash or silently accept an unknown build.
	if manifest == null: return ""
	var value := str(manifest.get_meta("source_fingerprint", ""))
	var digest := RegEx.new()
	digest.compile("^[0-9a-f]{64}$")
	return value if digest.search(value) != null else ""

static func _fingerprint_files(path: String, entries: Array[String]) -> void:
	for file in DirAccess.get_files_at(path):
		if file.ends_with(".gd") or file.ends_with(".cfg") or file.ends_with(".gdextension"):
			entries.append(path + "/" + file + ":" + FileAccess.get_sha256(path + "/" + file))
	for folder in DirAccess.get_directories_at(path):
		_fingerprint_files(path + "/" + folder, entries)

func is_compatible(metadata: Dictionary) -> bool:
	var expected := compatibility_metadata()
	if str(expected.addons).length() != 64: return false
	if metadata.size() != expected.size(): return false
	# JSON numbers are floats; strict Dictionary equality rejects a valid wire
	# protocol integer even though its numeric value is exactly the same.
	if not (metadata.get("protocol") is int or metadata.get("protocol") is float) or metadata.protocol != PROTOCOL_VERSION:
		return false
	for key in ["engine", "engine_hash", "addons"]:
		if metadata.get(key) != expected[key]: return false
	return true

func _complete_admission(id: int, identity: Dictionary, ticket: int, expected_room: String) -> bool:
	if not is_current(ticket) or not is_host() or expected_room != room_id or id <= ORIGINAL_HOST or not multiplayer.get_peers().has(id):
		return false
	if not identity.get("accepted", false) or not _member_allowed(id): return false
	var validated := {"account_id": identity.get("account_id"), "username": identity.get("username")}
	if not _valid_identity(validated): return false
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	return manager != null and manager._admit_authenticated_identity(id, validated)

func _admission_request_is_current(id: int, ticket: int, expected_room: String, serial: int) -> bool:
	return is_current(ticket) and expected_room == room_id and _pending_admissions.get(id) == serial and multiplayer.get_peers().has(id)

func submit_admission_ticket(ticket: String) -> void:
	if role != "CLIENT" or not is_current(generation) or len(ticket) < 32 or len(ticket) > 128: return
	_submit_admission_ticket.rpc_id(ORIGINAL_HOST, ticket)

@rpc("any_peer", "reliable")
func _submit_admission_ticket(ticket: String) -> void:
	if not is_host() or phase != "lobby" or _room_credential.is_empty() or len(ticket) < 32 or len(ticket) > 128: return
	var id := multiplayer.get_remote_sender_id()
	if id <= ORIGINAL_HOST or _pending_admissions.has(id) or not multiplayer.get_peers().has(id) or not _member_allowed(id): return
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	if manager == null or manager.get_lobby_peer_ids().has(id): return
	var request_generation := generation
	var request_room := room_id
	_admission_serial += 1
	var request_serial := _admission_serial
	_pending_admissions[id] = request_serial
	var identity: Dictionary = await AuthService.redeem_listen_ticket(request_room, ticket, _room_credential)
	if not _admission_request_is_current(id, request_generation, request_room, request_serial): return
	_pending_admissions.erase(id)
	if not _complete_admission(id, identity, request_generation, request_room):
		_reject_admission.call_deferred(id, request_generation)
		return
	var validated := {"account_id": str(identity.account_id), "username": str(identity.username)}
	peer_admitted.emit(id, validated)
	_admission_accepted.rpc_id(id, validated.username)
	manager._broadcast_lobby_snapshots()

func _reject_admission(id: int, ticket: int) -> void:
	if is_current(ticket) and multiplayer.get_peers().has(id):
		(multiplayer as SceneMultiplayer).disconnect_peer(id)

@rpc("authority", "reliable")
func _admission_accepted(username: String) -> void:
	if role == "CLIENT" and is_current(generation): EventBus.game_server_authenticated.emit(username)

func _member_allowed(id: int) -> bool:
	return transport != "steam" or (peer_membership_validator.is_valid() and bool(peer_membership_validator.call(id)))

func close(reason: String = "") -> void:
	if phase in ["menu", "closing"]: return
	# Invalidate every captured HTTP/load/transport callback before cleanup yields.
	generation += 1
	end_reason = reason
	var closing_room := room_id
	var closing_credential := _room_credential
	_room_credential = ""
	pending_admission_ticket = ""
	peer_membership_validator = Callable()
	_pending_admissions.clear()
	if not closing_credential.is_empty():
		# This callback only closes the captured backend room; it never mutates
		# session state or clears a newer room/account when its request completes.
		AuthService.close_listen_room.call_deferred(closing_room, closing_credential)
	set_phase("closing")
	for binding in _bindings:
		if binding.event.is_connected(binding.callback): binding.event.disconnect(binding.callback)
	_bindings.clear()
	(multiplayer as SceneMultiplayer).auth_callback = Callable()
	NetworkEvents.notify_local_disconnect()
	if multiplayer.multiplayer_peer == _peer: multiplayer.multiplayer_peer = null
	if _peer != null: _peer.close()
	_peer = null
	# The existing Netfox event owner has stopped the clock before peer detach.
	_finish_close.call_deferred(reason, generation)

func _finish_close(reason: String, ticket: int) -> void:
	# At least one full process turn lets Netfox observe an immediate attach/close.
	await get_tree().process_frame
	await get_tree().process_frame
	if ticket != generation: return
	if NetworkEvents._is_server:
		await NetworkEvents.on_server_stop
	if ticket != generation: return
	if _world_cleanup.is_valid(): await _world_cleanup.call()
	if ticket != generation: return
	role = "MENU"
	session_id = ""
	room_id = ""
	transport = ""
	set_phase("menu")
	session_ended.emit(reason)
