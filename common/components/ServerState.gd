# res://common/components/ServerState.gd
class_name ServerState
extends Node

signal health_changed(current: int, maximum: int)
signal death_changed(is_dead: bool)
signal name_changed(new_name: String)
signal character_changed(character_id: String)
signal souls_changed(amount: int)
signal team_changed(new_team: int)
signal pet_data_received(type: String, level: int)
signal heal_received(amount: int)
signal boss_damage_changed(red_damage: int, blue_damage: int)

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

## Server-validated playable character identity. Clients use this replicated
## value to load the same actor scene as the authoritative server.
@export var character_id: String = "warrior":
	set(v):
		if character_id == v: return
		character_id = v
		character_changed.emit(character_id)

@export var sync_souls: int = 0:
	set(v):
		if sync_souls == v: return
		sync_souls = v
		souls_changed.emit(sync_souls)

## Replicated per-entity team identity (int-serialized TeamId).
## Server-written only; stays NONE until roster assignment (Roadmap Stage 2 PR3).
@export var team_id: int = TeamId.NONE:
	set(v):
		if team_id == v: return
		team_id = v
		team_changed.emit(team_id)

## Server-tracked boss damage attribution. Updated by MatchManager when a
## hit lands on the boss; replicated to clients so the shared boss health
## bar can show each team's contribution in real time. Stays at 0 for
## non-boss entities.
@export var red_damage_taken: int = 0:
	set(v):
		if red_damage_taken == v: return
		red_damage_taken = v
		boss_damage_changed.emit(red_damage_taken, blue_damage_taken)

@export var blue_damage_taken: int = 0:
	set(v):
		if blue_damage_taken == v: return
		blue_damage_taken = v
		boss_damage_changed.emit(red_damage_taken, blue_damage_taken)

@export var knockback_velocity: Vector3 = Vector3.ZERO
@export var knockback_remaining_time: float = 0.0

@export var is_stunned: bool = false
@export var stun_remaining_time: float = 0.0

@export var sync_is_dashing: bool = false

## Server-authored heal event. The amount is written first, then incrementing
## the sequence replicates one visual event to every peer.
@export var sync_heal_amount: int = 0
@export var sync_heal_sequence: int = 0:
	set(v):
		if sync_heal_sequence == v: return
		sync_heal_sequence = v
		if sync_heal_sequence > 0 and sync_heal_amount > 0:
			heal_received.emit(sync_heal_amount)

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
		sync.add_state(self, "character_id")
		sync.add_state(self, "sync_souls")
		sync.add_state(self, "team_id")
		sync.add_state(self, "red_damage_taken")
		sync.add_state(self, "blue_damage_taken")
		sync.add_state(self, "knockback_velocity")
		sync.add_state(self, "knockback_remaining_time")
		sync.add_state(self, "is_stunned")
		sync.add_state(self, "stun_remaining_time")
		sync.add_state(self, "sync_is_dashing")
		sync.add_state(self, "sync_heal_amount")
		sync.add_state(self, "sync_heal_sequence")
		sync.add_state(self, "pet_type_sync")
		sync.add_state(self, "power_level_sync")
		if sync.has_method("process_settings"):
			print("[DEBUG] ServerState %s processing synchronizer settings" % get_parent().name)
			sync.process_settings()
	else:
		print("[WARNING] ServerState %s: StateSynchronizer not found!" % get_parent().name)
