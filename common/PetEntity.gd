# res://common/PetEntity.gd
extends CharacterBody3D

## A summoned pet that follows its owner and attacks enemies.
## Scales with power_level (souls invested).

@export var owner_id: int = 1
@export var pet_type: String = "ATTACK"
@export var power_level: int = 0

@onready var server_state: Node = $ServerState
@onready var health_comp: Node = $HealthComponent

var character_actor: CharacterActor
# Static cache to avoid repeated load calls
static var _actor_scene_cache: Dictionary = {}

# Skill Timers
var skill_timer: float = 0.0
var skill_interval: float = 4.0 # Base interval

func _ready() -> void:
	# Assign groups for AI
	add_to_group(&"pets")
	
	_load_character_actor()
	_setup_visuals()
	
	if not multiplayer.is_server():
		return
		
	# Scale stats based on power level
	_apply_power_scaling()
	print("[Pet] %s summoned for %d | Power: %d" % [pet_type, owner_id, power_level])

func _load_character_actor() -> void:
	var actor_path = "res://scenes/characters/PetDmg.tscn"
	match pet_type:
		"TANK": actor_path = "res://scenes/characters/PetTank.tscn"
		"HEAL": actor_path = "res://scenes/characters/PetHeal.tscn"
	
	var scene: PackedScene
	if _actor_scene_cache.has(actor_path):
		scene = _actor_scene_cache[actor_path]
	else:
		scene = load(actor_path) as PackedScene
		_actor_scene_cache[actor_path] = scene
	
	if scene:
		character_actor = scene.instantiate() as CharacterActor
		
		# Headless check
		if GameManager._is_headless_environment():
			_strip_visual_nodes(character_actor)
		
		add_child(character_actor)
		# Correct 180 degree rotation for models
		character_actor.rotation.y = PI
		character_actor.set_multiplayer_authority(1)

func _setup_visuals() -> void:
	if GameManager._is_headless_environment(): return
	if has_node("VisualComponent"):
		$VisualComponent.entity = self
		$VisualComponent.setup_with_actor(character_actor)
		$VisualComponent.update_name(pet_type)

func _strip_visual_nodes(node: Node) -> void:
	if not node: return
	var to_remove = []
	for child in node.get_children():
		if child is MeshInstance3D or child is Sprite3D or child is Decal or child is GPUParticles3D or child is CPUParticles3D:
			to_remove.append(child)
		else:
			_strip_visual_nodes(child)
	for child in to_remove:
		child.free()

func _apply_power_scaling() -> void:
	var multiplier = 1.0 + (power_level * 0.1)
	
	if health_comp:
		var base_hp = 100
		if pet_type == "TANK": base_hp = 250
		elif pet_type == "HEAL": base_hp = 80
		
		health_comp.max_health = int(base_hp * multiplier)
		health_comp.reset_health()
	
	# Visual scaling
	scale = Vector3.ONE * (1.0 + (power_level * 0.02))

func _rollback_tick(delta: float, _tick: int, is_fresh: bool) -> void:
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
