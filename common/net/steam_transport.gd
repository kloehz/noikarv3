extends Node
## Optional platform boundary adapted from multiplayer-template 1.0.0.
## SessionService owns peers; MatchManager owns accounts, teams and gameplay.
signal status_changed(message: String)
signal invitation_received(lobby: int)
signal host_ready(identity: Dictionary)
const PRODUCT := "noikar-pvpve-v1"
const MAX_PLAYERS := 6
var session: Node
var auth: Node
var lobby_id := 0
var initialized := false
var last_error := ""
var pending_invitation := 0
var _steam: Object
var _pending := ""
var _attempt := -1
var _target_lobby := 0
var _host_steam_id := 0
var _identity: Dictionary = {}
var _deadline := 0.0
var _create_in_flight := false
var _joins_in_flight: Dictionary = {}
var _owner_check := 0.0

func configure(owner: Node, accounts: Node) -> void:
	session = owner
	auth = accounts

func _ready() -> void:
	session.phase_changed.connect(_phase_changed)
	session.session_ended.connect(func(_reason): leave_lobby())
	session.peer_admitted.connect(func(_id, _identity): _update_joinable())

func _peer_available() -> bool:
	return ClassDB.class_exists("SteamMultiplayerPeer")

func initialize() -> bool:
	if initialized: return true
	if _steam == null and Engine.has_singleton("Steam"): _steam = Engine.get_singleton("Steam")
	if _steam == null or not _peer_available(): return _error("GodotSteam is unavailable. LAN remains available.")
	for method in ["isSteamRunning", "steamInitEx", "run_callbacks", "createLobby", "joinLobby", "getLobbyOwner", "getLobbyData", "setLobbyData", "getSteamID", "setLobbyJoinable", "getNumLobbyMembers", "getLobbyMemberByIndex", "requestLobbyData", "leaveLobby", "getFriendCount", "getFriendByIndex", "getFriendPersonaName", "getFriendPersonaState", "inviteUserToLobby"]:
		if not _steam.has_method(method): return _error("Steam API is missing " + method)
	for event in ["lobby_created", "lobby_joined", "join_requested", "lobby_data_update", "steam_shutdown"]:
		if not _steam.has_signal(event): return _error("Steam API is missing " + event)
	if not _steam.call("isSteamRunning"): return _error("Open Steam and sign in. LAN remains available.")
	var app_id := int(OS.get_environment("NOIKAR_STEAM_APP_ID"))
	if app_id == 0 and OS.is_debug_build(): app_id = 480
	if app_id <= 0 or (app_id == 480 and not OS.is_debug_build()): return _error("A production Steam AppID is required for release builds.")
	var result: Dictionary = _steam.call("steamInitEx", app_id, false)
	if int(result.get("status", -1)) != 0: return _error("Steam could not initialize: " + str(result.get("verbal", "unknown error")))
	initialized = true
	last_error = ""
	for pair in [["lobby_created", _lobby_created], ["lobby_joined", _lobby_joined], ["join_requested", _join_requested], ["lobby_data_update", _lobby_data_updated], ["steam_shutdown", _steam_shutdown]]:
		if not _steam.is_connected(pair[0], pair[1]): _steam.connect(pair[0], pair[1])
	return true

func _constant(name: String) -> int:
	return ClassDB.class_get_integer_constant("Steam", name)

func _new_peer() -> MultiplayerPeer:
	return ClassDB.instantiate("SteamMultiplayerPeer") as MultiplayerPeer

func create_private_lobby() -> void:
	if session.phase != "menu" or _create_in_flight or not _pending.is_empty(): return
	if not initialize(): return
	_attempt = session.begin_attempt()
	if _attempt < 0: return
	var attempt := _attempt
	_pending = "account"
	_deadline = _now() + 25.0
	var created: Dictionary = await auth.create_listen_room(session.session_id)
	if not _current(attempt):
		if created.get("accepted", false): auth.close_listen_room(created.room_id, created.room_credential)
		return
	if not created.get("accepted", false):
		_fail(str(created.get("reason", "Could not create an account-bound room")))
		return
	session.configure_room(created.room_id, created.room_credential)
	_identity = created.host_identity.duplicate()
	_pending = "create"
	_create_in_flight = true
	_steam.call("createLobby", _constant("LOBBY_TYPE_PRIVATE"), MAX_PLAYERS)
	status_changed.emit("Creating a private Steam room...")

func _current(attempt: int) -> bool:
	return attempt == _attempt and session.is_attempt_current(attempt)

