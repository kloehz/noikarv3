# tests/integration/test_spawn_routing.gd
extends GutTest

## Integration tests for PR3 spawn routing + team wiring: typed containers and
## per-container spawners in main.tscn, behavior-preserving routing (name
## prefixes and BaseEntity group detection unchanged), roster-driven team_id,
## deterministic team registry order, match-seed wiring into spawn ids, and
## solo/free play without a director. Runs headless with
## OfflineMultiplayerPeer; the live NetworkTime autoload hookup of the harness
## director is disconnected (no synthetic ticks needed here).

const MAIN_SCRIPT := "res://common/match_manager.gd"

var _main: Node3D
var _director: MatchDirector

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_main = null
	_director = null

func after_each() -> void:
	if is_instance_valid(_main):
		_main.queue_free()
	_main = null
	_director = null
	multiplayer.multiplayer_peer = null

## Builds a Main-like harness: MatchManager script + typed containers +
## MatchState, optionally with a MatchDirector (injected roster). The harness
## matches the main.tscn structure without the menu/HUD nodes.
func _make_main(with_director: bool = true, roster: Array[int] = [1, 2, 3, 4]) -> Node3D:
	var main: Node3D = load(MAIN_SCRIPT).new()
	for container_name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new()
		container.name = container_name
		main.add_child(container)
	var map := Node3D.new()
	map.name = "Map"
	var spawn_points := Node3D.new()
	spawn_points.name = "SpawnPoints"
	for marker_name in ["TeamRedSpawn", "TeamBlueSpawn"]:
		var marker := Marker3D.new()
		marker.name = marker_name
		spawn_points.add_child(marker)
	map.add_child(spawn_points)
	main.add_child(map)
	var state := MatchState.new()
	state.name = "MatchState"
	main.add_child(state)
	add_child_autofree(main)
	if with_director:
		_director = MatchDirector.new()
		_director.rules = load("res://common/resources/default_match_rules.tres")
		_director.match_state = state
		_director.roster_override = roster
		main.add_child(_director)
		NetworkTime.after_tick.disconnect(_director._on_after_tick)
	_main = main
	return main

func _players() -> Node3D:
	return _main.get_node("Players")

func _mobs() -> Node3D:
	return _main.get_node("Mobs")

func _souls() -> Node3D:
	return _main.get_node("Souls")

func _totems() -> Node3D:
	return _main.get_node("Totems")

## Lets the deferred initial-enemy spawn settle.
func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

