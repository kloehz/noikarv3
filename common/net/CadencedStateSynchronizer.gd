@tool
extends "res://addons/netfox/state-synchronizer.gd"
class_name CadencedStateSynchronizer

## Project-local StateSynchronizer that reduces only multiplayer-authority
## snapshot submission cadence. Non-authority peers still run the vendor
## StateSynchronizer every tick so received history and TickInterpolator
## presentation keep their normal cadence.

@export_range(1, 128, 1, "or_greater")
var authority_snapshot_stride: int = 2:
	set(value):
		authority_snapshot_stride = maxi(1, value)
		_recompute_authority_snapshot_phase()

var _authority_snapshot_phase: int = 0

func process_settings() -> void:
	super.process_settings()
	_recompute_authority_snapshot_phase()

func get_authority_snapshot_phase() -> int:
	return _authority_snapshot_phase

func should_submit_authority_snapshot(tick: int) -> bool:
	var stride := maxi(1, authority_snapshot_stride)
	return posmod(tick, stride) == _authority_snapshot_phase

func _connect_signals() -> void:
	if not is_inside_tree():
		return
	var after_tick_callable := Callable(self, "_after_tick")
	if not NetworkTime.after_tick.is_connected(after_tick_callable):
		NetworkTime.after_tick.connect(after_tick_callable)
	var after_loop_callable := Callable(self, "_after_loop")
	if not NetworkTime.after_tick_loop.is_connected(after_loop_callable):
		NetworkTime.after_tick_loop.connect(after_loop_callable)

func _disconnect_signals() -> void:
	var after_tick_callable := Callable(self, "_after_tick")
	if NetworkTime.after_tick.is_connected(after_tick_callable):
		NetworkTime.after_tick.disconnect(after_tick_callable)
	var after_loop_callable := Callable(self, "_after_loop")
	if NetworkTime.after_tick_loop.is_connected(after_loop_callable):
		NetworkTime.after_tick_loop.disconnect(after_loop_callable)

func _after_tick(dt: float, tick: int) -> void:
	if is_multiplayer_authority() and not should_submit_authority_snapshot(tick):
		return
	super._after_tick(dt, tick)

func _recompute_authority_snapshot_phase() -> void:
	var stride := maxi(1, authority_snapshot_stride)
	_authority_snapshot_phase = posmod(hash(_get_authority_phase_identity()), stride)

func _get_authority_phase_identity() -> String:
	if root == null:
		return name
	if root.is_inside_tree():
		return str(root.get_path())
	return root.name
