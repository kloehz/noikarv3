# res://common/SoulEntity.gd
extends Area3D

## Represents a volatile soul dropped by a mob.
## Must be collected within a time limit or it might respawn the mob.

signal collected(player: Node3D)
signal expired

@export var lifetime: float = 10.0
@export var respawn_probability: float = 0.4
@export var original_mob_scene_path: String = "res://scenes/TrainingDummy.tscn"

var _timer: float = 0.0
var _is_collected: bool = false

func _ready() -> void:
	if not multiplayer.is_server():
		set_process(false)
		return
		
	_timer = lifetime
	area_entered.connect(_on_area_entered)
	body_entered.connect(_on_body_entered)
	print("[Soul] Spawned at ", global_position)

func _process(delta: float) -> void:
	if _is_collected: return
	
	_timer -= delta
	if _timer <= 0:
		_expire()

func _on_body_entered(body: Node) -> void:
	if _is_collected: return
	
	# Check if it's a player (BaseEntity with a peer-based name)
	if body is BaseEntity and body.name.is_valid_int():
		_collect(body)

func _on_area_entered(area: Area3D) -> void:
	if _is_collected: return
	
	var parent = area.get_parent()
	if parent is BaseEntity and parent.name.is_valid_int():
		_collect(parent)

func _collect(player: BaseEntity) -> void:
	_is_collected = true
	print("[Soul] Collected by ", player.name)
	
	if player.server_state:
		player.server_state.sync_souls += 1
	
	collected.emit(player)
	queue_free()

func _expire() -> void:
	_is_collected = true
	print("[Soul] Expired at ", global_position)
	expired.emit()
	queue_free()