func _lobby_created(result: int, id: int) -> void:
	_create_in_flight = false
	if _pending != "create" or not _current(_attempt):
		if result == _constant("RESULT_OK"): _steam.call("leaveLobby", id)
		return
	if result != _constant("RESULT_OK") or id <= 0:
		_fail("Could not create the Steam lobby")
		return
	lobby_id = id
	_host_steam_id = int(_steam.call("getSteamID"))
	var metadata := {"product": PRODUCT, "compatibility": JSON.stringify(session.compatibility_metadata()), "room_id": session.room_id, "host_steam_id": str(_host_steam_id)}
	for key in metadata:
		if not bool(_steam.call("setLobbyData", id, key, metadata[key])):
			_fail("Could not publish Steam room compatibility")
			return
	var peer := _new_peer()
	peer.set("server_relay", true)
	if int(peer.call("create_host", 0)) != OK:
		peer.close()
		_fail("Could not create Steam P2P transport")
		return
	_pending = ""
	if session.attach_host(peer, "steam", _identity) != OK:
		peer.close()
		_fail("The active session cannot be replaced")
		return
	session.peer_membership_validator = _validate_member
	host_ready.emit(_identity.duplicate())
	_update_joinable()
	status_changed.emit("Steam room created. Invite friends to connect.")

func _join_requested(id: int, _friend: int) -> void:
	if id <= 0: return
	if session.phase != "menu":
		_error("Leave the current room before accepting another invitation.")
		return
	pending_invitation = id
	invitation_received.emit(id)

func accept_launch_invite(arguments: PackedStringArray) -> void:
	for index in range(arguments.size() - 1):
		if arguments[index] == "+connect_lobby" and arguments[index + 1].is_valid_int():
			_join_requested(int(arguments[index + 1]), 0)
			return

func join_lobby(id: int) -> void:
	if id <= 0 or session.phase != "menu" or _joins_in_flight.has(id) or not _pending.is_empty(): return
	if not initialize(): return
	_attempt = session.begin_attempt()
	if _attempt < 0: return
	_target_lobby = id
	_pending = "join"
	_joins_in_flight[id] = _attempt
	_deadline = _now() + 25.0
	_steam.call("joinLobby", id)
	status_changed.emit("Joining Steam room...")

func _lobby_joined(id: int, _permissions: int, _locked: bool, response: int) -> void:
	if id == lobby_id and _host_steam_id == int(_steam.call("getSteamID")): return
	var request: int = _joins_in_flight.get(id, -1)
	_joins_in_flight.erase(id)
	if _pending != "join" or id != _target_lobby or not _current(request):
		if response == _constant("CHAT_ROOM_ENTER_RESPONSE_SUCCESS"): _steam.call("leaveLobby", id)
		return
	if response != _constant("CHAT_ROOM_ENTER_RESPONSE_SUCCESS"):
		_fail("Steam refused the lobby join")
		return
	lobby_id = id
	_pending = "metadata"
	_try_connect()

func _lobby_data_updated(_success: int, id: int, _member: int) -> void:
	if _pending == "metadata" and id == lobby_id: _try_connect()

func _try_connect() -> void:
	if _pending != "metadata" or not _current(_attempt): return
	var product := str(_steam.call("getLobbyData", lobby_id, "product"))
	var room := str(_steam.call("getLobbyData", lobby_id, "room_id"))
	var host := str(_steam.call("getLobbyData", lobby_id, "host_steam_id"))
	var raw := str(_steam.call("getLobbyData", lobby_id, "compatibility"))
	if product.is_empty() or room.is_empty() or host.is_empty() or raw.is_empty():
		_steam.call("requestLobbyData", lobby_id)
		return
	var metadata = JSON.parse_string(raw) if raw.length() <= 2048 else null
	if product != PRODUCT or not metadata is Dictionary or not session.is_compatible(metadata) or not host.is_valid_int():
		_fail("This lobby uses an incompatible Noikar build")
		return
	_host_steam_id = host.to_int()
	if not _original_host_present() or not _contains_member(int(_steam.call("getSteamID"))):
		_fail("The original host is unavailable; host migration is not supported")
		return
	_pending = "ticket"
	var attempt := _attempt
	var proof: Dictionary = await auth.issue_listen_ticket(room)
	if not _current(attempt): return
	if not proof.get("accepted", false) or not _original_host_present():
		_fail("Could not obtain room admission")
		return
	session.configure_room(room)
	session.pending_admission_ticket = str(proof.ticket)
	var peer := _new_peer()
	peer.set("server_relay", true)
	if int(peer.call("create_client", _host_steam_id, 0)) != OK:
		peer.close()
		_fail("Could not connect Steam P2P transport")
		return
	_pending = ""
	if session.attach_client(peer, "steam") != OK:
		peer.close()
		_fail("The active session cannot be replaced")
		return
	session.peer_membership_validator = _validate_member
	pending_invitation = 0

