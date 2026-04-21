# res://common/PetEntity.gd
extends BaseEntity

## A summoned pet that follows its owner and attacks enemies.
## Scales with power_level (souls invested).
## Inherits from BaseEntity to reuse component handling logic.

@export var owner_id: int = 1
@export var pet_type: String = "ATTACK"
@export var power_level: int = 0

# Skill Timers
var skill_timer: float = 0.0
var skill_interval: float = 4.0 # Base interval

var _has_setup: bool = false

func _ready() -> void:
	# BaseEntity handles authority and initial loading
	# We override _ready to add pet-specific signals
	super._ready()
	
	if server_state:
		# On clients, wait for synchronized data to trigger setup
		if not multiplayer.is_server():
			server_state.pet_data_received.connect(func(t, l): setup_pet(owner_id, t, l))
			# Initial check in case it's already there
			if not server_state.pet_type_sync.is_empty():
				setup_pet(owner_id, server_state.pet_type_sync, server_state.power_level_sync)
	
	if multiplayer.is_server():
		# On server, we'll wait for setup_pet call from MatchManager
		pass

func setup_pet(p_owner_id: int, p_type: String, p_souls: int) -> void:
	if _has_setup and pet_type == p_type: return
	
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
	_load_character_actor()
	
	# Re-link VisualComponent
	if has_node("VisualComponent"):
		$VisualComponent.setup_with_actor(character_actor)
		$VisualComponent.update_name(pet_type)
	
	if multiplayer.is_server() and server_state:
		server_state.pet_type_sync = p_type
		server_state.power_level_sync = p_souls
		_apply_power_scaling()
		print("[Pet] %s setup for %d | Power: %d" % [pet_type, owner_id, power_level])

func _apply_power_scaling() -> void:
	var multiplier = 1.0 + (power_level * 0.1)
	
	if server_state:
		var base_hp = 100
		if pet_type == "TANK": base_hp = 250
		elif pet_type == "HEAL": base_hp = 80
		
		apply_stats(int(base_hp * multiplier))
	
	# Visual scaling
	scale = Vector3.ONE * (1.0 + (power_level * 0.02))

func _rollback_tick(delta: float, tick: int, is_fresh: bool) -> void:
	# 1. Physics/Movement (Inherited logic from BaseEntity -> LogicComponent)
	super._rollback_tick(delta, tick, is_fresh)
	
	# 2. Skill execution logic (Server only)
	if not is_fresh or not multiplayer.is_server(): return
	
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
	# Damage scaling
	var damage = 10 + (power_level * 2)
	var crit_chance = 0.0
	var area_chance = 0.0
	
	if power_level >= 11:
		area_chance = clamp((power_level - 10) * 0.05, 0.1, 0.6) # Up to 60% area chance
	if power_level >= 26:
		crit_chance = 0.2 # 20% Crit chance
		
	# Find current target from AI
	var ai = get_node_or_null("AIComponent")
	if ai and ai.target:
		var target = ai.target
		var is_crit = randf() < crit_chance
		var final_damage = damage * (2.0 if is_crit else 1.0)
		
		if randf() < area_chance:
			# Area Attack
			_apply_aoe_damage(target.global_position, 4.0, final_damage)
			print("[Pet Attack] AREA Hit! Crit: ", is_crit)
		else:
			# Single Target
			_apply_damage_to(target, final_damage)
			print("[Pet Attack] Single Hit! Crit: ", is_crit)

func _skill_tank() -> void:
	# Taunt/Stun scaling
	if power_level >= 26:
		# AOE STUN
		_apply_aoe_stun(global_position, 5.0, 1.5)
		print("[Pet Tank] AOE STUN!")
	elif power_level >= 11:
		# Frontal Stun (Simplified as nearest for now)
		var ai = get_node_or_null("AIComponent")
		if ai and ai.target:
			_apply_stun_to(ai.target, 1.5)
			print("[Pet Tank] Single STUN!")
	
	# Basic AOE Taunt (Always for tank)
	_apply_aoe_taunt(global_position, 8.0)

func _skill_heal() -> void:
	# Heal scaling
	var heal_amount = 5 + (power_level * 1)
	var crit_chance = 0.0
	var area_chance = 0.0
	
	if power_level >= 11:
		area_chance = clamp((power_level - 10) * 0.05, 0.1, 0.5)
	if power_level >= 26:
		crit_chance = 0.2
		
	# Find owner
	var players_node = get_tree().root.find_child("Players", true, false)
	var owner_node = players_node.get_node_or_null(str(owner_id)) if players_node else null
	
	if owner_node:
		var is_crit = randf() < crit_chance
		var final_heal = heal_amount * (2.0 if is_crit else 1.0)
		
		if randf() < area_chance:
			_apply_aoe_heal(owner_node.global_position, 6.0, final_heal)
			print("[Pet Heal] AREA Heal! Crit: ", is_crit)
		else:
			_apply_heal_to(owner_node, final_heal)
			print("[Pet Heal] Single Heal! Crit: ", is_crit)

# --- Helper Methods for Skills ---

func _apply_damage_to(target: Node, amount: int) -> void:
	var hurtbox = target.get_node_or_null("HurtboxComponent")
	if hurtbox and hurtbox.has_method("receive_hit_data"):
		hurtbox.receive_hit_data(amount, self)

func _apply_aoe_damage(pos: Vector3, radius: float, amount: int) -> void:
	var players_node = get_tree().root.find_child("Players", true, false)
	if not players_node: return
	for child in players_node.get_children():
		if child.global_position.distance_to(pos) <= radius:
			_apply_damage_to(child, amount)

func _apply_heal_to(target: Node, amount: int) -> void:
	var health = target.get_node_or_null("HealthComponent")
	if health and health.has_method("heal"):
		health.heal(amount)

func _apply_aoe_heal(pos: Vector3, radius: float, amount: int) -> void:
	var players_node = get_tree().root.find_child("Players", true, false)
	if not players_node: return
	for child in players_node.get_children():
		# Heal only friends (players and pets)
		var is_friend = child.name.is_valid_int() or child.name.begins_with("PET")
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
			# Don't stun owner or other pets of owner
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
				ai.state = 1 # Force CHASE
