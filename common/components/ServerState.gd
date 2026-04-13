# res://common/components/ServerState.gd
class_name ServerState
extends Node

## Server-authoritative state for entities.
## This node's multiplayer authority is ALWAYS set to the server (peer 1).
## This is required for netfox's StateSynchronizer to correctly deliver
## snapshots to clients — netfox filters by the property node's authority.

signal health_changed(current: int, maximum: int)
signal death_changed(is_dead: bool)
signal name_changed(new_name: String)

@export var max_health: int = 100

@export var sync_health: int = 100:
	set(v):
		if sync_health == v: return
		sync_health = v
		health_changed.emit(sync_health, max_health)

@export var sync_is_dead: bool = false:
	set(v):
		if sync_is_dead == v: return
		sync_is_dead = v
		death_changed.emit(sync_is_dead)

@export var player_name: String = "Player":
	set(v):
		if player_name == v: return
		player_name = v
		name_changed.emit(player_name)

func _ready() -> void:
	# CRITICAL: This node must always be server-authoritative.
	# Without this, netfox's StateSynchronizer ownership check will reject
	# all server snapshots on the client side.
	set_multiplayer_authority(1)
