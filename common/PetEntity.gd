# res://common/PetEntity.gd
extends BaseEntity

## A summoned pet that follows its owner and attacks enemies.
## Scales with power_level (souls invested).
## Inherits from BaseEntity to reuse component handling logic.

# --- CONSTANTS: Level Tiers ---
const LVL_TIER_2: int = 11
const LVL_TIER_3: int = 26

# --- CONSTANTS: Stats & Balances ---
const BASE_DMG: int = 12
const BASE_HP_TANK: int = 250
const BASE_HP_HEAL: int = 80
const BASE_HP_DMG: int = 100
const SKILL_COOLDOWN: float = 4.0

@export var owner_id: int = 1
@export var pet_type: String = "ATTACK"
@export var power_level: int = 0

# Skill Timers
var skill_timer: float = 0.0
var skill_interval: float = SKILL_COOLDOWN

var _has_setup: bool = false

func _ready() -> void:
	# BaseEntity handles authority, server_state link, and initial loading
	super._ready()
	
	if server_state:
		# On clients, wait for synchronized data to trigger setup
		if not multiplayer.is_server():
			if not server_state.is_connected("pet_data_received", _on_pet_data_received):
				server_state.pet_data_received.connect(_on_pet_data_received)
			
			# Initial check in case it's already there
			if not server_state.pet_type_sync.is_empty():
				_check_delayed_setup.call_deferred()

func _check_delayed_setup() -> void:
	if server_state and not server_state.pet_type_sync.is_empty():
		setup_pet(owner_id, server_state.pet_type_sync, server_state.power_level_sync)

func _on_pet_data_received(t: String, l: int) -> void:
	setup_pet(owner_id, t, l)

func setup_pet(p_owner_id: int, p_type: String, p_souls: int) -> void:
	if _has_setup and pet_type == p_type and power_level == p_souls: return
	
	owner_id = p_owner_id
	pet_type = p_type
	power_level = p_souls
	
	_has_setup = true
	
	# Update path for BaseEntity to load the correct model
	var actor_path = "res://scenes/characters/PetDmg.tscn"
	match pet_type:
		"TANK": actor_path = "res://scenes/characters/PetTank.tscn"
		"HEAL": actor_path = "res://scenes/characters/PetHeal.tscn"
	
	character_actor_path = actor_path
	
	# Re-load model via BaseEntity logic
	if character_actor:
		character_actor.queue_free()
		character_actor = null
		
	_load_character_actor()
	
	# Hide base placeholder mesh if it exists
	if has_node("MeshInstance3D"):
		get_node("MeshInstance3D").visible = false
	
	# Re-link VisualComponent
	if has_node("VisualComponent"):
		var vis = get_node("VisualComponent")
		vis.setup_with_actor(character_actor)
		vis.update_name(pet_type)
		# Force initial visual refresh
		vis.play_spawn_effect()
	
	if multiplayer.is_server() and server_state:
		server_state.pet_type_sync = p_type
		server_state.power_level_sync = p_souls
		_apply_power_scaling()
		
		# Configure CombatComponent for basic attacks
		var combat = get_node_or_null("CombatComponent")
		if combat:
			combat.damage = BASE_DMG + (power_level * 1)
			
		print("[Pet] %s setup for %d | Power: %d" % [pet_type, owner_id, power_level])

func _apply_power_scaling() -> void:
	var multiplier = 1.0 + (power_level * 0.1)
	
	if server_state:
		var base_hp = BASE_HP_DMG
		if pet_type == "TANK": base_hp = BASE_HP_TANK
		elif pet_type == "HEAL": base_hp = BASE_HP_HEAL
		
		apply_stats(int(base_hp * multiplier))
	
	# Visual scaling
	scale = Vector3.ONE * (1.0 + (power_level * 0.02))

func _rollback_tick(delta: float, tick: int, is_fresh: bool) -> void:
	# 1. Physics/Movement (Inherited logic from BaseEntity -> LogicComponent)
	super._rollback_tick(delta, tick, is_fresh)
	
	# 2. Skill execution logic (Server only)
	if not is_fresh or not multiplayer.is_server(): return
	
	# Skill execution logic
	skill_timer += delta
	if skill_timer >= skill_interval:
		_execute_skill()
		skill_timer = 0.0

func _execute_skill() -> void:
	match pet_type:
		"ATTACK": _skill_attack()
		"TANK": _skill_tank()
		"HEAL": _skill_heal()

