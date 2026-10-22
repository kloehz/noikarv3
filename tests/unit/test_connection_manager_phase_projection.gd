extends GutTest

# Exercise the real projection handlers without starting menu UI, auth or networking.
class ProjectionManager extends "res://client/connection_manager.gd":
	var switch_calls: Array[int] = []
	var rendered_snapshots := 0

	func _switch_state(new_state: State) -> void:
		switch_calls.append(new_state)
		current_state = new_state

	func _render_snapshot() -> void:
		rendered_snapshots += 1

const ACTIVE_PHASES := [
	MatchState.Phase.COUNTDOWN,
	MatchState.Phase.ROUND_SETUP,
	MatchState.Phase.PVE_RACE,
	MatchState.Phase.BOSS_LOCK,
	MatchState.Phase.BOSS_DEPLOY,
	MatchState.Phase.BOSS_A1,
]

func _manager() -> ProjectionManager:
	var manager := ProjectionManager.new()
	manager.current_state = manager.State.CHARACTER_SELECT
	return manager

func test_authoritative_pve_race_without_countdown_projects_in_game() -> void:
	var manager := _manager()
	assert_eq(manager.current_state, manager.State.CHARACTER_SELECT)
	manager._on_match_phase_changed(MatchState.Phase.PVE_RACE)
	assert_eq(manager.current_state, manager.State.IN_GAME)
	assert_eq(manager.switch_calls.size(), 1)
	manager.free()

func test_each_active_phase_projects_in_game_without_a_prior_phase_event() -> void:
	for phase in ACTIVE_PHASES:
		var manager := _manager()
		manager._on_match_phase_changed(phase)
		assert_eq(manager.current_state, manager.State.IN_GAME, "Active phase %d" % phase)
		assert_eq(manager.switch_calls.size(), 1)
		manager.free()

func test_non_active_and_unknown_phase_events_do_not_enter_game() -> void:
	for phase in [MatchState.Phase.LOBBY, MatchState.Phase.CHARACTER_SELECT,
			MatchState.Phase.RESULT, MatchState.Phase.POST_MATCH, -1, 999]:
		var manager := _manager()
		manager._on_match_phase_changed(phase)
		assert_eq(manager.current_state, manager.State.CHARACTER_SELECT)
		assert_eq(manager.switch_calls.size(), 0)
		manager.free()

func test_repeated_active_notifications_switch_ui_only_once() -> void:
	var manager := _manager()
	manager._on_match_phase_changed(MatchState.Phase.COUNTDOWN)
	for phase in ACTIVE_PHASES:
		manager._on_match_phase_changed(phase)
		manager._on_match_phase_changed(phase)
	assert_eq(manager.current_state, manager.State.IN_GAME)
	assert_eq(manager.switch_calls.size(), 1, "Do not repeat mouse/focus/UI side effects")
	manager.free()

func test_late_active_snapshots_use_the_same_idempotent_projection() -> void:
	for phase in ACTIVE_PHASES:
		var manager := _manager()
		manager._on_lobby_snapshot_received({"phase": phase, "members": []})
		manager._on_lobby_snapshot_received({"phase": phase, "members": []})
		assert_eq(manager.current_state, manager.State.IN_GAME)
		assert_eq(manager.switch_calls.size(), 1)
		assert_eq(manager.rendered_snapshots, 2, "Normal snapshot rendering is not suppressed")
		assert_eq(manager._snapshot.phase, phase)
		manager.free()

func test_inactive_snapshots_preserve_existing_lobby_and_selection_projection() -> void:
	var manager := _manager()
	manager._on_lobby_snapshot_received({"phase": MatchState.Phase.LOBBY})
	assert_eq(manager.current_state, manager.State.TEAM_LOBBY)
	manager._on_lobby_snapshot_received({"phase": MatchState.Phase.CHARACTER_SELECT})
	assert_eq(manager.current_state, manager.State.CHARACTER_SELECT)
	for phase in [MatchState.Phase.RESULT, MatchState.Phase.POST_MATCH, -1, 999]:
		manager._on_lobby_snapshot_received({"phase": phase})
		assert_eq(manager.current_state, manager.State.CHARACTER_SELECT)
	assert_eq(manager.switch_calls.size(), 2)
	manager.free()

func test_already_in_game_has_no_repeated_switch_or_input_side_effects() -> void:
	var manager := _manager()
	manager.current_state = manager.State.IN_GAME
	var mouse_mode := Input.mouse_mode
	for phase in ACTIVE_PHASES:
		manager._on_match_phase_changed(phase)
		manager._on_lobby_snapshot_received({"phase": phase})
	assert_eq(manager.current_state, manager.State.IN_GAME)
	assert_eq(manager.switch_calls.size(), 0)
	assert_eq(Input.mouse_mode, mouse_mode)
	manager.free()
