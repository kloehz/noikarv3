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
var original_host_peer_id := ORIGINAL_HOST
var _room_credential := ""
var _peer: MultiplayerPeer
var _bindings: Array[Dictionary] = []
var _world_cleanup: Callable
static var _addon_fingerprint := ""

func configure_room(id: String, credential: String = "") -> void:
	if phase != "menu": return
	room_id = id
	_room_credential = credential

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

func _valid_identity(identity: Dictionary) -> bool:
	return identity.size() == 2 and identity.get("account_id") is String and identity.get("username") is String and not identity.account_id.is_empty() and not identity.username.is_empty()

func _can_attach() -> bool:
	return is_inside_tree() and phase == "menu" and _peer == null and (multiplayer.multiplayer_peer == null or multiplayer.multiplayer_peer is OfflineMultiplayerPeer)

func _bind(event: Signal, callback: Callable) -> void:
	event.connect(callback)
	_bindings.append({"event": event, "callback": callback})

func _attach(peer: MultiplayerPeer, name_of_transport: String, next_role: String) -> void:
	generation += 1
	session_id = Crypto.new().generate_random_bytes(16).hex_encode()
	role = next_role
	transport = name_of_transport
	_peer = peer
	var api := multiplayer as SceneMultiplayer
	api.auth_timeout = 10.0
	api.auth_callback = _on_auth_data.bind(generation)
	_bind(api.peer_authenticating, _on_authenticating.bind(generation))
	_bind(api.peer_connected, _on_peer_connected.bind(generation))
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
	if not metadata is Dictionary or not is_compatible(metadata) or (role == "CLIENT" and id != ORIGINAL_HOST):
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
		entries.sort()
		_addon_fingerprint = "\n".join(entries).sha256_text()
	var version := Engine.get_version_info()
	var engine_build := "%s.%s.%s.%s.%s" % [version.major, version.minor, version.status, version.build, str(version.hash).left(9)]
	return {"protocol": PROTOCOL_VERSION, "engine": engine_build, "engine_hash": version.hash, "addons": _addon_fingerprint}

static func _fingerprint_files(path: String, entries: Array[String]) -> void:
	for file in DirAccess.get_files_at(path):
		if file.ends_with(".gd") or file.ends_with(".cfg") or file.ends_with(".gdextension"):
			entries.append(path + "/" + file + ":" + FileAccess.get_sha256(path + "/" + file))
	for folder in DirAccess.get_directories_at(path):
		_fingerprint_files(path + "/" + folder, entries)

func is_compatible(metadata: Dictionary) -> bool:
	var expected := compatibility_metadata()
	if metadata.size() != expected.size(): return false
	# JSON numbers are floats; strict Dictionary equality rejects a valid wire
	# protocol integer even though its numeric value is exactly the same.
	if not (metadata.get("protocol") is int or metadata.get("protocol") is float) or metadata.protocol != PROTOCOL_VERSION:
		return false
	for key in ["engine", "engine_hash", "addons"]:
		if metadata.get(key) != expected[key]: return false
	return true

func close(reason: String = "") -> void:
	if phase in ["menu", "closing"]: return
	# Invalidate every captured HTTP/load/transport callback before cleanup yields.
	generation += 1
	_room_credential = ""
	set_phase("closing")
	for binding in _bindings:
		if binding.event.is_connected(binding.callback): binding.event.disconnect(binding.callback)
	_bindings.clear()
	(multiplayer as SceneMultiplayer).auth_callback = Callable()
	var was_client := role == "CLIENT"
	if multiplayer.multiplayer_peer == _peer: multiplayer.multiplayer_peer = null
	_peer.close()
	_peer = null
	# Netfox observes server detach in its process hook, but has no local client
	# detach hook. Route that transition through its existing stop signal/owner.
	if was_client: NetworkEvents.on_client_stop.emit()
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
