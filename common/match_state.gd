# res://common/match_state.gd
## Server-owned replicated match snapshot (Roadmap Stage 2).
## The MatchDirector is the sole writer; clients observe via StateSynchronizer.
##
## Late-join safety (two layers, both mandatory):
## 1. Every setter guards `if x == v: return` — netfox _PropertySnapshot.apply()
##    re-applies the full snapshot unconditionally EVERY tick on clients.
## 2. On non-authority, `_signals_armed` starts false and is armed by a one-shot
##    NetworkTime.after_tick_loop callback. Catch-up lands in the first tick
##    loop, before arming, so replayed values emit no phase_changed burst.
##
## Signal flow: on the server the MatchDirector emits EventBus.phase_changed at
## each phase entry; on clients the phase setter emits it only on a real value
## change once armed. Each side emits exactly once per effective phase entry.
class_name MatchState
extends Node

## Match phases. Exactly these nine, in this order (LOBBY = 0 zero value).
enum Phase {
	LOBBY,
	COUNTDOWN,
	ROUND_SETUP,
	PVE_RACE,
	BOSS_LOCK,
	BOSS_DEPLOY,
	BOSS_A1,
	RESULT,
	POST_MATCH,
}

## False on clients until the first tick loop completes (catch-up window).
var _signals_armed: bool = true

## Current match phase (int-serialized MatchState.Phase).
@export var phase: int = Phase.LOBBY:
	set(v):
		if phase == v: return
		phase = v
		# Server-side writes are announced by the MatchDirector; only clients
		# (non-authority) surface replicated changes here, once armed.
		if _signals_armed and not is_multiplayer_authority():
			EventBus.phase_changed.emit(phase)

## Simulation tick at which the current phase was entered.
@export var phase_entered_tick: int = 0:
	set(v):
		if phase_entered_tick == v: return
		phase_entered_tick = v

## Deterministic match seed assigned at ROUND_SETUP (seed_base + match_index).
@export var match_seed: int = 0:
	set(v):
		if match_seed == v: return
		match_seed = v

## Score stubs (0 in Stage 2; consumed by later stages).
@export var team_red_score: int = 0:
	set(v):
		if team_red_score == v: return
		team_red_score = v

@export var team_blue_score: int = 0:
	set(v):
		if team_blue_score == v: return
		team_blue_score = v

## Winning team (int-serialized TeamId). NONE until RESULT declares one.
@export var winner: int = TeamId.NONE:
	set(v):
		if winner == v: return
		winner = v

func _ready() -> void:
	set_multiplayer_authority(1)
	if not is_multiplayer_authority():
		# Client: suppress signals until catch-up has landed in the first
		# tick loop, then arm exactly once.
		_signals_armed = false
		NetworkTime.after_tick_loop.connect(_arm_signals, CONNECT_ONE_SHOT)
	var sync = get_node_or_null("StateSynchronizer")
	if sync:
		sync.add_state(self, "phase")
		sync.add_state(self, "phase_entered_tick")
		sync.add_state(self, "match_seed")
		sync.add_state(self, "team_red_score")
		sync.add_state(self, "team_blue_score")
		sync.add_state(self, "winner")
		if sync.has_method("process_settings"):
			sync.process_settings()
	else:
		print("[WARNING] MatchState: StateSynchronizer not found!")

func _arm_signals() -> void:
	_signals_armed = true
