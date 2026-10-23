extends "res://tests/isolated_gut_test.gd"
const Fixture := preload("res://tests/fixtures/steam_platform.gd")
var _session: Node
var _adapter: Node
var _platform: RefCounted
var _accounts: Node
var _manager: Node3D
var _guest_api: SceneMultiplayer
var _guest_peer: ENetMultiplayerPeer

func before_each() -> void:
	super.before_each()
	_session = load("res://common/net/session_service.gd").new()
	add_child(_session)
	_accounts = Fixture.Accounts.new()
	add_child(_accounts)
	_adapter = Fixture.Adapter.new()
	_adapter.configure(_session, _accounts)
	_platform = Fixture.Platform.new()
	_adapter._steam = _platform
	add_child(_adapter)
	_manager = load("res://common/match_manager.gd").new()
	for name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new()
		container.name = name
		_manager.add_child(container)
	var state := MatchState.new()
	state.name = "MatchState"
	_manager.add_child(state)
	var director := MatchDirector.new()
	director.rules = load("res://common/resources/default_match_rules.tres")
	director.match_state = state
	_manager.add_child(director)
	add_child(_manager)

func after_each() -> void:
	if _guest_peer != null:
		_guest_api.multiplayer_peer = null
		_guest_peer.close()
		_guest_peer = null
		_guest_api = null
	_session.close()
	for frame in 4: await get_tree().process_frame
	_manager.free()
	_adapter.free()
	_accounts.free()
	_session.free()
	super.after_each()

func _host() -> void:
	await _adapter.create_private_lobby()
	_platform.lobby_created.emit(1, Fixture.LOBBY)

func test_private_lobby_has_six_slots_and_only_public_routing_metadata() -> void:
	await _host()
	assert_eq(_platform.creates, [[0, 6]])
	assert_eq(_adapter.lobby_id, Fixture.LOBBY)
	assert_eq(_session.role, "LISTEN_HOST")
	assert_eq(_session.transport, "steam")
	assert_eq(_platform.data.room_id, "account-room")
	assert_eq(_platform.data.host_steam_id, str(Fixture.HOST))
	assert_eq(_platform.data.product, "noikar-pvpve-v1")
	assert_false(JSON.stringify(_platform.data).contains("credential"))
	assert_false(JSON.stringify(_platform.data).contains(_accounts.access_token))
	assert_eq(_accounts.creates, 1)
	assert_eq(_session.multiplayer.multiplayer_peer.get_unique_id(), 1)

func test_explicit_invitation_keeps_exact_64_bit_target_and_reports_requested() -> void:
	await _host()
	var friends: Array = _adapter.get_invite_friends()
	assert_eq(friends.size(), 1)
	assert_true(_platform.sends.is_empty())
	watch_signals(_adapter)
	assert_true(_adapter.invite_friend(Fixture.FRIEND))
	assert_eq(_platform.sends, [[Fixture.LOBBY, Fixture.FRIEND]])
	var sent: Array = get_signal_parameters(_adapter, "status_changed")
	assert_true(str(sent[0]).contains("requested"))
	_platform.send_result = false
	assert_false(_adapter.invite_friend(Fixture.FRIEND))
	assert_false(_adapter.last_error.is_empty())
	assert_false(_adapter.invite_friend(Fixture.HOST))

func test_five_existing_members_allow_invites_but_six_or_full_roster_do_not() -> void:
	await _host()
	_platform.members = [Fixture.HOST, 11, 12, 13, 14]
	assert_true(_adapter.can_invite_friends())
	_platform.members.append(15)
	assert_false(_adapter.invite_friend(Fixture.FRIEND))
	_platform.members = [Fixture.HOST]
	for id in range(1, 7):
		assert_true(_manager._admit_authenticated_identity(id, {"account_id": "account-%d" % id, "username": "Name"}))
	assert_false(_adapter.can_invite_friends())

func test_owner_migration_ends_session_instead_of_transferring_authority() -> void:
	await _host()
	_platform.owner = Fixture.FRIEND
	assert_false(_adapter.invite_friend(Fixture.FRIEND))
	_adapter._process(1.1)
	for frame in 4: await get_tree().process_frame
	assert_eq(_session.phase, "menu")
	assert_eq(_adapter.lobby_id, 0)
	assert_true(_platform.leaves.has(Fixture.LOBBY))

func test_late_create_after_close_cannot_attach_or_start_clock() -> void:
	await _adapter.create_private_lobby()
	_session.close("Cancelled")
	_platform.lobby_created.emit(1, Fixture.LOBBY)
	for frame in 4: await get_tree().process_frame
	assert_eq(_session.phase, "menu")
	assert_eq(_adapter.lobby_id, 0)
	assert_true(_platform.leaves.has(Fixture.LOBBY))
	assert_eq(NetworkTime._state, NetworkTime._STATE_INACTIVE)

func test_late_api_creation_closes_old_room_without_creating_a_lobby() -> void:
	_accounts.delayed = true
	_adapter.create_private_lobby()
	_session.close("Cancelled during HTTP")
	_accounts.resume.emit()
	for frame in 4: await get_tree().process_frame
	assert_true(_platform.creates.is_empty())
	assert_eq(_accounts.closed, [["account-room", "room-only-scoped-credential"]])
	assert_eq(_session.phase, "menu")