## Test: main.tscn has every typed container plus exactly one MultiplayerSpawner
## per container, pointing at it; stubs carry an empty spawnable list and no
## spawner carries spawn-property config (verification-only risk per design).
func test_main_scene_typed_containers_and_spawners() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var scene_state := packed.get_state()
	var paths := []
	var spawner_paths := {}
	for i in scene_state.get_node_count():
		var path := str(scene_state.get_node_path(i))
		paths.append(path)
		if scene_state.get_node_type(i) == "MultiplayerSpawner":
			spawner_paths[path] = i

	for container in ["./Players", "./Mobs", "./Souls", "./Totems", "./Minions", "./Boss", "./Projectiles"]:
		assert_has(paths, container, "main.tscn must contain container " + container)

	assert_false(paths.has("./MultiplayerSpawner"),
		"The legacy single spawner must be gone")
	assert_eq(spawner_paths.size(), 7, "Exactly one spawner per container")

	var expected := {
		"./PlayerSpawner": "../Players",
		"./MobSpawner": "../Mobs",
		"./SoulSpawner": "../Souls",
		"./TotemSpawner": "../Totems",
		"./MinionSpawner": "../Minions",
		"./BossSpawner": "../Boss",
		"./ProjectileSpawner": "../Projectiles",
	}
	for spawner_path in expected:
		if not assert_has(spawner_paths.keys(), spawner_path, "Missing spawner " + spawner_path):
			continue
		var idx: int = spawner_paths[spawner_path]
		var prop_names := []
		var spawn_path := ""
		for p in scene_state.get_node_property_count(idx):
			var prop_name := str(scene_state.get_node_property_name(idx, p))
			prop_names.append(prop_name)
			if prop_name == "spawn_path":
				spawn_path = str(scene_state.get_node_property_value(idx, p))
		assert_eq(spawn_path, expected[spawner_path],
			spawner_path + " must spawn into " + expected[spawner_path])
		assert_eq(prop_names.size(), prop_names.count("spawn_path") + prop_names.count("_spawnable_scenes"),
			spawner_path + " must not carry spawn-property config")

	# Stub spawners are empty (absent property = default empty); typed spawners
	# map their entity scenes.
	for stub in ["./MinionSpawner", "./BossSpawner"]:
		var idx: int = spawner_paths[stub]
		var spawnable_size := 0
		for p in scene_state.get_node_property_count(idx):
			if str(scene_state.get_node_property_name(idx, p)) == "_spawnable_scenes":
				spawnable_size = (scene_state.get_node_property_value(idx, p) as PackedStringArray).size()
		assert_eq(spawnable_size, 0, stub + " must have an empty _spawnable_scenes (stub)")

	var spawnable_by_spawner := {}
	for spawner_path in spawner_paths:
		var idx: int = spawner_paths[spawner_path]
		for p in scene_state.get_node_property_count(idx):
			if str(scene_state.get_node_property_name(idx, p)) == "_spawnable_scenes":
				spawnable_by_spawner[spawner_path] = scene_state.get_node_property_value(idx, p)
	assert_eq(spawnable_by_spawner["./MobSpawner"], PackedStringArray(["uid://dg7xnmokokkvl"]),
		"MobSpawner spawns EnemyEntity only")
	assert_eq(spawnable_by_spawner["./TotemSpawner"],
		PackedStringArray(["res://scenes/TotemEntity.tscn", "res://scenes/PetEntity.tscn"]),
		"TotemSpawner spawns TotemEntity + PetEntity")
	assert_eq(spawnable_by_spawner["./SoulSpawner"], PackedStringArray(["res://scenes/SoulEntity.tscn"]),
		"SoulSpawner spawns SoulEntity only")
	assert_eq(spawnable_by_spawner["./PlayerSpawner"], PackedStringArray(["uid://bvbjvutgbeanf"]),
		"PlayerSpawner spawns BaseEntity only")

## Test: selection gating keeps every gameplay container empty before launch.
func test_initial_spawn_flow_is_gated_until_launch() -> void:
	_make_main()
	await _settle()
	assert_eq(_mobs().get_child_count(), 0, "Mobs must wait for selection launch")
	assert_eq(_players().get_child_count(), 0, "No players in the initial flow")
	assert_eq(_souls().get_child_count(), 0)
	assert_eq(_totems().get_child_count(), 0)

## Test: every spawn path routes to its typed container with an unchanged
## name prefix (MOB_/ELITE_/SOUL_/TOTEM_/PET_, int peer names).
func test_spawn_routing_containers_and_prefixes() -> void:
	_make_main()
	await _settle()

	var mob: Node = _main.spawn_enemy("AATROX", Vector3(1, 0, 1))
	assert_eq(mob.get_parent(), _mobs(), "Mobs spawn under Mobs")
	assert_string_starts_with(mob.name, "MOB_")

	_main._spawn_elite_mob(Vector3(2, 0, 2))
	var elite: Node = _mobs().get_child(_mobs().get_child_count() - 1)
	assert_string_starts_with(elite.name, "ELITE_", "Elites keep the ELITE_ prefix under Mobs")

	_main._spawn_soul(Vector3(3, 0, 3))
	var soul: Node = _souls().get_child(0)
	assert_string_starts_with(soul.name, "SOUL_", "Souls keep the SOUL_ prefix under Souls")

	_main._spawn_player(2)
	var player: Node = _players().get_node_or_null("2")
	assert_not_null(player, "Players keep int peer names under Players")

	# Totem + pet flow: player needs souls to summon.
	player.server_state.sync_souls = 5
	_main.request_spawn_totem(player, 0)
	var totem: Node = _totems().get_child(0)
	assert_string_starts_with(totem.name, "TOTEM_", "Totems keep the TOTEM_ prefix under Totems")
	totem.summoned.emit(0, 5)
	var pet: Node = _totems().get_child(1)
	assert_string_starts_with(pet.name, "PET_", "Pets keep the PET_ prefix under Totems")

