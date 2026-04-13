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
		print("[ServerState] %s health changed: %d -> %d (Server: %s)" % [get_parent().name, sync_health, v, str(multiplayer.is_server())])
		sync_health = v
		health_changed.emit(sync_health, max_health)

@export var sync_is_dead: bool = false:
	set(v):
		if sync_is_dead == v: return
		print("[ServerState] %s death changed: %s -> %s" % [get_parent().name, str(sync_is_dead), str(v)])
		sync_is_dead = v
		death_changed.emit(sync_is_dead)

@export var player_name: String = "Player":
	set(v):
		if player_name == v: return
		player_name = v
		name_changed.emit(player_name)

## Impulse force sent by the server to push this entity
@export var knockback_impulse: Vector3 = Vector3.ZERO

func _ready() -> void:
	# CRITICAL: This node must always be server-authoritative.
	set_multiplayer_authority(1)
	
	# Force Netfox to update its cache for this node
	var sync = get_node_or_null("StateSynchronizer")
	if sync and sync.has_method("process_settings"):
		sync.process_settings()
