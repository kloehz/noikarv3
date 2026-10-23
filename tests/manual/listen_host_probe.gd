extends SceneTree
## Independent process probe driven by the owned Go API/PostgreSQL fixture.
var _role := ""
var _rendezvous := ""
var _world: Node
var _menu: Node

func _init() -> void:
	call_deferred("run")

func _wait_until(predicate: Callable, seconds := 12.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if predicate.call(): return true
		await process_frame
	return false

func _fail(stage: String) -> void:
	print("LISTEN_HOST_RESULT ", JSON.stringify({"ok": false, "role": _role, "stage": stage}))
	quit(1)

func run() -> void:
	_role = OS.get_environment("NOIKAR_FIXTURE_ROLE")
	_rendezvous = OS.get_environment("NOIKAR_FIXTURE_RENDEZVOUS")
	var manager = root.get_node("GameManager")
	if not manager.has_method("host_player_lan"):
		_fail("Authenticated player-host orchestration is not implemented")
		return
	_world = load("res://scenes/main.tscn").instantiate()
	root.add_child(_world)
	current_scene = _world
	_menu = _world.get_node("ConnectionMenu")
	_menu.port_edit.value = int(OS.get_environment("NOIKAR_FIXTURE_GAME_PORT"))
	_menu.account_edit.text = "host-fixture" if _role == "host" else "guest-fixture"
	_menu.password_edit.text = "fixture-only-password"
	await _menu._on_enter_lobby_pressed()
	if _menu.current_state != _menu.State.ROOM:
		_fail("login")
		return
	if _role == "host":
		await _menu._on_host_pressed()
		if manager.session.role != "LISTEN_HOST" or not _world.get_lobby_peer_ids().has(1):
			_fail("host attachment/local account admission")
			return
		var file := FileAccess.open(_rendezvous, FileAccess.WRITE)
		file.store_string(JSON.stringify({"room_id": manager.session.room_id}))
		file.close()
	else:
		if not await _wait_until(func(): return FileAccess.file_exists(_rendezvous)):
			_fail("host rendezvous")
			return
		var room: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_rendezvous))
		_menu.room_id_edit.text = room.room_id
		_menu.noray_address_edit.text = "127.0.0.1"
		await _menu._on_join_pressed()
	if not await _wait_until(func(): return _menu.current_state == _menu.State.TEAM_LOBBY):
		_fail("account admitted/team lobby")
		return
	if _role == "host" and not await _wait_until(func(): return _world.get_lobby_peer_ids().size() == 2):
		_fail("guest account admission")
		return
	_menu._on_team_choice_pressed(TeamId.RED if _role == "host" else TeamId.BLUE)
	_menu._on_lobby_ready_toggled(true)
	if _role == "host":
		if not await _wait_until(func(): return _world._all_lobby_ready()):
			_fail("both teams ready")
			return
		_menu._on_start_selection_pressed()
	if not await _wait_until(func(): return _menu.current_state == _menu.State.CHARACTER_SELECT):
		_fail("character selection")
		return
	_menu._on_character_pressed("warrior")
	_menu._on_selection_ready_toggled(true)
	if not await _wait_until(func(): return _world.get_node("Players").get_child_count() == 2):
		_fail("two authoritative spawns")
		return
	var id: int = root.multiplayer.get_unique_id()
	var player := _world.get_node("Players/" + str(id))
	var combat := player.get_node("CombatComponent")
	var attacks_before: int = combat.sync_attack_count
	var origin: Vector3 = player.global_position
	var damage_once := true
	var drop_once := true
	if _role == "host":
		var mob = _world.spawn_enemy("HECARIM_TANK", Vector3.ZERO, 0.0, TeamId.RED)
		var health: Node = mob.get_node("HealthComponent")
		var health_before: int = health.current_health
		var souls_before: int = _world.get_node("Souls").get_child_count()
		health.take_damage(17)
		damage_once = health.current_health == health_before - 17
		health.take_damage(health.current_health)
		_world._on_entity_died(mob)
		drop_once = _world.get_node("Souls").get_child_count() == souls_before + 1
	Input.action_press("move_forward")
	Input.action_press("shoot")
	await create_timer(1.2).timeout
	Input.action_release("move_forward")
	Input.action_release("shoot")
	var moved: bool = player.global_position.distance_to(origin) > 0.1
	var attacked: bool = combat.sync_attack_count > attacks_before
	var presentation: bool = player.has_node("CameraPivot/Camera3D") and _world.has_node("HUD")
	if OS.get_environment("NOIKAR_FIXTURE_NPC_MOTION") == "1":
		if not await _exercise_pet_motion():
			_fail("independent guest pet source-time motion")
			return
	if _role == "host":
		if not await _wait_until(func(): return FileAccess.file_exists(_rendezvous + ".guest-ready")):
			_fail("guest movement/attack receipt")
			return
		manager.session.close("Integration host departure")
	else:
		var ready := FileAccess.open(_rendezvous + ".guest-ready", FileAccess.WRITE)
		ready.store_string("ready")
		ready.close()
	if not await _wait_until(func(): return manager.session.phase == "menu"):
		_fail("return to menu after host departure")
		return
	# A stale empty-room callback must not quit a player's application after
	# its hosted world has been torn down and replaced by the menu.
	current_scene._auto_shutdown()
	await process_frame
	var ok: bool = moved and attacked and presentation and damage_once and drop_once and not root.get_node("AuthService").access_token.is_empty() and root.get_node("NetworkTime")._state == root.get_node("NetworkTime")._STATE_INACTIVE
	print("LISTEN_HOST_RESULT ", JSON.stringify({"ok": ok, "role": _role, "login": true, "local_peer": id, "spawned_players": 2, "movement": moved, "attack": attacked, "presentation": presentation, "damage_once": damage_once, "drop_once": drop_once, "clock_inactive_after_close": true, "login_preserved": true, "rendered": DisplayServer.get_name() != "headless"}))
	quit(0 if ok else 1)

