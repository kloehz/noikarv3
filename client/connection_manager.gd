extends CanvasLayer

const DEFAULT_PORT := 7777
const GAME_CONNECTION_TIMEOUT_SEC := 12.0

@onready var login_panel: Control = $LoginPanel
@onready var room_panel: Control = $RoomPanel
@onready var team_lobby_panel: Control = $TeamLobbyPanel
@onready var character_select_panel: Control = $CharacterSelectPanel
@onready var connecting_panel: Control = $ConnectingPanel
@onready var bg_rect: ColorRect = $Background
@onready var account_edit: LineEdit = $LoginPanel/Card/VBox/AccountEdit
@onready var password_edit: LineEdit = $LoginPanel/Card/VBox/PasswordEdit
@onready var login_status: Label = $LoginPanel/Card/VBox/LoginStatus
@onready var room_id_edit: LineEdit = $RoomPanel/Card/VBox/JoinBox/RoomIDEdit
@onready var noray_address_edit: LineEdit = $RoomPanel/Card/VBox/SettingsBox/AddressEdit
@onready var status_label: Label = $ConnectingPanel/VBox/StatusLabel
@onready var room_info: Label = $HUD/RoomInfo
@onready var room_status: Label = $RoomPanel/Card/VBox/RoomStatus
@onready var lobby_status: Label = $TeamLobbyPanel/Card/VBox/Status
@onready var lobby_ready: CheckButton = $TeamLobbyPanel/Card/VBox/Ready
@onready var start_selection: Button = $TeamLobbyPanel/Card/VBox/StartSelection
@onready var join_red_button: Button = $TeamLobbyPanel/Card/VBox/TeamChoices/JoinRedButton
@onready var join_blue_button: Button = $TeamLobbyPanel/Card/VBox/TeamChoices/JoinBlueButton
@onready var red_roster: Label = $TeamLobbyPanel/Card/VBox/TeamRosters/RedRoster
@onready var blue_roster: Label = $TeamLobbyPanel/Card/VBox/TeamRosters/BlueRoster
@onready var selection_roster: Label = $CharacterSelectPanel/Card/VBox/Roster
@onready var selection_status: Label = $CharacterSelectPanel/Card/VBox/Status
@onready var selection_ready: CheckButton = $CharacterSelectPanel/Card/VBox/Ready
@onready var deadline: Label = $CharacterSelectPanel/Card/VBox/Deadline
@onready var aatrox_button: Button = $CharacterSelectPanel/Card/VBox/Characters/Aatrox
@onready var ivern_button: Button = $CharacterSelectPanel/Card/VBox/Characters/Ivern
@onready var boss_health_bar: Control = $HUD/BossHealthBar

var _active_peer: ENetMultiplayerPeer
var _game_connection_attempt := 0
var _current_oid := ""
var _snapshot: Dictionary = {}
var _selected_character := "warrior"
## Boss whose ServerState.boss_damage_changed drives the HUD bar. Re-resolved
## every poll in case the boss spawns/despawns during the match.
var _tracked_boss: Node = null

enum State { LOGIN, ROOM, CONNECTING, TEAM_LOBBY, CHARACTER_SELECT, IN_GAME }
var current_state := State.LOGIN

## Local team echoed from the latest snapshot. Compared against incoming
## snapshots to detect a server-side team change and start the visual cooldown.
var _local_team: int = TeamId.NONE
## Time.get_ticks_msec() deadline after which the local READY lock expires.
## Driven from the snapshot's team field, not from a per-button press, so the
## client cannot bypass the cooldown by re-pressing the same team button.
var _team_change_cooldown_until_ms: int = 0
const _TEAM_CHANGE_COOLDOWN_MS: int = 3000

