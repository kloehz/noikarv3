extends GutTest
## The host uses the existing roster and validated handlers, never fake RPC IDs.
var _manager: Node3D
var _director: MatchDirector
var _old_peer: MultiplayerPeer
var _old_role: String
var _old_phase: String

func before_each() -> void:
	_old_peer = multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_old_role = GameManager.session.role
	_old_phase = GameManager.session.phase
	GameManager.session.role = "LISTEN_HOST"
	GameManager.session.phase = "lobby"
	_manager = load("res://common/match_manager.gd").new()
	for name in ["Players", "Mobs", "Souls", "Totems", "Projectiles"]:
		var container := Node3D.new()
		container.name = name
		_manager.add_child(container)
	var map := Node3D.new()
	map.name = "Map"
	_manager.add_child(map)
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	map.add_child(spawn_points)
	for name in ["TeamRedSpawn", "TeamBlueSpawn"]:
		var marker := Marker3D.new()
		marker.name = name
		spawn_points.add_child(marker)
	var state := MatchState.new()
	state.name = "MatchState"
	_manager.add_child(state)
	_director = MatchDirector.new()
	_director.rules = load("res://common/resources/default_match_rules.tres")
	_director.match_state = state
	_manager.add_child(_director)
	add_child(_manager)
	NetworkTime.after_tick.disconnect(_director._on_after_tick)

func after_each() -> void:
	# Let actual Netfox deferred setup finish before freeing its test world.
	await get_tree().process_frame
	_manager.free()
	GameManager.session.role = _old_role
	GameManager.session.phase = _old_phase
	multiplayer.multiplayer_peer = _old_peer

func _admit_host() -> bool:
	assert_true(_manager.has_method("admit_local_host"), "The local host must enter the real account roster")
	if not _manager.has_method("admit_local_host"): return false
	return _manager.admit_local_host({"account_id": "host-account", "username": "Host"})

func test_host_peer_one_account_team_ready_and_character_selection() -> void:
	if not _admit_host(): return
	assert_eq(_manager.get_lobby_peer_ids(), [1])
	assert_true(_manager._lobby[1].is_host)
	assert_true(_manager.submit_team_choice(1, TeamId.RED))
	assert_true(_manager._set_lobby_ready_from_peer(1, true))
	assert_true(_manager.submit_character_select_start(1))
	assert_true(_manager.submit_character_selection(1, "ivern_ranger", false))
	assert_eq(_manager._lobby[1].character_id, "ivern_ranger")

func test_local_snapshot_is_delivered_without_rpc_to_self() -> void:
	if not _admit_host(): return
	watch_signals(EventBus)
	_manager._broadcast_lobby_snapshots()
	assert_signal_emitted_with_parameters(EventBus, "lobby_snapshot_received", [_manager._snapshot_for(1)])
	assert_false(_manager._snapshot_for(1).has("account_id"))

func test_six_total_three_per_team_and_last_slot_claims_include_host() -> void:
	if not _admit_host(): return
	for id in range(2, 6):
		assert_true(_manager._admit_authenticated_identity(id, {"account_id": "account-%d" % id, "username": "Guest%d" % id}))
	assert_true(_manager._admit_authenticated_identity(6, {"account_id": "last-account", "username": "Last"}))
	assert_false(_manager._admit_authenticated_identity(7, {"account_id": "seventh", "username": "Seventh"}))
	for id in [1, 2, 3]: assert_true(_manager.submit_team_choice(id, TeamId.RED))
	assert_false(_manager.submit_team_choice(4, TeamId.RED))
	for id in [4, 5, 6]: assert_true(_manager.submit_team_choice(id, TeamId.BLUE))
	assert_eq(_manager._team_member_count(TeamId.RED), 3)
	assert_eq(_manager._team_member_count(TeamId.BLUE), 3)
	assert_eq(_manager.get_lobby_peer_ids().size(), 6)

func test_duplicate_host_account_and_guest_selection_start_are_rejected() -> void:
	if not _admit_host(): return
	assert_false(_manager._admit_authenticated_identity(2, {"account_id": "host-account", "username": "Duplicate"}))
	assert_true(_manager._admit_authenticated_identity(2, {"account_id": "guest", "username": "Guest"}))
	assert_true(_manager.submit_team_choice(1, TeamId.RED))
	assert_true(_manager.submit_team_choice(2, TeamId.BLUE))
	assert_true(_manager._set_lobby_ready_from_peer(1, true))
	assert_true(_manager._set_lobby_ready_from_peer(2, true))
	assert_false(_manager.submit_character_select_start(2))
	assert_true(_manager.submit_character_select_start(1))
	_director.cancel_character_selection()
	assert_false(_manager.submit_character_selection(1, "warrior", true))
	assert_false(_manager._lobby[1].selection_ready)