## Opt-in fixture setup only: create a real authoritative pet for the guest.
## This does not certify earning souls or completing a summoning totem.
func _exercise_pet_motion() -> bool:
	if _role == "host":
		var guest_id: int = _world.get_lobby_peer_ids().filter(func(id): return id != 1)[0]
		var guest: Node3D = _world.get_node("Players/" + str(guest_id))
		_world._on_totem_complete(guest_id, 2, 5, guest.global_position + Vector3(7, 0, 0))
		return true
	if not await _wait_until(func(): return get_nodes_in_group("pets").size() > 0):
		return false
	var pet := get_nodes_in_group("pets")[0] as Node3D
	var player: Node3D = _world.get_node("Players/" + str(root.multiplayer.get_unique_id()))
	var rows: Array = []
	var initial: Vector3 = pet.global_position
	Input.action_press("move_forward")
	var deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and is_instance_valid(pet):
		await RenderingServer.frame_post_draw
		var interpolator := pet.get_node("TickInterpolator")
		rows.append({"usec": Time.get_ticks_usec(), "delta": interpolator.get_process_delta_time(), "position": [pet.global_position.x, pet.global_position.y, pet.global_position.z], "buffered": interpolator._uses_sparse_mode(), "source_tick": interpolator.get("_snapshot_buffer").latest_tick})
	Input.action_release("move_forward")
	var moved := is_instance_valid(pet) and pet.global_position.distance_to(initial) > 0.5
	var quality: Dictionary = load("res://tests/manual/npc_motion_metrics.gd").evaluate(rows, pet.get_node("LogicComponent").max_speed)
	var result := {"ok": moved and quality.ok, "quality": quality, "transport": "ENet", "authority": 1, "fixture_spawn": true, "full_summon_flow_verified": false, "pet_moved": moved, "samples": rows, "owner_position": str(player.global_position)}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/artifacts"))
	var file := FileAccess.open("res://tests/artifacts/npc-pet-lan.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	print("NPC_PET_RESULT ", JSON.stringify({"ok": result.ok, "pet_moved": moved, "quality": quality, "fixture_spawn": true}))
	return result.ok