func _ready() -> void:
	# Provisioned rooms load main.tscn too, which includes this menu. The
	# server already owns Noray.local_port for its ENet listener; letting the
	# client-only manager react to Noray's `connect` command would make it try
	# to bind a second ENet host to that same port.
	if _is_provisioned_server_process():
		queue_free()
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	EventBus.phase_changed.connect(_on_match_phase_changed)
	EventBus.game_server_authenticated.connect(_on_game_server_authenticated)
	EventBus.lobby_snapshot_received.connect(_on_lobby_snapshot_received)
	EventBus.room_admission_rejected.connect(_on_room_admission_rejected)
	Noray.on_connect_nat.connect(_on_noray_connect_nat)
	Noray.on_connect_relay.connect(_on_noray_connect_relay)
	account_edit.text_submitted.connect(_on_login_field_submitted)
	password_edit.text_submitted.connect(_on_login_field_submitted)
	_switch_state(State.LOGIN)
	var tween := create_tween().set_loops()
	tween.tween_property(bg_rect, "color", Color("1a1a2e"), 4.0)
	tween.tween_property(bg_rect, "color", Color("16213e"), 4.0)

func _is_provisioned_server_process() -> bool:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	return args.has("--server")

func _switch_state(new_state: State) -> void:
	current_state = new_state
	bg_rect.visible = new_state != State.IN_GAME
	login_panel.visible = new_state == State.LOGIN
	room_panel.visible = new_state == State.ROOM or new_state == State.CONNECTING
	team_lobby_panel.visible = new_state == State.TEAM_LOBBY
	character_select_panel.visible = new_state == State.CHARACTER_SELECT
	connecting_panel.visible = new_state == State.CONNECTING
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if new_state == State.IN_GAME else Input.MOUSE_MODE_VISIBLE
	match new_state:
		State.LOGIN: account_edit.grab_focus()
		State.ROOM: $RoomPanel/Card/VBox/HostBox/HostButton.grab_focus()
		State.TEAM_LOBBY: lobby_ready.grab_focus()
		State.CHARACTER_SELECT: aatrox_button.grab_focus()

func _on_enter_lobby_pressed() -> void:
	var result: Dictionary = await AuthService.login(account_edit.text, password_edit.text)
	_finish_auth(result)

func _on_login_field_submitted(_text: String) -> void:
	_on_enter_lobby_pressed()

func _on_register_pressed() -> void:
	var result: Dictionary = await AuthService.register(account_edit.text, password_edit.text)
	_finish_auth(result)

func _finish_auth(result: Dictionary) -> void:
	if not result.get("accepted", false):
		login_status.text = str(result.get("reason", "Could not sign in"))
		return
	password_edit.clear()
	login_status.text = ""
	_switch_state(State.ROOM)

func _on_host_pressed() -> void:
	_start_noray_flow(true)

func _on_join_pressed() -> void:
	_current_oid = room_id_edit.text.strip_edges()
	if not _current_oid.is_empty(): _start_noray_flow(false)

func _start_noray_flow(as_host: bool) -> void:
	_switch_state(State.CONNECTING)
	status_label.text = "Connecting to Noray..."
	var noray_addr := noray_address_edit.text.strip_edges()
	if noray_addr.is_empty(): noray_addr = "72.60.58.24"
	if not Noray.is_connected_to_host():
		if await Noray.connect_to_host(noray_addr) != OK:
			_fail_connection("Could not connect to Noray")
			return
	if as_host:
		var ticket_result: Dictionary = await AuthService.issue_room_creator_ticket()
		if not ticket_result.get("accepted", false):
			_fail_connection("Could not obtain a room creator ticket")
			return
		if Noray.request_host(str(ticket_result["ticket"])) != OK:
			_fail_connection("Could not provision a creator-bound room")
			return
		# Race host-ready against error + watchdog timeout: noray can refuse
		# the provisioning (bad ticket, spawn failure) and only sends
		# `error <reason>`, or the spawned headless server can crash before
		# reaching register-server / server-ready. Without the race + timeout
		# this await would hang forever and the user would see "Connecting
		# to Noray..." with no progress.
		_current_oid = await _await_host_provisioning()
	if _current_oid.is_empty():
		return
	Noray.register_host()
	if Noray.oid.is_empty(): await Noray.on_oid
	if Noray.pid.is_empty(): await Noray.on_pid
	if await Noray.register_remote() != OK:
		_fail_connection("Could not register the room connection")
		return
	# Relay instead of NAT: rooms always run on the VPS next to noray, so the
	# relay hop is loopback-internal and the game traffic uses the already-open
	# relay port range (20000-22048). NAT mode would hand clients the host's
	# registered address — 127.0.0.1, since the server registers over loopback.
	Noray.connect_relay(_current_oid)

