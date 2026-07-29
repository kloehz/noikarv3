# res://common/match_director.gd
## Server-authoritative match phase machine (Roadmap Stage 2).
##
## Pure timing core: all transitions are driven by `tick_update(tick)` (wired to
## NetworkTime.after_tick @60Hz on the server) or by the public stub seam
## methods. No rollback participation, no SceneTreeTimer, no wall-clock, no RNG.
## Clients never run transition logic — the tick hookup is server-only and
## MatchState changes reach them via StateSynchronizer.
##
## Phase walk: LOBBY ─host→ CHARACTER_SELECT ─all ready→ COUNTDOWN ─180t→ ROUND_SETUP ─seed→ PVE_RACE
## ─stub→ BOSS_LOCK ─stub→ BOSS_DEPLOY ─180t→ BOSS_A1 ─stub→ RESULT ─600t→
## POST_MATCH ─next tick→ LOBBY.
class_name MatchDirector
extends Node

## Match rules data; timers derive from it at phase entry. Assigned in scene.
@export var rules: MatchRules

## Base for deterministic match seeds: match_seed = seed_base + match_index.
@export var seed_base: int = 0

## Replicated match snapshot written by this director. Injected by tests; in
## the scene it is the sibling MatchState node under Main.
var match_state: MatchState

## Test seam: when non-empty, replaces the computed roster (host 1 +
## multiplayer.get_peers()) entirely. Deterministic LOBBY team assignment and
## headless determinism tests inject their roster here.
var roster_override: Array[int] = []

## Server-only roster: peer_id -> TeamId.Value. Computed in LOBBY, frozen after.
var _roster: Dictionary = {}
## Tick of the last tick_update call; stubs stamp phase_entered_tick with it.
var _last_tick: int = 0
## Count of matches played this session; feeds the deterministic seed.
var _match_index: int = 0
## Ticks remaining driver for the current timed phase (0 = untimed phase).
var _phase_timer_ticks: int = 0
## Frozen authenticated roster for the current character-selection phase.
var _frozen_peer_ids: Array[int] = []

func _ready() -> void:
	add_to_group(&"match_director")
	if rules == null:
		rules = load("res://common/resources/default_match_rules.tres")
	if match_state == null:
		match_state = get_parent().get_node_or_null("MatchState") as MatchState
	if not multiplayer.is_server():
		# Clients observe replicated MatchState only; no transition logic.
		return
	NetworkTime.after_tick.connect(_on_after_tick)
	EventBus.client_connected.connect(_on_roster_changed.unbind(1))
	EventBus.client_disconnected.connect(_on_roster_changed.unbind(1))
	# Initial LOBBY assignment (host-only roster until peers join).
	_recompute_teams()

## --- Timing core (pure, deterministic) -------------------------------------

## Advances timers. Driven by NetworkTime.after_tick on the server; tests drive
## it directly with synthetic ticks. Server-only logic.
func tick_update(tick: int) -> void:
	_last_tick = tick
	match match_state.phase:
		MatchState.Phase.CHARACTER_SELECT:
			if tick >= match_state.selection_deadline_tick:
				cancel_character_selection(tick)
		MatchState.Phase.COUNTDOWN:
			if tick - match_state.phase_entered_tick >= _phase_timer_ticks:
				_enter_round_setup(tick)
		MatchState.Phase.BOSS_DEPLOY:
			if tick - match_state.phase_entered_tick >= _phase_timer_ticks:
				_enter_phase(MatchState.Phase.BOSS_A1, tick)
		MatchState.Phase.RESULT:
			if tick - match_state.phase_entered_tick >= _phase_timer_ticks:
				_enter_phase(MatchState.Phase.POST_MATCH, tick)
		MatchState.Phase.POST_MATCH:
			# Internal next-tick reset back to LOBBY.
			if tick > match_state.phase_entered_tick:
				_reset_to_lobby(tick)

## --- Stub seam methods (Stage 3+ wires real conditions) ---------------------

## Compatibility stub for existing non-lobby test seams. Authenticated lobbies
## must use begin_character_selection with a frozen roster instead.
func request_match_start() -> void:
	if not multiplayer.is_server(): return
	if match_state.phase != MatchState.Phase.LOBBY: return
	_enter_phase(MatchState.Phase.COUNTDOWN, _last_tick)

func begin_character_selection(peer_ids: Array[int]) -> bool:
	if not multiplayer.is_server() or match_state.phase != MatchState.Phase.LOBBY:
		return false
	_frozen_peer_ids = peer_ids.duplicate()
	_frozen_peer_ids.sort()
	match_state.selection_deadline_tick = _last_tick + rules.seconds_to_ticks(rules.character_select_sec)
	_enter_phase(MatchState.Phase.CHARACTER_SELECT, _last_tick)
	return true

func complete_character_selection() -> bool:
	if not multiplayer.is_server() or match_state.phase != MatchState.Phase.CHARACTER_SELECT:
		return false
	EventBus.character_selection_launching.emit()
	_frozen_peer_ids.clear()
	match_state.selection_deadline_tick = 0
	_enter_phase(MatchState.Phase.COUNTDOWN, _last_tick)
	return true

func cancel_character_selection(tick: int = _last_tick) -> void:
	if match_state.phase != MatchState.Phase.CHARACTER_SELECT:
		return
	_frozen_peer_ids.clear()
	match_state.selection_deadline_tick = 0
	_enter_phase(MatchState.Phase.LOBBY, tick)
	EventBus.character_selection_cancelled.emit()