func _skill_attack() -> void:
	var ai = get_node_or_null("AIComponent")
	if ai and ai.target:
		# Trigger visual via Combat Component
		var combat = get_node_or_null("CombatComponent")
		if combat:
			combat.sync_attack_count += 1
			combat.attack_started.emit()

		var target = ai.target
		var crit_chance = 0.2 if power_level >= LVL_TIER_3 else 0.0
		var is_crit = randf() < crit_chance
		var skill_damage = (BASE_DMG + (power_level * 2)) * (2.0 if is_crit else 1.0)

		if power_level >= LVL_TIER_2 and randf() < 0.4:
			_apply_aoe_damage(target.global_position, 4.0, int(skill_damage))
		else:
			_apply_damage_to(target, int(skill_damage))

func _skill_tank() -> void:
	var combat = get_node_or_null("CombatComponent")
	if combat:
		combat.sync_attack_count += 1
		combat.attack_started.emit()

	if power_level >= LVL_TIER_3:
		_apply_aoe_stun(global_position, 5.0, 1.5)
	elif power_level >= LVL_TIER_2:
		var ai = get_node_or_null("AIComponent")
		if ai and ai.target:
			_apply_stun_to(ai.target, 1.5)
	
	_apply_aoe_taunt(global_position, 8.0)

func _skill_heal() -> void:
	var combat = get_node_or_null("CombatComponent")
	if combat:
		combat.sync_attack_count += 1
		combat.attack_started.emit()

	var heal_amount = 5 + (power_level * 1)
	var crit_chance = 0.2 if power_level >= LVL_TIER_3 else 0.0
	
	var players_node = get_tree().root.find_child("Players", true, false)
	var owner_node = players_node.get_node_or_null(str(owner_id)) if players_node else null
	
	if owner_node:
		var is_crit = randf() < crit_chance
		var final_heal = heal_amount * (2.0 if is_crit else 1.0)
		
		if power_level >= LVL_TIER_2 and randf() < 0.4:
			_apply_aoe_heal(owner_node.global_position, 6.0, int(final_heal))
		else:
			_apply_heal_to(owner_node, int(final_heal))

# --- Helper Methods for Skills ---

func _apply_damage_to(target: Node, amount: int) -> void:
	var hurtbox = target.get_node_or_null("HurtboxComponent")
	if hurtbox and hurtbox.has_method("receive_hit_data"):
		hurtbox.receive_hit_data(amount, self)

func _apply_aoe_damage(pos: Vector3, radius: float, amount: int) -> void:
	var players_node = get_tree().root.find_child("Players", true, false)
	if not players_node: return
	for child in players_node.get_children():
		if child.is_in_group(&"mobs") and child.global_position.distance_to(pos) <= radius:
			_apply_damage_to(child, amount)

func _apply_heal_to(target: Node, amount: int) -> void:
	var health = target.get_node_or_null("HealthComponent")
	if health and health.has_method("heal"):
		health.heal(amount)

func _apply_aoe_heal(pos: Vector3, radius: float, amount: int) -> void:
	var players_node = get_tree().root.find_child("Players", true, false)
	if not players_node: return
	for child in players_node.get_children():
		var is_friend = child.is_in_group(&"players") or child.is_in_group(&"pets")
		if is_friend and child.global_position.distance_to(pos) <= radius:
			_apply_heal_to(child, amount)

func _apply_stun_to(target: Node, duration: float) -> void:
	var state = target.get_node_or_null("ServerState")
	if state:
		state.is_stunned = true
		state.stun_remaining_time = duration

func _apply_aoe_stun(pos: Vector3, radius: float, duration: float) -> void:
	var players_node = get_tree().root.find_child("Players", true, false)
	if not players_node: return
	for child in players_node.get_children():
		if child.global_position.distance_to(pos) <= radius:
			var is_friendly = child.name == str(owner_id) or (child.get("owner_id") == owner_id)
			if not is_friendly:
				_apply_stun_to(child, duration)

func _apply_aoe_taunt(pos: Vector3, radius: float) -> void:
	var players_node = get_tree().root.find_child("Players", true, false)
	if not players_node: return
	for child in players_node.get_children():
		if child.global_position.distance_to(pos) <= radius:
			var ai = child.get_node_or_null("AIComponent")
			if ai and child != self:
				ai.target = self
				ai.state = 1 # State.CHASE