func test_host_player_spawns_only_once_with_camera_and_input() -> void:
	if not _admit_host(): return
	assert_true(_manager.submit_team_choice(1, TeamId.RED))
	_manager._lobby[1].character_id = "warrior"
	_manager._spawn_player(1)
	_manager._spawn_player(1)
	assert_eq(_manager.get_node("Players").get_child_count(), 1)
	var player := _manager.get_node("Players/1")
	assert_eq(player.get_multiplayer_authority(), 1)
	assert_true(player.has_node("CameraPivot/Camera3D"))
	assert_true(player.has_node("LogicComponent"))

func test_host_menu_intents_use_validated_local_handlers_not_rpc_to_self() -> void:
	if not _admit_host(): return
	var menu = load("res://scenes/connection_menu.tscn").instantiate()
	add_child_autofree(menu)
	menu._on_lobby_snapshot_received(_manager._snapshot_for(1))
	menu._on_team_choice_pressed(TeamId.RED)
	assert_eq(_manager.get_team_for(1), TeamId.RED)
	menu._on_lobby_ready_toggled(true)
	assert_true(_manager._lobby[1].lobby_ready)
	menu._on_start_selection_pressed()
	assert_eq(_director.match_state.phase, MatchState.Phase.CHARACTER_SELECT)
	menu._on_character_pressed("ivern_ranger")
	assert_eq(_manager._lobby[1].character_id, "ivern_ranger")
	menu._on_selection_ready_toggled(true)
	assert_eq(_director.match_state.phase, MatchState.Phase.COUNTDOWN)
	assert_eq(_manager.get_node("Players").get_child_count(), 1)

func test_host_tick_moves_and_decrements_each_cooldown_once() -> void:
	if not _admit_host(): return
	_manager._lobby[1].character_id = "warrior"
	_manager._spawn_player(1)
	await get_tree().physics_frame
	var player := _manager.get_node("Players/1")
	var logic := player.get_node("LogicComponent")
	var combat := player.get_node("CombatComponent")
	logic.input_axis = Vector2.RIGHT
	logic.current_velocity = Vector3.ZERO
	logic.dash_cooldown = 1.0
	combat._primary_cooldown = 1.0
	var start: Vector3 = player.global_position
	var dt := 1.0 / 30.0
	logic._rollback_tick(dt, 100, true)
	combat._rollback_tick(dt, 100, true)
	player._on_authoritative_tick(dt, 100)
	assert_almost_eq(logic.dash_cooldown, 1.0 - dt, 0.00001)
	assert_almost_eq(combat._primary_cooldown, 1.0 - dt, 0.00001)
	assert_almost_eq(logic.current_velocity.x, minf(logic.max_speed, logic.acceleration * 10.0 * dt), 0.001, "Movement acceleration is applied once, not separately for host/client roles")
	assert_gt(player.global_position.x, start.x)
	combat._primary_cooldown = 0.0
	logic.is_shooting = true
	var before: int = combat.sync_attack_count
	combat._rollback_tick(dt, 101, true)
	player._on_authoritative_tick(dt, 101)
	assert_eq(combat.sync_attack_count, before + 1)

func test_host_authoritative_damage_is_applied_once() -> void:
	if not _admit_host(): return
	var mob := load("res://scenes/EnemyEntity.tscn").instantiate() as EnemyEntity
	mob.name = "MOB_DAMAGE_FIXTURE"
	mob.configure_enemy("HECARIM_TANK")
	# Keep this test's boundary at authoritative health. The native two-process
	# gate exercises real graphical impact/death/drop presentation separately.
	var visual := mob.get_node("VisualComponent")
	mob.remove_child(visual)
	visual.free()
	_manager.get_node("Mobs").add_child(mob)
	await get_tree().process_frame
	var health: Node = mob.get_node("HealthComponent")
	var before: int = health.current_health
	assert_eq(health.take_damage(17), 17)
	assert_eq(health.current_health, before - 17)
