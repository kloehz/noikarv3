# res://common/components/ServerState.gd
class_name ServerState
extends Node

signal health_changed(current: int, maximum: int)
signal death_changed(is_dead: bool)
signal name_changed(new_name: String)
signal souls_changed(amount: int)
signal pet_data_received(type: String, level: int)

@export var max_health: int = 100:
	set(v):
		if max_health == v: return
		max_health = v
		health_changed.emit(sync_health, max_health)

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

@export var sync_souls: int = 0:
	set(v):
		if sync_souls == v: return
		sync_souls = v
		souls_changed.emit(sync_souls)

@export var knockback_velocity: Vector3 = Vector3.ZERO
@export var knockback_remaining_time: float = 0.0

@export var is_stunned: bool = false
@export var stun_remaining_time: float = 0.0

@export var pet_type_sync: String = "":
	set(v):
		if pet_type_sync == v: return
		pet_type_sync = v
		if not pet_type_sync.is_empty():
			pet_data_received.emit(pet_type_sync, power_level_sync)

@export var power_level_sync: int = 0:
	set(v):
		if power_level_sync == v: return
		power_level_sync = v
		if not pet_type_sync.is_empty():
			pet_data_received.emit(pet_type_sync, power_level_sync)

func _ready() -> void:
	print("[DEBUG] ServerState initialization for entity: %s" % get_parent().name)
	set_multiplayer_authority(1)
	var sync = get_node_or_null("StateSynchronizer")
	if sync:
		print("[DEBUG] ServerState %s found StateSynchronizer, adding states" % get_parent().name)
		sync.add_state(self, "max_health")
		sync.add_state(self, "sync_health")
		sync.add_state(self, "sync_is_dead")
		sync.add_state(self, "player_name")
		sync.add_state(self, "sync_souls")
		sync.add_state(self, "knockback_velocity")
		sync.add_state(self, "knockback_remaining_time")
		sync.add_state(self, "is_stunned")
		sync.add_state(self, "stun_remaining_time")
		sync.add_state(self, "pet_type_sync")
		sync.add_state(self, "power_level_sync")
		if sync.has_method("process_settings"):
			print("[DEBUG] ServerState %s processing synchronizer settings" % get_parent().name)
			sync.process_settings()
	else:
		print("[WARNING] ServerState %s: StateSynchronizer not found!" % get_parent().name)
