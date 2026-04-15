# res://common/components/ServerState.gd
class_name ServerState
extends Node

signal health_changed(current: int, maximum: int)
signal death_changed(is_dead: bool)
signal name_changed(new_name: String)

@export var max_health: int = 100
@export var sync_health: int = 100
@export var sync_is_dead: bool = false
@export var player_name: String = "Player"
@export var knockback_velocity: Vector3 = Vector3.ZERO
@export var knockback_remaining_time: float = 0.0

func _ready() -> void:
	set_multiplayer_authority(1)
	var sync = get_node_or_null("StateSynchronizer")
	if sync:
		sync.add_state(self, "sync_health")
		sync.add_state(self, "sync_is_dead")
		sync.add_state(self, "player_name")
		sync.add_state(self, "knockback_velocity")
		sync.add_state(self, "knockback_remaining_time")
		if sync.has_method("process_settings"):
			sync.process_settings()
