class_name NpcDecisionClock
extends RefCounted

## An elapsed-seconds clock, independent of network/render tickrate.
## Each decision receives all time since its previous decision, never a
## multiplied delta guessed from the number of skipped network ticks.
var remaining: float = 0.0
var interval: float = 0.1
var _elapsed: float = 0.0

func configure(entity_key: String, frequency: float) -> void:
	interval = 1.0 / clampf(frequency, 5.0, 10.0)
	remaining = float(entity_key.hash() & 0xffff) / 65536.0 * interval
	_elapsed = 0.0

func advance(delta: float) -> float:
	_elapsed += delta
	remaining -= delta
	if remaining > 0.000001:
		return 0.0
	remaining = maxf(0.0, remaining + interval)
	var elapsed := _elapsed
	_elapsed = 0.0
	return elapsed

func wake() -> void:
	remaining = 0.0

func pending_elapsed() -> float:
	return _elapsed
