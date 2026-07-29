# tests/integration/test_match_director_phases.gd
extends GutTest

## Integration tests for the MatchDirector phase machine: full LOBBY→POST_MATCH
## walk, exact tick timers, determinism (identical (phase, tick) logs across
## runs), deterministic seed, LOBBY team assignment/freeze, lifecycle events,
## and silent late-join catch-up. Runs headless with OfflineMultiplayerPeer
## and synthetic ticks; the live NetworkTime autoload hookup is disconnected
## so only synthetic ticks drive the director.

const DEFAULT_RULES := "res://common/resources/default_match_rules.tres"

var _phase_log: Array = []  # [phase: int, tick: int] entries
var _current_tick: int = 0
var _match_started_count: int = 0
var _match_ended_events: Array[int] = []
var _team_assigned_count: int = 0
var _client_peer: ENetMultiplayerPeer

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_phase_log = []
	_current_tick = 0
	_match_started_count = 0
	_match_ended_events = []
	_team_assigned_count = 0
	EventBus.phase_changed.connect(_on_phase_changed)
	EventBus.match_started.connect(_on_match_started)
	EventBus.match_ended.connect(_on_match_ended)
	EventBus.team_assigned.connect(_on_team_assigned)

func after_each() -> void:
	EventBus.phase_changed.disconnect(_on_phase_changed)
	EventBus.match_started.disconnect(_on_match_started)
	EventBus.match_ended.disconnect(_on_match_ended)
	EventBus.team_assigned.disconnect(_on_team_assigned)
	if is_instance_valid(_client_peer):
		_client_peer.close()
	_client_peer = null
	multiplayer.multiplayer_peer = null

func _on_phase_changed(phase: int) -> void:
	_phase_log.append([phase, _current_tick])

func _on_match_started() -> void:
	_match_started_count += 1

func _on_match_ended(winner_id: int) -> void:
	_match_ended_events.append(winner_id)

func _on_team_assigned() -> void:
	_team_assigned_count += 1

## Builds a server MatchState + MatchDirector pair with an injected roster,
## isolated from the live NetworkTime autoload (synthetic ticks only).
func _make_director(roster: Array[int] = [1, 2, 3, 4], seed_base: int = 0) -> MatchDirector:
	var state := MatchState.new()
	add_child_autofree(state)
	var director := MatchDirector.new()
	director.rules = load(DEFAULT_RULES)
	director.match_state = state
	director.seed_base = seed_base
	director.roster_override = roster
	add_child_autofree(director)
	NetworkTime.after_tick.disconnect(director._on_after_tick)
	return director

func _drive_ticks(director: MatchDirector, from_tick: int, count: int) -> void:
	for i in range(from_tick, from_tick + count):
		_current_tick = i
		director.tick_update(i)

## Full scripted walk LOBBY→COUNTDOWN→ROUND_SETUP→PVE_RACE→BOSS_LOCK→
## BOSS_DEPLOY→BOSS_A1→RESULT→POST_MATCH→LOBBY using stub events in order.
func _run_full_walk(director: MatchDirector) -> void:
	director.request_match_start()
	_drive_ticks(director, 1, 180)
	director.request_boss_lock()
	director.request_boss_lock()
	_drive_ticks(director, 181, 180)
	director.request_boss_a1_end()
	_drive_ticks(director, 361, 600)
	_drive_ticks(director, 961, 1)

const EXPECTED_WALK := [
	[MatchState.Phase.COUNTDOWN, 0],
	[MatchState.Phase.ROUND_SETUP, 180],
	[MatchState.Phase.PVE_RACE, 180],
	[MatchState.Phase.BOSS_LOCK, 180],
	[MatchState.Phase.BOSS_DEPLOY, 180],
	[MatchState.Phase.BOSS_A1, 360],
	[MatchState.Phase.RESULT, 360],
	[MatchState.Phase.POST_MATCH, 960],
	[MatchState.Phase.LOBBY, 961],
]

## Test: Director registers in the match_director group on ready
func test_director_in_match_director_group() -> void:
	var director := _make_director()
	assert_true(director.is_in_group(&"match_director"),
		"MatchDirector must join the match_director group")

## Test: Full 2-team walk visits every phase in exact spec order on exact ticks
func test_full_phase_walk_order_and_ticks() -> void:
	var director := _make_director()
	_run_full_walk(director)
	assert_eq(_phase_log, EXPECTED_WALK, "Phase walk must match the transition map exactly")
	assert_eq(director.match_state.phase, MatchState.Phase.LOBBY,
		"POST_MATCH must reset back to LOBBY")

