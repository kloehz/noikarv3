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
signal damage_received(amount: int, source: Node)
signal boss_damage_changed(red_damage: int, blue_damage: int)
## Emitted whenever sync_threat_table changes on the server. Used by
## debug HUDs; the aggro decision itself is read directly from
## sync_threat_table by mob AI.
signal threat_changed(new_table: Dictionary)

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

## Per-attacker threat table owned by THIS entity. The mob's
## AIComponent reads its OWN table to pick the highest-threat
## attacker — so only the mobs that actually took damage from a
## player will aggro on that player. Without this split, the
## attacker's threat would be visible to every mob in the wave
## and the entire spawn would chase the same target.
##
## Keyed by the attacker's entity name (string). Value is threat
## points, which combine the raw damage and the attacker's
## per-class multiplier (see HurtboxComponent._threat_multiplier_for).
## Decays linearly on authoritative network ticks; entries that hit 0
## are erased so the table doesn't grow unbounded.
@export var sync_threat_table: Dictionary = {}:
	set(v):
		var incoming: Dictionary = v.duplicate(true)
		if sync_threat_table == incoming: return
		sync_threat_table = incoming
		threat_changed.emit(sync_threat_table)

## Threat tables must be reassigned, rather than mutated in place, so the
## StateSynchronizer observes every server-side update.
func add_threat(attacker_name: String, amount: int) -> void:
	if attacker_name.is_empty() or amount <= 0:
		return
	var table: Dictionary = sync_threat_table.duplicate(true)
	table[attacker_name] = int(table.get(attacker_name, 0)) + amount
	sync_threat_table = table

func decay_threat(amount: int) -> void:
	if amount <= 0 or sync_threat_table.is_empty():
		return
	var table: Dictionary = sync_threat_table.duplicate(true)
	for attacker_name in table.keys():
		var remaining: int = max(0, int(table[attacker_name]) - amount)
		if remaining == 0:
			table.erase(attacker_name)
		else:
			table[attacker_name] = remaining
	sync_threat_table = table

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

## Server-authored damage event. Bumping the sequence replicates one hit
## VFX event to every peer; the writer also passes the source so clients
## can attribute the hit for client-side effects (camera shake, sound).
@export var sync_damage_amount: int = 0
@export var sync_damage_source: Node = null
@export var sync_damage_sequence: int = 0:
	set(v):
		if sync_damage_sequence == v: return
		sync_damage_sequence = v
		if sync_damage_sequence > 0 and sync_damage_amount > 0:
			damage_received.emit(sync_damage_amount, sync_damage_source)

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
	set_multiplayer_authority(1)
	var sync = get_node_or_null("StateSynchronizer")
	if sync:
		var properties: Array[String] = [
			"max_health",
			"sync_health",
			"sync_is_dead",
			"team_id",
			"sync_heal_amount",
			"sync_heal_sequence",
			"sync_damage_amount",
			"sync_damage_sequence",
			"is_stunned",
			"stun_remaining_time",
		]
		var entity := get_parent()
		if entity.name.begins_with("PET"):
			properties.append_array(["sync_threat_table", "pet_type_sync", "power_level_sync"])
			_add_npc_presentation_state(sync, entity)
		elif entity.name.begins_with("MOB_") or entity.name.begins_with("BOSS_") \
				or entity.name.begins_with("ELITE") or entity.name.begins_with("Dummy"):
			properties.append_array(["sync_threat_table", "red_damage_taken", "blue_damage_taken"])
			_add_npc_presentation_state(sync, entity)
		else:
			properties.append_array([
				"player_name",
				"character_id",
				"sync_souls",
				"knockback_velocity",
				"knockback_remaining_time",
				"sync_is_dashing",
			])
		for property in properties:
			sync.add_state(self, property)
		if sync.has_method("process_settings"):
			sync.process_settings()
	else:
		print("[WARNING] ServerState %s: StateSynchronizer not found!" % get_parent().name)

func _add_npc_presentation_state(sync: StateSynchronizer, entity: Node) -> void:
	sync.add_state(entity, "global_position")
	sync.add_state(entity, "quaternion")
	var logic := entity.get_node_or_null("LogicComponent")
	if logic:
		sync.add_state(logic, "current_velocity")
	var combat := entity.get_node_or_null("CombatComponent")
	if combat:
		sync.add_state(combat, "sync_attack_count")