func _on_noray_connect_nat(address: String, port: int) -> void:
	_connect_to_peer(address, port)

func _on_noray_connect_relay(address: String, port: int) -> void:
	_connect_to_peer(address, port)

## Waits for either `Noray.on_host_ready` or `Noray.on_error`, whichever fires
## first, up to a watchdog timeout. Returns the OID on success, or an empty
## string if noray refused the provisioning or never answered. Without this
## race + timeout the await on `on_host_ready` would hang forever when noray
## replies with `error <reason>` instead of `host-ready`, or when the spawned
## headless server fails before sending register-server / server-ready.
func _await_host_provisioning() -> String:
	# GDScript 4 lambdas capture primitives (bool, int, String) by VALUE, so
	# the race state has to live inside reference-typed containers if the
	# resolver wants to publish results back to this coroutine.
	var done: Array = [false]
	var result: Array = [""]
	var ready_cb := func(oid: String) -> void:
		if done[0]:
			return
		done[0] = true
		result[0] = oid
	var error_cb := func(reason: String) -> void:
		if done[0]:
			return
		done[0] = true
		_fail_connection("Noray refused the request: " + reason)
		result[0] = ""
	var timer_cb := func() -> void:
		if done[0]:
			return
		done[0] = true
		_fail_connection("Provisioning timed out — headless server did not become ready")
		result[0] = ""
	Noray.on_host_ready.connect(ready_cb, CONNECT_ONE_SHOT)
	Noray.on_error.connect(error_cb, CONNECT_ONE_SHOT)
	# Watchdog covers the case where the spawned Godot process exits silently
	# (e.g. ticket validation failed, no `register-server` / `server-ready`).
	# 20s gives the headless server plenty of time to start on a cold cache.
	var watchdog: SceneTreeTimer = get_tree().create_timer(20.0)
	watchdog.timeout.connect(timer_cb, CONNECT_ONE_SHOT)
	while not done[0]:
		await get_tree().process_frame
	return result[0]

func _connect_to_peer(address: String, port: int) -> void:
	_game_connection_attempt += 1
	var attempt := _game_connection_attempt
	status_label.text = "Connecting to game server..."
	_active_peer = ENetMultiplayerPeer.new()
	if _active_peer.create_client(address, port, 0, 0, 0, Noray.local_port) != OK:
		_fail_connection("Could not start the game connection")
		return
	multiplayer.multiplayer_peer = _active_peer
	PacketHandshake.over_enet_peer(_active_peer, address, port)
	_watch_game_connection(attempt, _active_peer)

func _watch_game_connection(attempt: int, peer: ENetMultiplayerPeer) -> void:
	await get_tree().create_timer(GAME_CONNECTION_TIMEOUT_SEC).timeout
	if attempt != _game_connection_attempt or peer != _active_peer:
		return
	if peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING:
		_fail_connection("Timed out connecting to the game server")

func _on_connected_to_server() -> void:
	_game_connection_attempt += 1
	status_label.text = "Validating account..."
	EventBus.player_auth_token_submitted.emit(AuthService.access_token)

func _on_game_server_authenticated(_username: String) -> void:
	room_info.text = "SALA: " + _current_oid

func _on_room_admission_rejected(reason: String) -> void:
	room_status.text = reason
	_switch_state(State.ROOM)

func _on_lobby_snapshot_received(snapshot: Dictionary) -> void:
	_snapshot = snapshot.duplicate(true)
	_render_snapshot()
	var phase := int(_snapshot.get("phase", MatchState.Phase.LOBBY))
	if phase == MatchState.Phase.LOBBY:
		_switch_state(State.TEAM_LOBBY)
	elif phase == MatchState.Phase.CHARACTER_SELECT:
		_switch_state(State.CHARACTER_SELECT)

