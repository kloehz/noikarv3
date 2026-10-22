extends GutTest
## Separate SceneMultiplayer APIs exchange real ENet authentication packets.
## No account admission or gameplay is inferred from transport compatibility.
var _roots: Array[Node] = []
var _services: Array[Node] = []
var _apis: Array[SceneMultiplayer] = []
var _previous_peer: MultiplayerPeer

func before_each() -> void:
	_previous_peer = multiplayer.multiplayer_peer
	if multiplayer.multiplayer_peer == null:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

class OtherBuild extends "res://common/net/session_service.gd":
	func compatibility_metadata() -> Dictionary:
		var metadata := super.compatibility_metadata()
		metadata.engine_hash = "other-build"
		return metadata

func _endpoint(other_build := false) -> Node:
	var root := Node.new()
	root.name = "Endpoint%d" % _roots.size()
	add_child(root)
	_roots.append(root)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, root.get_path())
	_apis.append(api)
	var service = OtherBuild.new() if other_build else load("res://common/net/session_service.gd").new()
	root.add_child(service)
	_services.append(service)
	return service

func after_each() -> void:
	for service in _services: service.close()
	for frame in 4: await get_tree().process_frame
	for root in _roots:
		get_tree().set_multiplayer(null, root.get_path())
		root.free()
	_roots.clear()
	_services.clear()
	_apis.clear()
	multiplayer.multiplayer_peer = _previous_peer

func test_matching_builds_connect_without_authenticating_an_account() -> void:
	var host := _endpoint()
	var guest := _endpoint()
	host.configure_room("fixture-room", "scoped-fixture-secret")
	assert_eq(host.host_lan(0, {"account_id": "host", "username": "Host"}), OK)
	var port: int = (_apis[0].multiplayer_peer as ENetMultiplayerPeer).host.get_local_port()
	assert_eq(guest.join_lan("127.0.0.1", port), OK)
	watch_signals(host)
	for frame in 120:
		if _apis[0].get_peers().size() == 1 and guest.phase == "lobby": break
		await get_tree().process_frame
	assert_eq(_apis[0].get_peers().size(), 1)
	assert_eq(guest.phase, "lobby")
	assert_signal_not_emitted(host, "peer_admitted", "Build compatibility is not account identity")

func test_different_engine_build_is_rejected_before_peer_connected() -> void:
	var host := _endpoint()
	var guest := _endpoint(true)
	host.configure_room("fixture-room", "scoped-fixture-secret")
	assert_eq(host.host_lan(0, {"account_id": "host", "username": "Host"}), OK)
	var port: int = (_apis[0].multiplayer_peer as ENetMultiplayerPeer).host.get_local_port()
	watch_signals(_apis[0])
	assert_eq(guest.join_lan("127.0.0.1", port), OK)
	for frame in 60: await get_tree().process_frame
	assert_eq(_apis[0].get_peers().size(), 0)
	assert_signal_not_emitted(_apis[0], "peer_connected")

func test_failed_host_authentication_returns_client_to_menu() -> void:
	var guest := _endpoint()
	assert_eq(guest.join_lan("127.0.0.1", 1), OK)
	_apis[0].peer_authentication_failed.emit(1)
	for frame in 4: await get_tree().process_frame
	assert_eq(guest.phase, "menu")

func test_old_room_auth_completion_cannot_admit_into_new_session() -> void:
	var host := _endpoint()
	var guest := _endpoint()
	assert_true(host.has_method("_complete_admission"), "Scoped admission completion needs session/room generation checks")
	if not host.has_method("_complete_admission"): return
	var manager = load("res://common/match_manager.gd").new()
	for name in ["Players", "Mobs", "Souls", "Totems", "Projectiles"]:
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
	add_child_autofree(manager)
	host.configure_room("new-room", "new-room-scoped-credential")
	assert_eq(host.host_lan(0, {"account_id": "host", "username": "Host"}), OK)
	var port: int = (_apis[0].multiplayer_peer as ENetMultiplayerPeer).host.get_local_port()
	assert_eq(guest.join_lan("127.0.0.1", port), OK)
	for frame in 120:
		if _apis[0].get_peers().size() == 1: break
		await get_tree().process_frame
	assert_eq(_apis[0].get_peers().size(), 1)
	if _apis[0].get_peers().is_empty(): return
	var peer_id: int = _apis[0].get_peers()[0]
	var identity := {"accepted": true, "account_id": "guest", "username": "Guest"}
	assert_false(host._complete_admission(peer_id, identity, host.generation - 1, "new-room"))
	assert_false(host._complete_admission(peer_id, identity, host.generation, "old-room"))
	assert_true(manager.get_lobby_peer_ids().is_empty())
	assert_true(host.has_method("_admission_request_is_current"), "A reused peer ID must not inherit an old HTTP redemption")
	if not host.has_method("_admission_request_is_current"): return
	host._pending_admissions[peer_id] = 41
	assert_true(host._admission_request_is_current(peer_id, host.generation, "new-room", 41))
	host._pending_admissions[peer_id] = 42
	assert_false(host._admission_request_is_current(peer_id, host.generation, "new-room", 41))
	assert_true(host._admission_request_is_current(peer_id, host.generation, "new-room", 42))
	assert_true(host._complete_admission(peer_id, identity, host.generation, "new-room"), "Same validated response is accepted only for its active peer/session/room")
	assert_eq(manager.get_lobby_peer_ids(), [peer_id])