## Test: Timed phases use MatchRules durations: 180t countdown, 180t deploy, 600t result
func test_phase_timer_durations() -> void:
	var director := _make_director()
	_run_full_walk(director)
	var by_phase := {}
	for entry in _phase_log:
		by_phase[entry[0]] = entry[1]
	assert_eq(by_phase[MatchState.Phase.PVE_RACE] - by_phase[MatchState.Phase.COUNTDOWN], 180,
		"COUNTDOWN must last countdown_sec (3.0s = 180t)")
	assert_eq(by_phase[MatchState.Phase.BOSS_A1] - by_phase[MatchState.Phase.BOSS_DEPLOY], 180,
		"BOSS_DEPLOY must last boss_deploy_countdown_sec (3.0s = 180t)")
	assert_eq(by_phase[MatchState.Phase.POST_MATCH] - by_phase[MatchState.Phase.RESULT], 600,
		"RESULT must last result_display_sec (10.0s = 600t)")

## Test: Same roster + seed_base yields byte-identical (phase, tick) logs
func test_determinism_identical_runs() -> void:
	var director_a := _make_director([1, 2, 3, 4], 42)
	_run_full_walk(director_a)
	var log_a := _phase_log.duplicate()
	var seed_a: int = director_a.match_state.match_seed

	_phase_log = []
	_current_tick = 0
	var director_b := _make_director([1, 2, 3, 4], 42)
	_run_full_walk(director_b)

	assert_eq(_phase_log, log_a, "Two runs with same roster+seed must produce identical logs")
	assert_eq(director_b.match_state.match_seed, seed_a, "Match seed must be identical")
	assert_eq(log_a, EXPECTED_WALK, "Run A must match the expected walk")

## Test: match_seed = seed_base + match_index assigned at ROUND_SETUP, and
## match_index increments after the POST_MATCH reset
func test_match_seed_assignment() -> void:
	var director := _make_director([1, 2], 42)
	director.request_match_start()
	_drive_ticks(director, 1, 180)
	assert_eq(director.match_state.phase, MatchState.Phase.PVE_RACE)
	assert_eq(director.match_state.match_seed, 42, "First match seed = seed_base + 0")

	# Finish the match and start a second one.
	director.request_boss_lock()
	director.request_boss_lock()
	_drive_ticks(director, 181, 180)
	director.request_boss_a1_end()
	_drive_ticks(director, 361, 600)
	_drive_ticks(director, 961, 1)
	assert_eq(director.match_state.phase, MatchState.Phase.LOBBY)

	director.request_match_start()
	_drive_ticks(director, 962, 180)
	assert_eq(director.match_state.match_seed, 43, "Second match seed = seed_base + 1")

## Test: match_started fires once at PVE_RACE, match_ended(NONE) once at RESULT
func test_lifecycle_events_fire_once() -> void:
	var director := _make_director()
	_run_full_walk(director)
	assert_eq(_match_started_count, 1, "match_started must fire exactly once")
	assert_eq(_match_ended_events, [TeamId.NONE] as Array[int],
		"match_ended must fire exactly once with winner NONE (stub)")

## Test: LOBBY assignment alternates RED/BLUE over sorted peer ids (host first)
func test_team_assignment_alternates() -> void:
	var director := _make_director([1, 2, 3, 4])
	assert_eq(director.get_team(1), TeamId.RED)
	assert_eq(director.get_team(2), TeamId.BLUE)
	assert_eq(director.get_team(3), TeamId.RED)
	assert_eq(director.get_team(4), TeamId.BLUE)
	assert_eq(director.get_team(999), TeamId.NONE, "Unknown peers get NONE")
	assert_eq(_team_assigned_count, 1, "Initial LOBBY assignment emits team_assigned")

## Test: Odd roster gives RED the extra player (index 0, 2 → RED)
func test_team_assignment_odd_roster() -> void:
	var director := _make_director([1, 2, 3])
	assert_eq(director.get_team(1), TeamId.RED)
	assert_eq(director.get_team(2), TeamId.BLUE)
	assert_eq(director.get_team(3), TeamId.RED)

## Test: LOBBY churn triggers a full deterministic recompute + re-emit
func test_lobby_churn_full_recompute() -> void:
	var director := _make_director([1, 2])
	assert_eq(director.get_team(2), TeamId.BLUE)
	# Peer 3 joins during LOBBY: roster re-sorted, teams recomputed.
	director.roster_override = [3, 1, 2]  # unsorted on purpose
	EventBus.client_connected.emit(3)
	assert_eq(director.get_team(1), TeamId.RED)
	assert_eq(director.get_team(2), TeamId.BLUE)
	assert_eq(director.get_team(3), TeamId.RED)
	assert_eq(_team_assigned_count, 2, "Churn in LOBBY must re-emit team_assigned")