func _render_snapshot() -> void:
	var members: Array = _snapshot.get("members", [])
	var lines: Array[String] = ["Your team"]
	for member in members:
		lines.append("%s  %s%s" % [str(member.get("name", "Player")), "Ready" if member.get("lobby_ready", false) else "Waiting", " · " + str(member.get("character_id", "")) if not str(member.get("character_id", "")).is_empty() else ""])
	selection_roster.text = "\n".join(lines)
	var new_team: int = int(_snapshot.get("team", TeamId.NONE))
	if new_team != _local_team and _local_team != TeamId.NONE:
		_team_change_cooldown_until_ms = Time.get_ticks_msec() + _TEAM_CHANGE_COOLDOWN_MS
		lobby_ready.set_pressed_no_signal(false)
	_local_team = new_team
	var max_per_team: int = _max_players_per_team()
	var red_members: Array = _snapshot.get("red_members", [])
	var blue_members: Array = _snapshot.get("blue_members", [])
	red_roster.text = _format_team_roster("RED", red_members, max_per_team)
	blue_roster.text = _format_team_roster("BLUE", blue_members, max_per_team)
	var red_full: bool = red_members.size() >= max_per_team
	var blue_full: bool = blue_members.size() >= max_per_team
	join_red_button.disabled = red_full and _local_team != TeamId.RED
	join_blue_button.disabled = blue_full and _local_team != TeamId.BLUE
	join_red_button.text = _format_team_button("RED", red_members.size(), max_per_team, _local_team == TeamId.RED, red_full and _local_team != TeamId.RED)
	join_blue_button.text = _format_team_button("BLUE", blue_members.size(), max_per_team, _local_team == TeamId.BLUE, blue_full and _local_team != TeamId.BLUE)
	_apply_ready_cooldown()
	if not lobby_ready.disabled:
		lobby_ready.set_pressed_no_signal(bool(_snapshot.get("self_lobby_ready", false)))
	var selected_character := str(_snapshot.get("self_character_id", ""))
	if not selected_character.is_empty():
		_selected_character = selected_character
	_set_character_selection(selected_character)
	selection_ready.set_pressed_no_signal(bool(_snapshot.get("self_selection_ready", false)))
	start_selection.visible = bool(_snapshot.get("is_host", false))
	lobby_status.text = str(_snapshot.get("rejection", ""))
	selection_status.text = str(_snapshot.get("rejection", ""))
	deadline.text = "Selection deadline tick: %d" % int(_snapshot.get("deadline_tick", 0))

func _format_team_roster(label: String, members: Array, max_per_team: int) -> String:
	var header := "%s (%d/%d)" % [label, members.size(), max_per_team]
	if members.is_empty():
		return "%s\n(empty)" % header
	var names: Array[String] = [header]
	for member in members:
		var ready_marker := "R" if member.get("lobby_ready", false) else "-"
		names.append("[%s] %s" % [ready_marker, str(member.get("name", "Player"))])
	return "\n".join(names)

func _format_team_button(label: String, count: int, max_per_team: int, is_self: bool, full: bool) -> String:
	var suffix := ""
	if is_self: suffix = " (YOUR TEAM)"
	elif full: suffix = " (FULL)"
	return "%s %d/%d%s" % [label, count, max_per_team, suffix]

func _apply_ready_cooldown() -> void:
	var now_ms := Time.get_ticks_msec()
	if now_ms < _team_change_cooldown_until_ms:
		var remaining: float = float(_team_change_cooldown_until_ms - now_ms) / 1000.0
		lobby_ready.disabled = true
		lobby_ready.text = "READY (team change %.1fs)" % remaining
	else:
		lobby_ready.disabled = _local_team == TeamId.NONE
		lobby_ready.text = "READY"

func _max_players_per_team() -> int:
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	if manager and "rules" in manager and manager.rules and "max_players_per_team" in manager.rules:
		return int(manager.rules.max_players_per_team)
	return 3

