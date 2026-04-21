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
	
	# Check if it's a player or a pet (base entities)
	var entity = body as BaseEntity
	if entity and (entity.is_in_group(&"players") or entity.name.is_valid_int()):
		_collect(entity)

func _on_area_entered(area: Area3D) -> void:
	if _is_collected: return
	
	var parent = area.get_parent()
	var entity = parent as BaseEntity
	if entity and (entity.is_in_group(&"players") or entity.name.is_valid_int()):
		_collect(entity)

func _collect(player: BaseEntity) -> void:
	_is_collected = true
	print("[SERVER] Soul collected by %s" % player.name)
	
	if player.server_state:
		player.server_state.sync_souls += 1
		print("[SERVER] Player %s now has %d souls" % [player.name, player.server_state.sync_souls])
	else:
		print("[SERVER ERROR] Player %s has no ServerState to store souls!" % player.name)
	
	collected.emit(player)
	queue_free()

func _expire() -> void:
	_is_collected = true
	print("[Soul] Expired at ", global_position)
	expired.emit()
	queue_free()
