extends GutTest

## Contract coverage for explicit team choice: server-side RPC validation,
## cap enforcement, READY cooldown after switching teams, and snapshot exposure
## of both team rosters for client-side rendering.

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

func _record(name: String, team: int = TeamId.NONE) -> Dictionary:
	return {"account_id": name, "name": name, "team": team, "lobby_ready": false, "character_id": "", "selection_ready": false, "is_host": false}

func _seed(count: int) -> void:
	_manager._lobby.clear()
	_manager._last_team_change_tick.clear()
	for i in count:
		var peer_id := i + 2
		_manager._lobby[peer_id] = _record("Peer%d" % peer_id)

func _drive_tick(tick: int) -> void:
	_director.tick_update(tick)

func test_explicit_team_choice_sets_lobby_team() -> void:
	_seed(1)
	assert_true(_manager.submit_team_choice(2, TeamId.RED))
	assert_eq(_manager.get_team_for(2), TeamId.RED)
	assert_eq(int(_manager._lobby[2]["team"]), TeamId.RED)

func test_switching_team_resets_lobby_ready() -> void:
	_seed(1)
	_manager._lobby[2]["lobby_ready"] = true
	assert_true(_manager.submit_team_choice(2, TeamId.RED))
	assert_true(_manager.submit_team_choice(2, TeamId.BLUE))
	assert_eq(_manager._lobby[2]["team"], TeamId.BLUE)
	assert_false(_manager._lobby[2]["lobby_ready"], "Team switch must clear READY")

func test_team_full_rejects_with_no_state_change() -> void:
	_manager._lobby = {2: _record("P2", TeamId.RED), 3: _record("P3", TeamId.RED), 4: _record("P4", TeamId.RED)}
	assert_eq(_director.rules.max_players_per_team, 3)
	assert_false(_manager.submit_team_choice(5, TeamId.RED))
	assert_eq(_manager.get_team_for(5), TeamId.NONE)

func test_invalid_team_value_is_rejected() -> void:
	_seed(1)
	assert_false(_manager.submit_team_choice(2, 99))
	assert_false(_manager.submit_team_choice(2, TeamId.NONE))
	assert_eq(_manager.get_team_for(2), TeamId.NONE)

func test_ready_without_team_is_rejected() -> void:
	_seed(1)
	assert_false(_manager._set_lobby_ready_from_peer(2, true))
	assert_false(_manager._lobby[2]["lobby_ready"])

func test_ready_blocked_during_team_change_cooldown() -> void:
	_seed(1)
	assert_true(_manager.submit_team_choice(2, TeamId.RED))
	_manager._lobby[2]["lobby_ready"] = true
	_drive_tick(100)
	assert_true(_manager.submit_team_choice(2, TeamId.BLUE))
	assert_false(_manager._lobby[2]["lobby_ready"], "Switch resets READY")
	assert_false(_manager._set_lobby_ready_from_peer(2, true),
		"READY locked during the cooldown window")
	_drive_tick(100 + _manager.TEAM_CHANGE_COOLDOWN_TICKS - 1)
	assert_false(_manager._set_lobby_ready_from_peer(2, true),
		"READY still locked one tick before the cooldown expires")
	_drive_tick(100 + _manager.TEAM_CHANGE_COOLDOWN_TICKS)
	assert_true(_manager._set_lobby_ready_from_peer(2, true),
		"READY unlocks once the cooldown elapses")

func test_initial_team_choice_does_not_apply_cooldown() -> void:
	_seed(1)
	assert_true(_manager.submit_team_choice(2, TeamId.RED))
	assert_false(_manager._last_team_change_within_cooldown(2),
		"First-ever choice must not start the cooldown")

func test_all_lobby_ready_requires_team_chosen() -> void:
	_manager._lobby = {2: _record("P2"), 3: _record("P3")}
	for peer_id in [2, 3]:
		_manager._lobby[peer_id]["lobby_ready"] = true
	assert_false(_manager._all_lobby_ready(),
		"NONE team must keep _all_lobby_ready false")
	_manager._lobby[2]["team"] = TeamId.RED
	assert_false(_manager._all_lobby_ready(),
		"Partial team assignment keeps it false")
	_manager._lobby[3]["team"] = TeamId.BLUE
	assert_true(_manager._all_lobby_ready(),
		"Both teams chosen + READY → lobby ready")

