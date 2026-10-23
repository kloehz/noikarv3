extends "res://tests/isolated_gut_test.gd"
## Exercise real menu/picker controls; only Steam's external SDK is replaced.
const Fixture := preload("res://tests/fixtures/steam_platform.gd")
var _menu: CanvasLayer
var _picker: Control
var _adapter: Node
var _session: Node
var _accounts: Node
var _platform: RefCounted
var _old_steam: Node
var _manager: Node3D

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
	_manager = Fixture.add_match_manager(self)
	assert_true(GameManager.get("steam") == null or GameManager.get("steam") is Node)
	_old_steam = GameManager.get("steam")
	if GameManager.get("steam") == null and not _has_steam_property(): return
	GameManager.steam = _adapter
	_menu = load("res://scenes/connection_menu.tscn").instantiate()
	add_child(_menu)
	_picker = _menu.get_node_or_null("SteamFriendPicker")

func _has_steam_property() -> bool:
	for property in GameManager.get_property_list():
		if property.name == "steam": return true
	return false

func after_each() -> void:
	if _menu != null: _menu.free()
	if _has_steam_property(): GameManager.steam = _old_steam
	_session.close()
	for frame in 4: await get_tree().process_frame
	_manager.free()
	_adapter.free()
	_accounts.free()
	_session.free()
	super.after_each()

func _open_picker() -> bool:
	assert_not_null(_picker, "Noikar menu needs an editable Steam friend picker")
	if _picker == null: return false
	assert_true(_adapter.initialize())
	# Real adapter friend-list rules need a host session and a free roster slot.
	_session.role = "LISTEN_HOST"
	_session.phase = "lobby"
	_session.transport = "steam"
	_adapter.lobby_id = Fixture.LOBBY
	_adapter._host_steam_id = Fixture.HOST
	_picker.open()
	return true

func test_existing_login_teams_and_characters_are_preserved_with_steam_controls() -> void:
	assert_not_null(_menu, "Steam should extend, not replace, the Noikar menu")
	if _menu == null: return
	for path in ["LoginPanel/Card/VBox/AccountEdit", "TeamLobbyPanel/Card/VBox/TeamChoices/JoinRedButton", "CharacterSelectPanel/Card/VBox/Characters/Ivern", "RoomPanel/Card/VBox/SteamBox/HostSteam", "RoomPanel/Card/VBox/SteamBox/JoinSteam", "TeamLobbyPanel/Card/VBox/InviteSteam"]:
		assert_not_null(_menu.get_node_or_null(path), path)
	assert_eq(_menu.get_node("RoomPanel/Card").get_theme_stylebox("panel"), _picker.get_node("Center/Card").get_theme_stylebox("panel"))

func test_open_and_refresh_never_send_and_row_targets_exact_64_bit_friend() -> void:
	if not _open_picker(): return
	assert_true(_picker.visible)
	_picker.refresh()
	assert_true(_platform.sends.is_empty())
	var rows: Array[Node] = _picker.get_node("Center/Card/VBox/Scroll/Rows").get_children()
	assert_eq(rows.size(), 2, "Hidden editable row template plus one friend")
	if rows.size() != 2: return
	var button := rows[1] as Button
	assert_eq(button.get_meta("steam_id"), Fixture.FRIEND)
	button.pressed.emit()
	assert_eq(_platform.sends, [[Fixture.LOBBY, Fixture.FRIEND]])
	assert_true(_picker.get_node("Center/Card/VBox/Status").text.contains("requested"))

func test_picker_closes_when_original_host_is_unavailable() -> void:
	if not _open_picker(): return
	_platform.owner = Fixture.FRIEND
	_picker._process(0.1)
	assert_false(_picker.visible)

func test_launch_invitation_requires_explicit_accept_after_login() -> void:
	assert_not_null(_menu)
	if _menu == null: return
	assert_true(_adapter.initialize())
	_adapter.accept_launch_invite(PackedStringArray(["+connect_lobby", str(Fixture.LOBBY)]))
	assert_true(_platform.joins.is_empty())
	assert_eq(_menu.room_id_edit.text, str(Fixture.LOBBY))
	assert_eq(_menu.current_state, _menu.State.LOGIN)
