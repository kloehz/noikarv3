extends GutTest
const Profile := preload("res://common/benchmark_profile.gd")
const Manager := preload("res://common/match_manager.gd")
const Game := preload("res://common/game_manager.gd")

class PopulationEntity extends Node3D:
	var sync_is_dead := false

func test_default_resource_and_role_are_unchanged() -> void:
	var authored := load("res://common/resources/default_match_rules.tres") as MatchRules
	assert_eq(authored.max_players_per_team, 3)
	assert_same(Profile.scoped_match_rules(authored, 0), authored)
	assert_true(Profile.validate_load20_options("", {}))
	assert_true(Game.server_role_for_display(true, false, false))
	assert_false(Game.server_role_for_display(true, false, true))
	assert_true(Game.server_role_for_display(true, true, true))
	assert_false(Game.server_role_for_display(false, false, false))

func test_load20_clones_rules_without_mutating_authored_asset() -> void:
	var authored := load("res://common/resources/default_match_rules.tres") as MatchRules
	var runtime := Profile.scoped_match_rules(authored, 20)
	assert_ne(runtime, authored)
	assert_eq(runtime.max_players_per_team, 10)
	assert_eq(authored.max_players_per_team, 3)
	assert_eq(runtime.countdown_sec, authored.countdown_sec)
	assert_null(Profile.scoped_match_rules(authored, 19))
	assert_null(Profile.scoped_match_rules(runtime, 20))
	assert_true(Profile.capacity_matches(20, 20))
	assert_true(Profile.capacity_matches(0, 0))
	assert_false(Profile.capacity_matches(20, 0))
	assert_false(Profile.capacity_matches(0, 20))
	assert_false(Profile.capacity_matches(8, 8))

func test_load20_options_reject_invalid_remote_mismatched_or_implicit_limits() -> void:
	var server := {"limit": "20", "client": "", "perf": "1", "backend": "http://127.0.0.1:18090", "fixed_population": "1", "mobs": "20"}
	assert_true(Profile.validate_load20_options("compare30", server))
	assert_true(Profile.validate_load20_options("compare60", server))
	for bad in [{"limit": "20.0"}, {"limit": "19"}, {"backend": "https://remote.example"}, {"perf": ""}, {"mobs": "19"}, {"fixed_population": ""}]:
		var options := server.duplicate(); options.merge(bad, true)
		assert_false(Profile.validate_load20_options("compare60", options))
	assert_false(Profile.validate_load20_options("", server))
	var client := server.duplicate()
	client.merge({"client": "1", "players": "20", "expected_mobs": "20", "fixed_route": "1", "index": "19"}, true)
	assert_true(Profile.validate_load20_options("compare60", client))
	for bad_index in ["20", "-1", "19.5", "01", ""]:
		client.index = bad_index
		assert_false(Profile.validate_load20_options("compare60", client))

func _manager_with_rules(limit: int) -> Node3D:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var manager := Manager.new()
	for container_name in ["Players", "Mobs", "Souls", "Totems"]:
		var container := Node3D.new(); container.name = container_name; manager.add_child(container)
	var state := MatchState.new(); state.name = "MatchState"; manager.add_child(state)
	var director := MatchDirector.new()
	director.rules = Profile.scoped_match_rules(load("res://common/resources/default_match_rules.tres"), limit)
	director.match_state = state; manager.add_child(director)
	add_child_autofree(manager)
	NetworkTime.after_tick.disconnect(director._on_after_tick)
	return manager

func test_real_admission_and_team_gates_accept_twenty_but_reject_duplicates_and_twenty_first() -> void:
	var manager := _manager_with_rules(20)
	for i in 20:
		assert_true(manager._admit_authenticated_identity(i + 2, {"account_id": "account%d" % i, "username": "Owner%d" % i}))
	assert_eq(manager.peer_data.size(), 20)
	assert_false(manager._admit_authenticated_identity(30, {"account_id": "extra", "username": "Extra"}))
	assert_eq(manager._admission_failure_reason("extra"), "Room is full")
	for i in 20:
		assert_true(manager.submit_team_choice(i + 2, TeamId.RED if i < 10 else TeamId.BLUE))
	assert_eq(manager._team_member_count(TeamId.RED), 10)
	assert_eq(manager._team_member_count(TeamId.BLUE), 10)
	assert_false(manager.submit_team_choice(12, TeamId.RED))
	manager._lobby.erase(21); manager.peer_data.erase(21)
	assert_false(manager._admit_authenticated_identity(30, {"account_id": "account0", "username": "Duplicate"}))
	assert_false(manager._admit_authenticated_identity(30, {"account_id": "", "username": "Empty"}))
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func test_default_admission_is_still_six() -> void:
	var manager := _manager_with_rules(0)
	for i in 6:
		assert_true(manager._admit_authenticated_identity(i + 2, {"account_id": "account%d" % i, "username": "Owner%d" % i}))
	assert_false(manager._admit_authenticated_identity(20, {"account_id": "extra", "username": "Extra"}))
	assert_eq(manager._get_match_director().rules.max_players_per_team, 3)
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func test_authoritative_population_reads_actual_nodes_and_authorities() -> void:
	var manager := _manager_with_rules(20)
	for i in 20:
		var id := i + 2
		manager.peer_data[id] = {"account_id": "account%d" % i}
		manager._lobby[id] = {"team": TeamId.RED if i < 10 else TeamId.BLUE}
		var entity := PopulationEntity.new(); entity.name = str(id)
		var logic := Node.new(); logic.name = "LogicComponent"; logic.set_multiplayer_authority(id)
		var state := Node.new(); state.name = "ServerState"; state.set_multiplayer_authority(1)
		entity.add_child(logic); entity.add_child(state); manager.players_container.add_child(entity)
		var mob := PopulationEntity.new(); mob.name = "MOB_%d" % i; manager.mobs_container.add_child(mob)
	var actual: Dictionary = manager.profile_owner_population()
	assert_eq(actual.owners.size(), 20)
	assert_eq(actual.authenticated_accounts, 20)
	assert_eq(actual.red, 10); assert_eq(actual.blue, 10)
	assert_eq(actual.live_mobs, 20); assert_eq(actual.alive_mobs, 20)
	assert_eq(actual.input_authorities, actual.owners)
	assert_eq(actual.server_state_authorities, 20)
	manager.players_container.get_child(0).sync_is_dead = true
	manager.mobs_container.get_child(0).sync_is_dead = true
	actual = manager.profile_owner_population()
	assert_eq(actual.alive_players, 19); assert_eq(actual.alive_mobs, 19)
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