func test_bad_metadata_never_requests_account_ticket() -> void:
	_adapter.join_lobby(Fixture.LOBBY)
	_platform.data = {"product": "other-game", "room_id": "room", "host_steam_id": str(Fixture.HOST), "compatibility": "{}"}
	_platform.lobby_joined.emit(Fixture.LOBBY, 0, false, 1)
	assert_eq(_accounts.tickets, 0)
	for frame in 4: await get_tree().process_frame
	assert_eq(_session.phase, "menu")

func test_membership_check_runs_before_and_after_account_redemption() -> void:
	await _host()
	assert_true(_session.get("peer_membership_validator") is Callable, "Steam membership must compose with account admission")
	if not _session.get("peer_membership_validator") is Callable: return
	assert_false(_session.peer_membership_validator.call(2))
	_platform.members.append(Fixture.FRIEND)
	assert_true(_session.peer_membership_validator.call(2))

func test_character_selection_closes_invitations_without_replacing_game_rules() -> void:
	await _host()
	EventBus.phase_changed.emit(MatchState.Phase.CHARACTER_SELECT)
	assert_false(_adapter.can_invite_friends())
	assert_false(_platform.joinable)

func test_invite_is_queued_for_login_not_accepted_as_an_account_identity() -> void:
	assert_true(_adapter.initialize())
	_platform.join_requested.emit(Fixture.LOBBY, Fixture.FRIEND)
	assert_eq(_adapter.pending_invitation, Fixture.LOBBY)
	assert_true(_platform.joins.is_empty())
	assert_eq(_accounts.tickets, 0)

func _connect_real_guest() -> int:
	_platform.members.append(Fixture.FRIEND)
	_guest_api = SceneMultiplayer.new()
	_guest_api.root_path = get_path()
	_guest_api.auth_callback = func(id: int, _data: PackedByteArray): _guest_api.complete_auth(id)
	_guest_api.peer_authenticating.connect(func(id: int): _guest_api.send_auth(id, JSON.stringify(_session.compatibility_metadata()).to_utf8_buffer()))
	_guest_peer = ENetMultiplayerPeer.new()
	var host_peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	assert_eq(_guest_peer.create_client("127.0.0.1", host_peer.host.get_local_port()), OK)
	_guest_api.multiplayer_peer = _guest_peer
	var until := Time.get_ticks_msec() + 2000
	while multiplayer.get_peers().is_empty() and Time.get_ticks_msec() < until:
		_guest_api.poll()
		multiplayer.poll()
		await get_tree().create_timer(0.005).timeout
	assert_eq(multiplayer.get_peers().size(), 1, "A real transport peer must pass the compatibility and Steam-membership checks")
	return _guest_peer.get_unique_id()

func test_real_compatible_lobby_peer_needs_valid_account_and_membership_at_completion() -> void:
	await _host()
	var id := await _connect_real_guest()
	assert_false(_manager.get_lobby_peer_ids().has(id), "Transport compatibility/lobby presence is not account admission")
	assert_false(_session._complete_admission(id, {"accepted": false}, _session.generation, "account-room"))
	_platform.members.erase(Fixture.FRIEND)
	var identity := {"accepted": true, "account_id": "guest-account", "username": "Guest"}
	assert_false(_session._complete_admission(id, identity, _session.generation, "account-room"))
	assert_false(_manager.get_lobby_peer_ids().has(id))
	_platform.members.append(Fixture.FRIEND)
	assert_true(_session._complete_admission(id, identity, _session.generation, "account-room"))
	assert_true(_manager.get_lobby_peer_ids().has(id))

func test_cancelled_ticket_completion_cannot_attach_a_client_to_new_session() -> void:
	_accounts.delayed = true
	_platform.local_id = Fixture.FRIEND
	_platform.members = [Fixture.HOST, Fixture.FRIEND]
	_platform.data = {"product": "noikar-pvpve-v1", "room_id": "account-room", "host_steam_id": str(Fixture.HOST), "compatibility": JSON.stringify(_session.compatibility_metadata())}
	_adapter.join_lobby(Fixture.LOBBY)
	_platform.lobby_joined.emit(Fixture.LOBBY, 0, false, 1)
	assert_eq(_accounts.tickets, 1)
	_session.close("Cancelled during ticket request")
	_accounts.resume.emit()
	for frame in 4: await get_tree().process_frame
	assert_eq(_session.phase, "menu")
	assert_true(_session.pending_admission_ticket.is_empty())
	assert_eq(_adapter.lobby_id, 0)
	assert_eq(NetworkTime._state, NetworkTime._STATE_INACTIVE)

func test_closed_sdk_never_creates_account_room_or_lobby() -> void:
	_platform.running = false
	await _adapter.create_private_lobby()
	assert_eq(_accounts.creates, 0)
	assert_true(_platform.creates.is_empty())
	assert_eq(_session.phase, "menu")
	assert_false(_adapter.last_error.is_empty())