## Test: BaseEntity group detection keys off name prefixes and yields the exact
## pre-change groups for entities spawned under the new containers.
func test_group_detection_matches_prechange() -> void:
	_make_main()
	await _settle()

	var mob: Node = _main.spawn_enemy("AATROX", Vector3.ZERO)
	_main._spawn_elite_mob(Vector3.ONE)
	var elite: Node = _mobs().get_child(_mobs().get_child_count() - 1)
	_main._spawn_soul(Vector3.ZERO)
	var soul: Node = _souls().get_child(0)
	_main._spawn_player(2)
	var player: Node = _players().get_node("2")
	player.server_state.sync_souls = 5
	_main.request_spawn_totem(player, 0)
	var totem: Node = _totems().get_child(0)
	totem.summoned.emit(0, 5)
	var pet: Node = _totems().get_child(1)

	assert_true(player.is_in_group(&"players"), "int-named entities are players")
	assert_true(mob.is_in_group(&"mobs"), "MOB_ entities are mobs")
	assert_true(elite.is_in_group(&"mobs"), "ELITE_ entities are mobs")
	assert_true(pet.is_in_group(&"pets"), "PET_ entities are pets")
	for entity in [soul, totem]:
		assert_false(entity.is_in_group(&"players"), entity.name + " must not be a player")
		assert_false(entity.is_in_group(&"mobs"), entity.name + " must not be a mob")
		assert_false(entity.is_in_group(&"pets"), entity.name + " must not be a pet")

## Test: spawned players get team_id from the roster; mobs/souls/totems stay NONE.
func test_team_id_from_roster_at_spawn() -> void:
	_make_main(true, [1, 2, 3, 4])  # 1/3 RED, 2/4 BLUE
	await _settle()

	_main._spawn_player(1)
	_main._spawn_player(2)
	var red_player := _players().get_node("1") as BaseEntity
	var blue_player := _players().get_node("2") as BaseEntity
	assert_eq(red_player.get_node("ServerState").team_id, TeamId.RED,
		"Peer 1 spawns RED per roster")
	assert_eq(blue_player.get_node("ServerState").team_id, TeamId.BLUE,
		"Peer 2 spawns BLUE per roster")
	assert_eq(red_player.collision_layer, BaseEntity.RED_COLLISION_LAYER)
	assert_eq(red_player.collision_mask, BaseEntity.WORLD_COLLISION_LAYER | BaseEntity.BLUE_COLLISION_LAYER | BaseEntity.NEUTRAL_COLLISION_LAYER)
	assert_eq(blue_player.collision_layer, BaseEntity.BLUE_COLLISION_LAYER)
	assert_eq(blue_player.collision_mask, BaseEntity.WORLD_COLLISION_LAYER | BaseEntity.RED_COLLISION_LAYER | BaseEntity.NEUTRAL_COLLISION_LAYER)

	var mob: Node = _main.spawn_enemy("AATROX", Vector3.ZERO)
	assert_eq(mob.get_node("ServerState").team_id, TeamId.NONE,
		"Mobs stay NONE at this stage")
	assert_eq(mob.collision_layer, BaseEntity.NEUTRAL_COLLISION_LAYER,
		"Mobs are hostile neutrals regardless of wave-accounting team")
	var soul_count_before := _souls().get_child_count()
	_main._spawn_soul(Vector3.ZERO)
	var soul := _souls().get_child(soul_count_before) as Area3D
	assert_eq(soul.collision_mask, BaseEntity.RED_COLLISION_LAYER | BaseEntity.BLUE_COLLISION_LAYER,
		"Souls detect both faction-layered player bodies")