## Polls the Mobs container for a BOSS_* entity and keeps the BossHealthBar
## wired to its replicated damage counters. The boss can spawn and despawn
## during the match (boss entity is freed on death), so we re-resolve the
## reference every tick. Connecting twice to the same source is a no-op
## because we compare instance ids before subscribing.
func _refresh_boss_health_bar() -> void:
	if boss_health_bar == null: return
	var boss: Node = _find_boss_entity()
	if boss != _tracked_boss:
		_tracked_boss = boss
		if boss == null:
			boss_health_bar.visible = false
			return
		var server_state: Node = boss.get_node_or_null("ServerState")
		if server_state == null:
			boss_health_bar.visible = false
			return
		boss_health_bar.visible = true
		boss_health_bar.set_label("BOSS")
		server_state.boss_damage_changed.connect(_on_boss_damage_changed.bind(boss, server_state))
		# Paint the current values immediately (the boss may have taken
		# damage on the server before we discovered it).
		var max_hp: int = int(boss.max_health) if "max_health" in boss else 100
		_on_boss_damage_changed(int(server_state.red_damage_taken),
			int(server_state.blue_damage_taken), boss, server_state, max_hp)

func _find_boss_entity() -> Node:
	var manager := get_tree().get_first_node_in_group(&"match_manager")
	if manager == null: return null
	var mobs: Node = manager.get_node_or_null("Mobs")
	if mobs == null: return null
	for child in mobs.get_children():
		if String(child.name).begins_with("BOSS_"):
			return child
	return null

func _on_boss_damage_changed(red_damage: int, blue_damage: int, _boss: Node, server_state: Node, max_hp: int = -1) -> void:
	if boss_health_bar == null: return
	if max_hp < 0 and _boss and "max_health" in _boss:
		max_hp = int(_boss.max_health)
	boss_health_bar.set_damage(red_damage, blue_damage, max(1, max_hp))

func _process(_delta: float) -> void:
	# The final refresh at expiry is what re-enables READY. Restrict this to
	# the lobby so other menu states do not overwrite the control's state.
	if current_state == State.TEAM_LOBBY:
		_apply_ready_cooldown()
	_refresh_boss_health_bar()

func _on_lobby_ready_toggled(ready: bool) -> void:
	if multiplayer.has_multiplayer_peer(): get_tree().get_first_node_in_group(&"match_manager").request_lobby_ready.rpc_id(1, ready)

func _on_team_choice_pressed(team: int) -> void:
	if team != TeamId.RED and team != TeamId.BLUE: return
	if _local_team == team: return
	if Time.get_ticks_msec() < _team_change_cooldown_until_ms: return
	if multiplayer.has_multiplayer_peer():
		get_tree().get_first_node_in_group(&"match_manager").request_team_choice.rpc_id(1, team)
	else:
		_local_team = team
		_team_change_cooldown_until_ms = Time.get_ticks_msec() + _TEAM_CHANGE_COOLDOWN_MS
		lobby_ready.set_pressed_no_signal(false)
		_apply_ready_cooldown()

func _on_start_selection_pressed() -> void:
	if multiplayer.has_multiplayer_peer(): get_tree().get_first_node_in_group(&"match_manager").request_character_select_start.rpc_id(1)

func _on_character_pressed(character_id: String) -> void:
	_selected_character = character_id
	_set_character_selection(character_id)
	selection_status.text = "Selected " + character_id
	if multiplayer.has_multiplayer_peer(): get_tree().get_first_node_in_group(&"match_manager").request_character_selection.rpc_id(1, character_id, false)

func _set_character_selection(character_id: String) -> void:
	aatrox_button.set_pressed_no_signal(character_id == "warrior")
	ivern_button.set_pressed_no_signal(character_id == "ivern_ranger")

func _on_selection_ready_toggled(ready: bool) -> void:
	if multiplayer.has_multiplayer_peer(): get_tree().get_first_node_in_group(&"match_manager").request_character_selection.rpc_id(1, _selected_character, ready)

func _on_match_phase_changed(phase: int) -> void:
	if phase == MatchState.Phase.COUNTDOWN: _switch_state(State.IN_GAME)

func _on_connection_failed() -> void: _fail_connection("Game server connection failed")
func _on_server_disconnected() -> void: _fail_connection("Disconnected from game server")
func _fail_connection(message: String) -> void:
	_game_connection_attempt += 1
	if _active_peer:
		_active_peer.close()
		if multiplayer.multiplayer_peer == _active_peer:
			multiplayer.multiplayer_peer = null
		_active_peer = null
	status_label.text = message
	_switch_state(State.ROOM)
