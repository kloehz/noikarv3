extends GutTest

## Contract coverage for private server-side lobby records and deterministic
## selection cancellation. RPC sender validation remains in MatchManager.

var _manager: Node3D
var _director: MatchDirector

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_manager = load("res://common/match_manager.gd").new()
	for container_name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new()
		container.name = container_name
		_manager.add_child(container)
	var state := MatchState.new()
	state.name = "MatchState"
	_manager.add_child(state)
	_director = MatchDirector.new()
	_director.rules = load("res://common/resources/default_match_rules.tres")
	_director.match_state = state
	_manager.add_child(_director)
	add_child_autofree(_manager)
	NetworkTime.after_tick.disconnect(_director._on_after_tick)

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _record(name: String, account_id: String = "") -> Dictionary:
	return {"account_id": account_id, "name": name, "team": TeamId.NONE, "lobby_ready": false, "character_id": "", "selection_ready": false, "is_host": false}

func test_private_snapshot_never_contains_enemy_identity_or_peer_id() -> void:
	_manager._lobby = {2: _record("Red", "red"), 3: _record("Blue", "blue"), 4: _record("RedTwo", "red-two")}
	_manager._recompute_lobby()
	_manager._lobby[2]["team"] = TeamId.RED
	_manager._lobby[3]["team"] = TeamId.BLUE
	_manager._lobby[4]["team"] = TeamId.RED
	var red_snapshot: Dictionary = _manager._snapshot_for(2)
	assert_eq(red_snapshot["team"], TeamId.RED)
	assert_eq(red_snapshot["members"].size(), 2)
	assert_false(red_snapshot.has("peer_id"))
	assert_false(red_snapshot.has("account_id"))
	assert_false(red_snapshot.has("team_red_score"))
	assert_false(red_snapshot.has("team_blue_score"))

func test_selection_cancellation_clears_ready_and_choices_without_spawning() -> void:
	_manager._lobby = {2: _record("Red", "red"), 3: _record("Blue", "blue")}
	_manager._recompute_lobby()
	for peer_id in [2, 3]:
		var record: Dictionary = _manager._lobby[peer_id]
		record["lobby_ready"] = true
		record["character_id"] = "warrior"
		record["selection_ready"] = true
		_manager._lobby[peer_id] = record
	_director.begin_character_selection([2, 3])
	_director.tick_update(1800)
	assert_eq(_director.match_state.phase, MatchState.Phase.LOBBY)
	assert_eq(_manager.get_node("Players").get_child_count(), 0)
	for record in _manager._lobby.values():
		assert_false(record["lobby_ready"])
		assert_false(record["selection_ready"])
		assert_eq(record["character_id"], "")

func test_only_provisioned_creator_is_host_and_join_order_cannot_claim_it() -> void:
	_manager._on_room_creator_ticket_validated("creator")
	_manager._lobby = {2: _record("Joiner", "joiner"), 9: _record("Creator", "creator")}
	_manager._recompute_lobby()
	assert_false(_manager._lobby[2]["is_host"])
	assert_true(_manager._lobby[9]["is_host"])

func test_duplicate_authenticated_account_is_rejected_before_lobby_mutation() -> void:
	assert_true(_manager._admit_authenticated_identity(2, {"account_id": "account-1", "username": "First"}))
	assert_false(_manager._admit_authenticated_identity(3, {"account_id": "account-1", "username": "Duplicate"}))
	assert_eq(_manager._lobby.size(), 1)

func test_wrong_phase_mutation_guard_rejects_without_changing_ready_state() -> void:
	_manager._lobby = {2: _record("Player", "account-1")}
	_manager._recompute_lobby()
	_director.begin_character_selection([2])
	assert_false(_manager._set_lobby_ready_from_peer(2, true))
	assert_false(_manager._lobby[2]["lobby_ready"])

func test_actual_netfox_peer_leave_removes_lobby_member() -> void:
	_manager._lobby = {2: _record("Leaving", "leaving"), 3: _record("Remaining", "remaining")}
	_manager._recompute_lobby()
	NetworkEvents.on_peer_leave.emit(2)
	assert_false(_manager._lobby.has(2))
	assert_eq(_manager._lobby.size(), 1)

func test_snapshot_ready_state_updates_without_emitting_user_toggle() -> void:
	var menu: CanvasLayer = load("res://scenes/connection_menu.tscn").instantiate()
	add_child_autofree(menu)
	var ready: CheckButton = menu.get_node("TeamLobbyPanel/VBox/Ready")
	var selection_ready: CheckButton = menu.get_node("CharacterSelectPanel/VBox/Ready")
	var toggle_count := 0
	ready.toggled.connect(func(_pressed: bool) -> void: toggle_count += 1)
	menu._on_lobby_snapshot_received({"phase": MatchState.Phase.LOBBY, "team": TeamId.RED, "self_lobby_ready": true, "self_selection_ready": true, "is_host": false, "members": [], "red_members": [], "blue_members": [], "rejection": ""})
	assert_true(ready.button_pressed)
	assert_true(selection_ready.button_pressed)
	assert_eq(toggle_count, 0, "Authoritative rendering must not invoke the user RPC signal")