## Test: Roster freezes after LOBBY — churn mid-match changes nothing
func test_roster_frozen_after_lobby() -> void:
	var director := _make_director([1, 2])
	director.request_match_start()
	assert_eq(director.match_state.phase, MatchState.Phase.COUNTDOWN)
	var assigned_before := _team_assigned_count
	director.roster_override = [1, 2, 9]
	EventBus.client_connected.emit(9)
	assert_eq(director.get_team(9), TeamId.NONE, "Joiner mid-match gets NONE")
	assert_eq(director.get_team(1), TeamId.RED, "Existing assignment unchanged")
	assert_eq(_team_assigned_count, assigned_before, "No re-emit after LOBBY")

## Test: Stub seam methods are no-ops outside their source phase
func test_stub_phase_guards() -> void:
	var director := _make_director()
	director.request_boss_lock()  # in LOBBY: no-op
	director.request_boss_a1_end()  # in LOBBY: no-op
	assert_eq(director.match_state.phase, MatchState.Phase.LOBBY)
	director.request_match_start()
	director.request_match_start()  # in COUNTDOWN: no-op
	assert_eq(director.match_state.phase, MatchState.Phase.COUNTDOWN)
	_drive_ticks(director, 1, 180)
	director.request_match_start()  # in PVE_RACE: no-op
	director.request_boss_a1_end()  # in PVE_RACE: no-op
	assert_eq(director.match_state.phase, MatchState.Phase.PVE_RACE)
	assert_eq(_phase_log.size(), 3, "Guarded stubs must not emit phase entries")

func test_character_selection_deadline_is_exact_and_cancels() -> void:
	var director := _make_director([1, 2])
	assert_true(director.begin_character_selection([1, 2]))
	assert_eq(director.match_state.phase, MatchState.Phase.CHARACTER_SELECT)
	assert_eq(director.match_state.selection_deadline_tick, 1800)
	director.tick_update(1799)
	assert_eq(director.match_state.phase, MatchState.Phase.CHARACTER_SELECT)
	director.tick_update(1800)
	assert_eq(director.match_state.phase, MatchState.Phase.LOBBY)
	assert_eq(director.match_state.selection_deadline_tick, 0)

func test_character_selection_all_ready_seam_enters_countdown() -> void:
	var director := _make_director([1, 2])
	director.begin_character_selection([1, 2])
	assert_true(director.complete_character_selection())
	assert_eq(director.match_state.phase, MatchState.Phase.COUNTDOWN)
	assert_eq(director.match_state.selection_deadline_tick, 0)

## Test: Late-join catch-up is silent — replayed values emit no phase_changed,
## then post-arm real changes emit exactly once
func test_silent_late_join_catchup() -> void:
	# Simulate a client peer (unique id != 1) receiving a full snapshot.
	_client_peer = ENetMultiplayerPeer.new()
	_client_peer.create_client("127.0.0.1", 44999)
	multiplayer.multiplayer_peer = _client_peer
	var state := MatchState.new()
	add_child_autofree(state)

	# Catch-up burst: full snapshot lands before the first tick loop ends.
	state.phase = MatchState.Phase.PVE_RACE
	state.phase_entered_tick = 500
	state.match_seed = 42
	state.team_red_score = 3
	assert_eq(_phase_log.size(), 0, "Catch-up must emit no phase_changed burst")

	# First tick loop arms the setters; replayed identical values stay silent.
	NetworkTime.after_tick_loop.emit()
	state.phase = MatchState.Phase.PVE_RACE
	assert_eq(_phase_log.size(), 0, "Re-applied snapshot values must stay silent")

	# A real post-arm transition surfaces exactly once.
	state.phase = MatchState.Phase.BOSS_LOCK
	assert_eq(_phase_log.size(), 1)
	assert_eq(_phase_log[0][0], MatchState.Phase.BOSS_LOCK)

## Test: main.tscn wires MatchState + StateSynchronizer + MatchDirector under Main
func test_main_scene_contains_match_nodes() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	var scene_state := packed.get_state()
	var paths := []
	for i in scene_state.get_node_count():
		paths.append(str(scene_state.get_node_path(i)))
	assert_has(paths, "./MatchState", "main.tscn must contain MatchState")
	assert_has(paths, "./MatchState/StateSynchronizer", "MatchState must have a StateSynchronizer child")
	assert_has(paths, "./MatchDirector", "main.tscn must contain MatchDirector")