## Test: LOBBY recompute pushes updated teams onto already-spawned players.
func test_team_assigned_refreshes_spawned_players() -> void:
	_make_main(true, [1, 2, 3])  # 3 -> RED (sorted index 2)
	await _settle()
	_main._spawn_player(3)
	assert_eq(_players().get_node("3").get_node("ServerState").team_id, TeamId.RED)

	# A lower peer id joins: sorted [0, 1, 2, 3] moves 3 to index 3 -> BLUE.
	# (Drive the director directly; emitting client_connected would also make
	# MatchManager spawn the new peer, which is not what this test checks.)
	_director.roster_override = [0, 1, 2, 3]
	_director._on_roster_changed()
	assert_eq(_players().get_node("3").get_node("ServerState").team_id, TeamId.BLUE,
		"Full recompute must refresh spawned players' team_id")
	assert_eq(_players().get_node("3").collision_layer, BaseEntity.BLUE_COLLISION_LAYER,
		"A team reassignment refreshes the player's collision faction")

## Test: registry preserves spawn-sequence order on register/unregister, and
## MatchManager registers typed spawns (players under their roster team).
func test_registry_spawn_sequence_order() -> void:
	_make_main(true, [1, 2])
	await _settle()

	# Pure registry semantics: append order, stable removal.
	_director.register_to_team(TeamId.RED, &"s1")
	_director.register_to_team(TeamId.RED, &"s2")
	_director.register_to_team(TeamId.RED, &"s3")
	assert_eq(_director.get_team_registry(TeamId.RED), [&"s1", &"s2", &"s3"] as Array[StringName],
		"Registry enumerates in spawn order, not dictionary order")
	_director.unregister_from_team(TeamId.RED, &"s2")
	assert_eq(_director.get_team_registry(TeamId.RED), [&"s1", &"s3"] as Array[StringName],
		"Unregister preserves the order of the remaining ids")

	# Before selection launch, no gameplay entity is registered.
	var none_registry := _director.get_team_registry(TeamId.NONE)
	assert_eq(none_registry.size(), 0, "Pre-launch gameplay registry must be empty")

	_main._spawn_player(1)
	_main._spawn_player(2)
	assert_has(_director.get_team_registry(TeamId.RED), &"1", "Peer 1 registers RED")
	assert_has(_director.get_team_registry(TeamId.BLUE), &"2", "Peer 2 registers BLUE")

	_main._despawn_player(1)
	assert_false(_director.get_team_registry(TeamId.RED).has(&"1"),
		"Despawned players unregister from their team")

## Test: ROUND_SETUP pulls the assigned match seed into spawn id generation and
## resets the per-prefix counters (deterministic ids per match).
func test_match_seed_wiring() -> void:
	_make_main()
	await _settle()

	var first_id: String = _main._next_spawn_id("MOB_")
	assert_string_starts_with(first_id, "MOB_00_", "Seed defaults to 0 pre-ROUND_SETUP")

	_director.match_state.match_seed = 42
	EventBus.phase_changed.emit(MatchState.Phase.ROUND_SETUP)
	assert_eq(_main.match_seed, 42, "ROUND_SETUP must push the seed into MatchManager")
	assert_eq(_main._next_spawn_id("MOB_"), "MOB_2A_0001",
		"Spawn ids embed the seed hex and restart the per-prefix counter")

## Test: solo/free play without a director works unchanged — spawns route,
## guards no-op, and team_id stays NONE.
func test_solo_free_play_without_director() -> void:
	_make_main(false)
	await _settle()

	var mob: Node = _main.spawn_enemy("AATROX", Vector3.ZERO)
	assert_eq(mob.get_parent(), _mobs())
	_main._spawn_player(5)
	var player: Node = _players().get_node_or_null("5")
	assert_not_null(player, "Solo spawn works without a director")
	assert_eq(player.get_node("ServerState").team_id, TeamId.NONE,
		"team_id stays NONE without a director")

	# Seed wiring and team refresh no-op gracefully without a director/state.
	EventBus.phase_changed.emit(MatchState.Phase.ROUND_SETUP)
	EventBus.team_assigned.emit()
	assert_eq(_main.match_seed, 0, "No director/state means no seed change")