func test_empty_creator_ticket_cannot_request_noray_host() -> void:
	assert_eq(Noray.request_host(""), ERR_INVALID_PARAMETER)

func test_admission_rejection_returns_safe_room_message() -> void:
	var menu: CanvasLayer = load("res://scenes/connection_menu.tscn").instantiate()
	add_child_autofree(menu)
	menu._on_room_admission_rejected("Room is full")
	assert_eq(menu.get_node("RoomPanel/VBox/RoomStatus").text, "Room is full")
	assert_eq(menu.current_state, menu.State.ROOM)

func test_backend_validated_creator_event_establishes_host_identity() -> void:
	_manager._lobby = {2: _record("Creator", "creator")}
	EventBus.room_creator_ticket_validated.emit("creator")
	assert_true(_manager._lobby[2]["is_host"])

func test_peer_leave_during_character_selection_cancels_and_refreshes_lobby() -> void:
	_manager._on_room_creator_ticket_validated("creator")
	_manager._lobby = {2: _record("Creator", "creator"), 3: _record("Leaving", "leaving")}
	_manager._recompute_lobby()
	for peer_id in [2, 3]:
		var record: Dictionary = _manager._lobby[peer_id]
		record["team"] = TeamId.RED
		record["lobby_ready"] = true
		_manager._lobby[peer_id] = record
	assert_true(_manager.submit_character_select_start(2))
	assert_eq(_director.match_state.phase, MatchState.Phase.CHARACTER_SELECT)
	NetworkEvents.on_peer_leave.emit(3)
	assert_eq(_director.match_state.phase, MatchState.Phase.LOBBY)
	assert_eq(_manager.get_node("Players").get_child_count(), 0)
	assert_false(_manager._lobby[2]["lobby_ready"])
	assert_eq(_manager._snapshot_for(2)["phase"], MatchState.Phase.LOBBY)

func test_public_selection_handlers_enforce_host_and_phase_without_mutation() -> void:
	_manager._on_room_creator_ticket_validated("creator")
	_manager._lobby = {2: _record("Creator", "creator"), 3: _record("Joiner", "joiner")}
	_manager._recompute_lobby()
	for peer_id in [2, 3]:
		var record: Dictionary = _manager._lobby[peer_id]
		record["team"] = TeamId.RED
		record["lobby_ready"] = true
		_manager._lobby[peer_id] = record
	assert_false(_manager.submit_character_select_start(3))
	assert_eq(_director.match_state.phase, MatchState.Phase.LOBBY)
	assert_false(_manager.submit_character_selection(2, "warrior", true))
	assert_false(_manager._lobby[2]["selection_ready"])
	assert_true(_manager.submit_character_select_start(2))

func test_ui_disables_team_button_when_team_is_full() -> void:
	var menu: CanvasLayer = load("res://scenes/connection_menu.tscn").instantiate()
	add_child_autofree(menu)
	menu.current_state = menu.State.TEAM_LOBBY
	var snapshot := {
		"phase": MatchState.Phase.LOBBY,
		"team": TeamId.BLUE,
		"is_host": false,
		"self_lobby_ready": false,
		"self_selection_ready": false,
		"deadline_tick": 0,
		"members": [],
		"red_members": [{"name": "A", "lobby_ready": true, "character_id": "", "selection_ready": false}, {"name": "B", "lobby_ready": true, "character_id": "", "selection_ready": false}, {"name": "C", "lobby_ready": true, "character_id": "", "selection_ready": false}],
		"blue_members": [],
		"rejection": "",
	}
	menu._on_lobby_snapshot_received(snapshot)
	assert_true(menu.join_red_button.disabled, "Full RED team disables the RED button for a BLUE player")
	assert_false(menu.join_blue_button.disabled, "Empty BLUE team keeps the BLUE button enabled")

func test_ui_locks_ready_during_post_team_change_cooldown() -> void:
	var menu: CanvasLayer = load("res://scenes/connection_menu.tscn").instantiate()
	add_child_autofree(menu)
	menu.current_state = menu.State.TEAM_LOBBY
	menu._on_lobby_snapshot_received({"phase": MatchState.Phase.LOBBY, "team": TeamId.RED, "is_host": false, "self_lobby_ready": true, "self_selection_ready": false, "deadline_tick": 0, "members": [], "red_members": [], "blue_members": [], "rejection": ""})
	assert_true(menu.lobby_ready.button_pressed)
	menu._on_lobby_snapshot_received({"phase": MatchState.Phase.LOBBY, "team": TeamId.BLUE, "is_host": false, "self_lobby_ready": true, "self_selection_ready": false, "deadline_tick": 0, "members": [], "red_members": [], "blue_members": [], "rejection": ""})
	assert_false(menu.lobby_ready.button_pressed, "Team change clears READY visually")
	assert_true(menu.lobby_ready.disabled, "READY locked during the cooldown")
	assert_true(menu.lobby_ready.text.contains("team change"),
		"Cooldown countdown is rendered on the button label")