func _original_host_present() -> bool:
	return initialized and lobby_id > 0 and _host_steam_id > 0 and int(_steam.call("getLobbyOwner", lobby_id)) == _host_steam_id and _contains_member(_host_steam_id)

func _contains_member(id: int) -> bool:
	for index in int(_steam.call("getNumLobbyMembers", lobby_id)):
		if int(_steam.call("getLobbyMemberByIndex", lobby_id, index)) == id: return true
	return false

func _validate_member(id: int) -> bool:
	var peer: MultiplayerPeer = session.multiplayer.multiplayer_peer
	if not _original_host_present() or peer == null or not peer.has_method("get_steam_id_for_peer_id"): return false
	var steam_id: int = peer.call("get_steam_id_for_peer_id", id)
	return steam_id > 0 and _contains_member(steam_id) and (session.is_host() or (id == 1 and steam_id == _host_steam_id))

func _occupancy() -> int:
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	return manager.get_lobby_peer_ids().size() if manager != null else MAX_PLAYERS

func can_invite_friends() -> bool:
	if not initialized or not _pending.is_empty() or session.transport != "steam" or session.phase != "lobby" or not session.is_host(): return false
	return _original_host_present() and _host_steam_id == int(_steam.call("getSteamID")) and _occupancy() < MAX_PLAYERS and int(_steam.call("getNumLobbyMembers", lobby_id)) < MAX_PLAYERS

func get_invite_friends() -> Array:
	if not can_invite_friends():
		_error("Invitations require your active Steam room with an open slot.")
		return []
	var flag := _constant("FRIEND_FLAG_IMMEDIATE")
	var count := int(_steam.call("getFriendCount", flag))
	if count < 0:
		_error("Steam could not read the friend list.")
		return []
	last_error = ""
	var seen := {_host_steam_id: true}
	var friends: Array = []
	for index in count:
		var id := int(_steam.call("getFriendByIndex", index, flag))
		if id <= 0 or seen.has(id): continue
		seen[id] = true
		var name := str(_steam.call("getFriendPersonaName", id))
		friends.append({"id": id, "name": name if not name.is_empty() else "Steam %d" % id, "online": int(_steam.call("getFriendPersonaState", id)) != _constant("PERSONA_STATE_OFFLINE"), "in_lobby": _contains_member(id)})
	friends.sort_custom(func(a, b): return a.online if a.online != b.online else str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return friends

func invite_friend(id: int) -> bool:
	for friend in get_invite_friends():
		if friend.id != id: continue
		if friend.in_lobby: return _error("This friend is already in the room.")
		if not bool(_steam.call("inviteUserToLobby", lobby_id, id)): return _error("Steam rejected the invitation request.")
		status_changed.emit("Invitation requested for %s; delivery and acceptance are not confirmed." % friend.name)
		return true
	return _error("Select a friend from the current Steam list.")

func _update_joinable() -> void:
	if initialized and lobby_id > 0 and session.is_host():
		_steam.call("setLobbyJoinable", lobby_id, session.phase == "lobby" and _occupancy() < MAX_PLAYERS)

func _phase_changed(phase: String) -> void:
	if phase == "closing": leave_lobby()
	else: _update_joinable()

func leave_lobby() -> void:
	_pending = ""
	_attempt = -1
	_target_lobby = 0
	_identity.clear()
	if initialized and lobby_id > 0: _steam.call("leaveLobby", lobby_id)
	lobby_id = 0
	_host_steam_id = 0

func _steam_shutdown() -> void:
	if session.transport == "steam" or not _pending.is_empty(): session.close("Steam closed")
	leave_lobby()
	initialized = false

func _process(delta: float) -> void:
	if not initialized: return
	_steam.call("run_callbacks")
	if not _pending.is_empty() and _now() > _deadline: _fail("Steam room operation timed out")
	_owner_check += delta
	if _owner_check >= 1.0:
		_owner_check = 0.0
		if lobby_id > 0 and _host_steam_id > 0 and not _original_host_present(): _fail("The original Steam host left the room")
		_update_joinable()

func _fail(message: String) -> void:
	leave_lobby()
	if session.phase not in ["menu", "closing"]: session.close(message)
	_error(message)

func _error(message: String) -> bool:
	last_error = message
	status_changed.emit(message)
	return false

func _now() -> float:
	return Time.get_ticks_usec() / 1000000.0