func test_snapshot_exposes_red_and_blue_rosters_separately() -> void:
	_manager._lobby = {2: _record("Alice", TeamId.RED), 3: _record("Bob", TeamId.BLUE), 4: _record("Cara", TeamId.RED)}
	_manager._lobby[3]["lobby_ready"] = true
	var snap: Dictionary = _manager._snapshot_for(3)
	assert_eq(snap["team"], TeamId.BLUE)
	assert_eq((snap["red_members"] as Array).size(), 2)
	assert_eq((snap["blue_members"] as Array).size(), 1)
	assert_eq(str(snap["red_members"][0]["name"]), "Alice")
	assert_eq(str(snap["blue_members"][0]["name"]), "Bob")
	assert_eq((snap["members"] as Array).size(), 1,
		"members still mirrors only the recipient's own team")

func test_director_roster_tracks_manager_choices() -> void:
	_seed(2)
	_manager.submit_team_choice(2, TeamId.RED)
	_manager.submit_team_choice(3, TeamId.BLUE)
	_director._recompute_teams()
	assert_eq(_director.get_team(2), TeamId.RED)
	assert_eq(_director.get_team(3), TeamId.BLUE)

func test_spawn_position_follows_explicit_team_choice() -> void:
	_seed(1)
	_manager.submit_team_choice(2, TeamId.BLUE)
	var team: int = _manager._team_for_player_spawn(2)
	assert_eq(team, TeamId.BLUE,
		"Spawn position must respect the explicit choice, not the parity fallback")

## --- Mob difficulty scaling by team size -------------------------------
## Curve (see MOB_DIFFICULTY_* in match_manager.gd):
##   1 → 1.0, 2 → 1.2, 3 → 1.4, 4 → 1.5, 5 → 1.6, 6 → 1.7
## First two extra teammates each contribute +20%; +10% per teammate beyond.

func _seed_team(team: int, count: int) -> void:
	_manager._lobby.clear()
	for i in count:
		var peer_id := (2 if team == TeamId.RED else 100) + i
		_manager._lobby[peer_id] = _record("Peer%d" % peer_id, team)

func test_mob_difficulty_for_solo_team_returns_one() -> void:
	_seed_team(TeamId.RED, 1)
	assert_almost_eq(_manager._mob_difficulty_for_team(TeamId.RED), 1.0, 0.0001,
		"Solo (1 player) must not scale mob stats")

func test_mob_difficulty_curve_matches_spec() -> void:
	var cases := [
		[1, 1.0],
		[2, 1.2],
		[3, 1.4],
		[4, 1.5],
		[5, 1.6],
		[6, 1.7],
		[8, 1.9],
	]
	for case in cases:
		var size: int = case[0]
		var expected: float = case[1]
		_seed_team(TeamId.RED, size)
		var actual: float = _manager._mob_difficulty_for_team(TeamId.RED)
		assert_almost_eq(actual, expected, 0.0001,
			"Team size %d must yield difficulty %.2f (got %.4f)" % [size, expected, actual])

func test_mob_difficulty_for_none_team_returns_one() -> void:
	# Boss / free-play elites go through TeamId.NONE; they keep their own
	# scaling (BOSS_HP_MULTIPLIER) and must not get the team-size multiplier.
	assert_almost_eq(_manager._mob_difficulty_for_team(TeamId.NONE), 1.0, 0.0001,
		"NONE team (boss/elites) must not pick up the team-size curve")
	_seed_team(TeamId.BLUE, 5)
	assert_almost_eq(_manager._mob_difficulty_for_team(TeamId.NONE), 1.0, 0.0001,
		"NONE team must stay at 1.0 even when the lobby is full")

func test_mob_difficulty_uses_correct_team_roster() -> void:
	# RED has 3 players, BLUE has 5 — each side's mobs scale by their own
	# opposing roster, not the combined lobby size.
	_manager._lobby.clear()
	for i in 3:
		_manager._lobby[10 + i] = _record("R%d" % i, TeamId.RED)
	for i in 5:
		_manager._lobby[50 + i] = _record("B%d" % i, TeamId.BLUE)
	assert_almost_eq(_manager._mob_difficulty_for_team(TeamId.RED), 1.4, 0.0001,
		"3 RED players → +40% mob stats")
	assert_almost_eq(_manager._mob_difficulty_for_team(TeamId.BLUE), 1.6, 0.0001,
		"5 BLUE players → +60% mob stats")
