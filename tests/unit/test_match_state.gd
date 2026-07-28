# tests/unit/test_match_state.gd
extends GutTest

## Unit tests for MatchState: enum shape, defaults, setter value-guards, and
## the _signals_armed late-join guard (catch-up must be silent on clients).

var _phase_events: Array[int] = []
var _client_peer: ENetMultiplayerPeer

func before_each() -> void:
	# Explicit offline peer: unique id 1 (server) for authority-side tests.
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_phase_events = []
	EventBus.phase_changed.connect(_on_phase_changed)

func after_each() -> void:
	EventBus.phase_changed.disconnect(_on_phase_changed)
	if is_instance_valid(_client_peer):
		_client_peer.close()
	_client_peer = null
	multiplayer.multiplayer_peer = null

func _on_phase_changed(phase: int) -> void:
	_phase_events.append(phase)

## Creates a client-side (non-authority) MatchState. An unconnected ENet
## client peer gives this tree a unique id != 1, so the authority-1 node goes
## through the real client path: _signals_armed starts false and arms on the
## first NetworkTime.after_tick_loop.
func _make_client_state() -> MatchState:
	_client_peer = ENetMultiplayerPeer.new()
	_client_peer.create_client("127.0.0.1", 44999)  # no server; id != 1
	multiplayer.multiplayer_peer = _client_peer
	assert_ne(multiplayer.get_unique_id(), 1, "Client sim must not be peer 1")
	var state := MatchState.new()
	add_child_autofree(state)
	return state

## Test: Phase enum has exactly the nine spec phases, LOBBY = 0
func test_phase_enum_values() -> void:
	assert_eq(MatchState.Phase.LOBBY, 0)
	assert_eq(MatchState.Phase.COUNTDOWN, 1)
	assert_eq(MatchState.Phase.ROUND_SETUP, 2)
	assert_eq(MatchState.Phase.PVE_RACE, 3)
	assert_eq(MatchState.Phase.BOSS_LOCK, 4)
	assert_eq(MatchState.Phase.BOSS_DEPLOY, 5)
	assert_eq(MatchState.Phase.BOSS_A1, 6)
	assert_eq(MatchState.Phase.RESULT, 7)
	assert_eq(MatchState.Phase.POST_MATCH, 8)
	assert_eq(MatchState.Phase.size(), 9, "Exactly nine phases per spec")

## Test: Replicated defaults are the LOBBY zero state
func test_defaults() -> void:
	var state := MatchState.new()
	add_child_autofree(state)
	assert_eq(state.phase, MatchState.Phase.LOBBY)
	assert_eq(state.phase_entered_tick, 0)
	assert_eq(state.match_seed, 0)
	assert_eq(state.team_red_score, 0)
	assert_eq(state.team_blue_score, 0)
	assert_eq(state.winner, TeamId.NONE)

## Test: Authority (server) setters assign but never emit from the setter —
## the MatchDirector announces server-side phase entries.
func test_server_setters_assign_without_emitting() -> void:
	var state := MatchState.new()
	add_child_autofree(state)
	assert_true(state.is_multiplayer_authority(), "Default authority must be server")
	state.phase = MatchState.Phase.PVE_RACE
	state.phase_entered_tick = 42
	state.match_seed = 7
	assert_eq(state.phase, MatchState.Phase.PVE_RACE)
	assert_eq(state.phase_entered_tick, 42)
	assert_eq(state.match_seed, 7)
	assert_eq(_phase_events.size(), 0, "Server setter must not emit phase_changed")

## Test: Unarmed client setter suppresses the catch-up burst entirely
func test_unarmed_client_suppresses_catchup() -> void:
	var state := _make_client_state()
	assert_false(state._signals_armed, "Client must start unarmed")
	# Simulates _PropertySnapshot.apply() replaying a PVE_RACE match state.
	state.phase = MatchState.Phase.PVE_RACE
	state.phase_entered_tick = 500
	state.match_seed = 42
	assert_eq(state.phase, MatchState.Phase.PVE_RACE, "Values still land")
	assert_eq(_phase_events.size(), 0, "Catch-up must emit no phase_changed")

## Test: After arming, a real replicated change emits phase_changed once
func test_armed_client_emits_on_real_change() -> void:
	var state := _make_client_state()
	NetworkTime.after_tick_loop.emit()  # one-shot arm
	assert_true(state._signals_armed, "Client must be armed after first tick loop")
	state.phase = MatchState.Phase.PVE_RACE
	assert_eq(_phase_events, [MatchState.Phase.PVE_RACE] as Array[int])

## Test: Value-guard suppresses re-applied identical snapshots (netfox
## _PropertySnapshot.apply() writes unconditionally every tick)
func test_value_guard_suppresses_identical_writes() -> void:
	var state := _make_client_state()
	NetworkTime.after_tick_loop.emit()
	state.phase = MatchState.Phase.BOSS_LOCK
	state.phase = MatchState.Phase.BOSS_LOCK
	state.phase = MatchState.Phase.BOSS_LOCK
	assert_eq(_phase_events.size(), 1, "Identical re-writes must not re-emit")

## Test: Score and winner stubs guard identically (no crash, values land)
func test_stub_property_guards() -> void:
	var state := _make_client_state()
	NetworkTime.after_tick_loop.emit()
	state.team_red_score = 3
	state.team_red_score = 3
	state.team_blue_score = 1
	state.winner = TeamId.RED
	state.winner = TeamId.RED
	assert_eq(state.team_red_score, 3)
	assert_eq(state.team_blue_score, 1)
	assert_eq(state.winner, TeamId.RED)
	assert_eq(_phase_events.size(), 0, "Stub props never emit phase_changed")

## Test: Arming is one-shot — the connection is released after the first loop
func test_arming_is_one_shot() -> void:
	var state := _make_client_state()
	NetworkTime.after_tick_loop.emit()
	assert_true(state._signals_armed)
	assert_false(NetworkTime.after_tick_loop.is_connected(state._arm_signals),
		"One-shot connection must be released after arming")
	NetworkTime.after_tick_loop.emit()
	assert_true(state._signals_armed, "Repeated tick loops keep it armed without stacking")
