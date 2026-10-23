extends RefCounted
## SDK/HTTP boundaries only. Real SessionService and loopback ENet lifecycle.
const HOST := 76561198000010101
const FRIEND := 76561198000010102
const LOBBY := 900719925474099312

static func add_match_manager(parent: Node) -> Node3D:
	var manager = load("res://common/match_manager.gd").new()
	for name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new()
		container.name = name
		manager.add_child(container)
	var state := MatchState.new()
	state.name = "MatchState"
	manager.add_child(state)
	var director := MatchDirector.new()
	director.rules = load("res://common/resources/default_match_rules.tres")
	director.match_state = state
	manager.add_child(director)
	parent.add_child(manager)
	return manager

class Platform:
	extends RefCounted
	signal lobby_created(result: int, id: int)
	signal lobby_joined(id: int, permissions: int, locked: bool, response: int)
	signal join_requested(id: int, friend_id: int)
	signal lobby_data_update(success: int, id: int, member: int)
	signal steam_shutdown
	var running := true
	var owner := HOST
	var local_id := HOST
	var members: Array = [HOST]
	var friends: Array = [{"id": FRIEND, "name": "Fixture friend", "online": true}]
	var data := {}
	var creates: Array = []
	var joins: Array = []
	var leaves: Array = []
	var sends: Array = []
	var send_result := true
	var joinable := false
	func isSteamRunning() -> bool: return running
	func steamInitEx(_appid: int, _embed: bool) -> Dictionary: return {"status": 0}
	func run_callbacks() -> void: pass
	func getSteamID() -> int: return local_id
	func createLobby(kind: int, capacity: int) -> void: creates.append([kind, capacity])
	func joinLobby(id: int) -> void: joins.append(id)
	func getLobbyOwner(_id: int) -> int: return owner
	func getLobbyData(_id: int, key: String) -> String: return str(data.get(key, ""))
	func setLobbyData(_id: int, key: String, value: String) -> bool:
		data[key] = value
		return true
	func getNumLobbyMembers(_id: int) -> int: return members.size()
	func getLobbyMemberByIndex(_id: int, index: int) -> int: return members[index]
	func requestLobbyData(_id: int) -> bool: return true
	func setLobbyJoinable(_id: int, value: bool) -> void: joinable = value
	func leaveLobby(id: int) -> void: leaves.append(id)
	func getFriendCount(_flags: int) -> int: return friends.size()
	func getFriendByIndex(index: int, _flags: int) -> int: return friends[index].id
	func getFriendPersonaName(id: int) -> String:
		for friend in friends:
			if friend.id == id: return friend.name
		return ""
	func getFriendPersonaState(id: int) -> int:
		for friend in friends:
			if friend.id == id: return 1 if friend.online else 0
		return 0
	func inviteUserToLobby(lobby: int, id: int) -> bool:
		sends.append([lobby, id])
		return send_result

class Accounts:
	extends Node
	signal resume
	var delayed := false
	var creates := 0
	var tickets := 0
	var closed: Array = []
	var access_token := "owner-only-account-bearer"
	func create_listen_room(_session: String) -> Dictionary:
		creates += 1
		if delayed: await resume
		return {"accepted": true, "room_id": "account-room", "room_credential": "room-only-scoped-credential", "host_identity": {"account_id": "host-account", "username": "Host"}}
	func issue_listen_ticket(_room: String) -> Dictionary:
		tickets += 1
		if delayed: await resume
		return {"accepted": true, "ticket": "opaque-single-use-admission-proof-32"}
	func close_listen_room(room: String, credential: String) -> void: closed.append([room, credential])

class Peer:
	extends ENetMultiplayerPeer
	var server_relay := false
	func create_host(_port: int) -> int: return create_server(0, 5)
	func get_steam_id_for_peer_id(id: int) -> int: return HOST if id == 1 else FRIEND

class Adapter:
	extends "res://common/net/steam_transport.gd"
	func _peer_available() -> bool: return true
	func _constant(name: String) -> int:
		return {"LOBBY_TYPE_PRIVATE": 0, "RESULT_OK": 1, "CHAT_ROOM_ENTER_RESPONSE_SUCCESS": 1, "FRIEND_FLAG_IMMEDIATE": 4, "PERSONA_STATE_OFFLINE": 0}.get(name, -1)
	func _new_peer() -> MultiplayerPeer: return Peer.new()
