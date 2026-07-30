extends GutTest

## Contract coverage for the per-team parallel stage progression. Verifies
## that both teams spawn their stage 1 simultaneously, wave accounting stays
## isolated per team, the boss fires when ANY team clears stage 3 (even if the
## other team is still mid-progression), and the slower team keeps progressing
## after the boss spawns.

const MOBS_PER_STAGE: int = 10

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
	await get_tree().process_frame

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _mobs_of_team(team: int) -> Array:
	var result: Array = []
	for child in _manager.get_node("Mobs").get_children():
		if child.has_node("ServerState") and int(child.get_node("ServerState").team_id) == team:
			result.append(child)
	return result

func _boss() -> Node:
	for child in _manager.get_node("Mobs").get_children():
		if String(child.name).begins_with("BOSS_"):
			return child
	return null

func _kill_all_in_wave(team: int) -> void:
	for mob in _mobs_of_team(team):
		_manager._on_entity_died(mob)
		await get_tree().process_frame

func test_begin_stage_progression_starts_both_teams_at_stage_1() -> void:
	_manager._begin_stage_progression()
	assert_eq(_manager._stage_progression_active_by_team[TeamId.RED], true)
	assert_eq(_manager._stage_progression_active_by_team[TeamId.BLUE], true)
	assert_eq(_manager._next_stage_index_by_team[TeamId.RED], 1)
	assert_eq(_manager._next_stage_index_by_team[TeamId.BLUE], 1)
	assert_eq(_mobs_of_team(TeamId.RED).size(), MOBS_PER_STAGE)
	assert_eq(_mobs_of_team(TeamId.BLUE).size(), MOBS_PER_STAGE)

func test_each_team_has_correct_team_id_on_spawned_mobs() -> void:
	_manager._begin_stage_progression()
	for mob in _mobs_of_team(TeamId.RED):
		assert_eq(int(mob.get_node("ServerState").team_id), TeamId.RED)
	for mob in _mobs_of_team(TeamId.BLUE):
		assert_eq(int(mob.get_node("ServerState").team_id), TeamId.BLUE)

func test_killing_one_team_does_not_advance_the_other() -> void:
	_manager._begin_stage_progression()
	await _kill_all_in_wave(TeamId.RED)
	assert_eq(_manager._next_stage_index_by_team[TeamId.RED], 2,
		"Red advanced to stage 2 after clearing stage 1")
	assert_eq(_manager._wave_alive_by_team[TeamId.BLUE], MOBS_PER_STAGE,
		"Blue wave untouched while Red advanced")
	assert_eq(_manager._next_stage_index_by_team[TeamId.BLUE], 1,
		"Blue index stays at stage 2 spawn")

func test_both_teams_advance_through_all_three_stages_independently() -> void:
	_manager._begin_stage_progression()
	for _stage in range(3):
		await _kill_all_in_wave(TeamId.RED)
		await _kill_all_in_wave(TeamId.BLUE)
	assert_eq(_manager._boss_spawned, true,
		"Boss spawns once both teams independently reach their stage 3 clear")
	assert_ne(_boss(), null, "Boss exists")
	assert_eq(_manager._next_stage_index_by_team[TeamId.RED], -1)
	assert_eq(_manager._next_stage_index_by_team[TeamId.BLUE], -1)

func test_boss_spawns_when_only_red_clears_stage_3_first() -> void:
	_manager._begin_stage_progression()
	for _i in range(3):
		await _kill_all_in_wave(TeamId.RED)
	assert_eq(_manager._boss_spawned, true, "Boss fires when Red clears stage 3")
	assert_ne(_boss(), null)
	assert_eq(_manager._next_stage_index_by_team[TeamId.RED], -1)
	assert_eq(_manager._stage_progression_active_by_team[TeamId.RED], false)

func test_blue_keeps_progressing_after_boss_already_spawned() -> void:
	_manager._begin_stage_progression()
	for _i in range(3):
		await _kill_all_in_wave(TeamId.RED)
	assert_eq(_manager._boss_spawned, true)
	assert_eq(_manager._wave_alive_by_team[TeamId.BLUE], MOBS_PER_STAGE,
		"Blue is still mid stage 1 when Red already summoned the boss")
	await _kill_all_in_wave(TeamId.BLUE)
	assert_eq(_manager._next_stage_index_by_team[TeamId.BLUE], 2,
		"Blue advances to stage 2 even though boss already spawned")
	assert_eq(_manager._boss_spawned, true, "Boss spawned flag stays true; only one boss per match")

func test_boss_spawns_only_once_when_both_teams_finish() -> void:
	_manager._begin_stage_progression()
	for _i in range(3):
		await _kill_all_in_wave(TeamId.RED)
	var first_boss := _boss()
	assert_ne(first_boss, null)
	assert_eq(_manager._boss_spawned, true)
	for _i in range(3):
		await _kill_all_in_wave(TeamId.BLUE)
	var all_bosses: Array = []
	for child in _manager.get_node("Mobs").get_children():
		if String(child.name).begins_with("BOSS_"):
			all_bosses.append(child)
	assert_eq(all_bosses.size(), 1,
		"Exactly one boss despite both teams clearing their waves")

func test_killing_a_non_active_wave_mob_does_not_advance_progression() -> void:
	_manager._begin_stage_progression()
	var free_mob: Node = _manager.spawn_enemy("AATROX", Vector3(0, 0, 0), 0.0, TeamId.NONE)
	_manager._on_entity_died(free_mob)
	await get_tree().process_frame
	assert_eq(_manager._wave_alive_by_team[TeamId.RED], MOBS_PER_STAGE)
	assert_eq(_manager._wave_alive_by_team[TeamId.BLUE], MOBS_PER_STAGE)
	assert_eq(_manager._next_stage_index_by_team[TeamId.RED], 1)
	assert_eq(_manager._next_stage_index_by_team[TeamId.BLUE], 1)