func frozen_peer_ids() -> Array[int]:
	return _frozen_peer_ids.duplicate()

## Stub event: boss lock sequence. First call PVE_RACE → BOSS_LOCK, second
## call BOSS_LOCK → BOSS_DEPLOY (both are distinct stub conditions per spec).
func request_boss_lock() -> void:
	if not multiplayer.is_server(): return
	if match_state.phase == MatchState.Phase.PVE_RACE:
		_enter_phase(MatchState.Phase.BOSS_LOCK, _last_tick)
	elif match_state.phase == MatchState.Phase.BOSS_LOCK:
		_enter_phase(MatchState.Phase.BOSS_DEPLOY, _last_tick)

## Stub event: boss activity 1 resolved. BOSS_A1 → RESULT.
func request_boss_a1_end() -> void:
	if not multiplayer.is_server(): return
	if match_state.phase != MatchState.Phase.BOSS_A1: return
	_enter_phase(MatchState.Phase.RESULT, _last_tick)

## --- Team assignment (server-only, LOBBY only) ------------------------------

## Returns the assigned team for a peer, NONE if unassigned.
func get_team(peer_id: int) -> TeamId.Value:
	return _roster.get(peer_id, TeamId.NONE)

func _on_after_tick(_delta: float, tick: int) -> void:
	tick_update(tick)

func _on_roster_changed() -> void:
	# Roster freezes once the match leaves LOBBY.
	if match_state.phase == MatchState.Phase.LOBBY:
		_recompute_teams()

## Deterministic LOBBY team assignment: peer ids sorted ascending (host 1
## included), even index → RED, odd index → BLUE. Full recompute on any LOBBY
## roster churn so the same peer set always yields the same assignment.
func _recompute_teams() -> void:
	var ids: Array[int] = []
	if roster_override.is_empty():
		ids.append(1)
		for peer_id in multiplayer.get_peers():
			ids.append(peer_id)
	else:
		ids.append_array(roster_override)
	ids.sort()
	_roster.clear()
	for i in ids.size():
		_roster[ids[i]] = TeamId.RED if i % 2 == 0 else TeamId.BLUE
	EventBus.team_assigned.emit()

## --- Team registry (spawn-sequence ordered, server-only) --------------------

## Per-team registries of stable spawn ids in deterministic spawn-sequence
## order (Array append order — never dictionary iteration order). Stage 2
## enforces no caps; MatchManager registers every typed spawn and unregisters
## despawned players.
var _team_registry: Dictionary = {
	TeamId.NONE: [] as Array[StringName],
	TeamId.RED: [] as Array[StringName],
	TeamId.BLUE: [] as Array[StringName],
}

## Registers a spawn id under a team, preserving spawn-sequence order.
func register_to_team(team: TeamId.Value, spawn_id: StringName) -> void:
	if not _team_registry.has(team):
		_team_registry[team] = [] as Array[StringName]
	_team_registry[team].append(spawn_id)

## Removes a spawn id from a team registry. Order of the remaining ids is
## preserved; unknown ids are ignored.
func unregister_from_team(team: TeamId.Value, spawn_id: StringName) -> void:
	if _team_registry.has(team):
		_team_registry[team].erase(spawn_id)

## Consultation path: spawn ids registered for a team, in spawn order.
func get_team_registry(team: TeamId.Value) -> Array[StringName]:
	return _team_registry.get(team, [] as Array[StringName])

## --- Transitions ------------------------------------------------------------

## ROUND_SETUP: assign the deterministic match seed, then complete setup.
## Initial-spawn routing lands in PR3; setup completes on the same tick here.
func _enter_round_setup(tick: int) -> void:
	match_state.match_seed = seed_base + _match_index
	_enter_phase(MatchState.Phase.ROUND_SETUP, tick)
	_enter_phase(MatchState.Phase.PVE_RACE, tick)

## POST_MATCH → LOBBY: reset per-match state and recompute the roster in place
## (scene-lifetime node; no autoload state-leak on rematch).
func _reset_to_lobby(tick: int) -> void:
	_match_index += 1
	match_state.team_red_score = 0
	match_state.team_blue_score = 0
	match_state.winner = TeamId.NONE
	_frozen_peer_ids.clear()
	match_state.selection_deadline_tick = 0
	_enter_phase(MatchState.Phase.LOBBY, tick)
	_recompute_teams()

## Sole writer path into MatchState. Emits the server-side phase_changed and
## the one-shot lifecycle events; clients observe via replication.
func _enter_phase(p: int, tick: int) -> void:
	match p:
		MatchState.Phase.COUNTDOWN:
			_phase_timer_ticks = rules.seconds_to_ticks(rules.countdown_sec)
		MatchState.Phase.BOSS_DEPLOY:
			_phase_timer_ticks = rules.seconds_to_ticks(rules.boss_deploy_countdown_sec)
		MatchState.Phase.RESULT:
			_phase_timer_ticks = rules.seconds_to_ticks(rules.result_display_sec)
		_:
			_phase_timer_ticks = 0
	match_state.phase = p
	match_state.phase_entered_tick = tick
	EventBus.phase_changed.emit(p)
	match p:
		MatchState.Phase.PVE_RACE:
			EventBus.match_started.emit()
		MatchState.Phase.RESULT:
			EventBus.match_ended.emit(TeamId.NONE)
