# res://core/AIComponent.gd
class_name AIComponent
extends Node

## AI Brain that simulates inputs for LogicComponent.
## Only runs on the Server.

enum State { IDLE, CHASE, ATTACK, FOLLOW_OWNER }

@export var state: State = State.IDLE
@export var detection_range: float = 15.0
@export var attack_range: float = 3.0
@export var follow_distance: float = 4.0

var entity: BaseEntity
var logic: Node

var target: Node3D = null
var owner_node: Node3D = null # For pets
var _players_node: Node3D = null

# Performance Optimization: Throttling
var _target_search_timer: float = 0.0
var _target_search_interval: float = 0.2 # Search every 200ms
var _is_mob: bool = false
var _is_pet: bool = false

func _ready() -> void:
	# AI logic only runs on the server
	if not multiplayer.is_server():
		set_process(false)
		return
	
	entity = get_parent() as BaseEntity
	if not entity:
		set_process(false)
		return

	# Search for logic component
	logic = entity.get_node_or_null("LogicComponent")
	
	# Cache players node to avoid expensive root searches
	_players_node = get_tree().root.find_child("Players", true, false)
	
	# Cache faction to avoid string comparisons every tick
	_is_mob = entity.is_in_group(&"mobs")
	_is_pet = entity.is_in_group(&"pets")
	
	print("[AI] Brain started for %s (Pet: %s, Mob: %s)" % [entity.name, _is_pet, _is_mob])
	# Disable normal process, LogicComponent will call tick()
	set_process(false)

func tick(delta: float) -> void:
	if not entity or entity.get("sync_is_dead"):
		if logic: _stop_inputs()
		return
	
	if not logic:
		logic = entity.get_node_or_null("LogicComponent")
		if not logic: return
	
	# Ensure we have the players node
	if not is_instance_valid(_players_node):
		_players_node = get_tree().root.find_child("Players", true, false)
		if not _players_node: return

	# Update search timer
	_target_search_timer -= delta

	match state:
		State.IDLE:
			_logic_idle()
		State.CHASE:
			_logic_chase()
		State.ATTACK:
			_logic_attack()
		State.FOLLOW_OWNER:
			_logic_follow()

func _logic_idle() -> void:
	_stop_inputs()
	
	# If we are a pet with an owner, prefer following over idling
	if _is_pet and is_instance_valid(owner_node):
		state = State.FOLLOW_OWNER
		return
	
	# Only search for targets occasionally
	if _target_search_timer <= 0:
		_find_nearest_target()
		_target_search_timer = _target_search_interval
		
	if target:
		state = State.CHASE

func _logic_chase() -> void:
	if not is_instance_valid(target) or target.get("sync_is_dead"):
		target = null
		# Pets go back to following owner, mobs to idle
		state = State.FOLLOW_OWNER if _is_pet and is_instance_valid(owner_node) else State.IDLE
		return
		
	var dist = entity.global_position.distance_to(target.global_position)
	
	if dist <= attack_range:
		state = State.ATTACK
		return
		
	if dist > detection_range:
		target = null
		state = State.FOLLOW_OWNER if _is_pet and is_instance_valid(owner_node) else State.IDLE
		return
		
	# Move towards target
	_move_towards(target.global_position)

func _logic_attack() -> void:
	if not is_instance_valid(target) or target.get("sync_is_dead"):
		state = State.FOLLOW_OWNER if _is_pet and is_instance_valid(owner_node) else State.IDLE
		return
		
	var dist = entity.global_position.distance_to(target.global_position)
	if dist > attack_range:
		state = State.CHASE
		logic.is_shooting = false
		return
		
	# Look at target and shoot
	_look_at_target(target.global_position)
	logic.input_axis = Vector2.ZERO
	logic.is_shooting = true

func _logic_follow() -> void:
	if not is_instance_valid(owner_node):
		# Try to re-find owner if lost
		if entity.has_method("get"):
			var owner_id = entity.get("owner_id")
			if owner_id:
				if _players_node:
					owner_node = _players_node.get_node_or_null(str(owner_id))
		
		if not is_instance_valid(owner_node):
			state = State.IDLE
			return
		
	var dist = entity.global_position.distance_to(owner_node.global_position)
	
	# If we see an enemy while following, switch to CHASE (unless we are a HEALER)
	if _target_search_timer <= 0:
		var type = entity.get("pet_type") if entity.has_method("get") else ""
		if type != "HEAL":
			_find_nearest_target()
			if target:
				state = State.CHASE
				return
		_target_search_timer = _target_search_interval

	if dist > follow_distance:
		_move_towards(owner_node.global_position)
	else:
		_stop_inputs()
		# Smoothly face the same way as owner
		logic.look_yaw = lerp_angle(logic.look_yaw, owner_node.rotation.y, 0.1)

func _move_towards(pos: Vector3) -> void:
	var dir = (pos - entity.global_position).normalized()
	
	# Point the character at the target
	var target_yaw = atan2(-dir.x, -dir.z)
	
	# Force look_yaw to the target instantly (faster rotation)
	logic.look_yaw = lerp_angle(logic.look_yaw, target_yaw, 0.4)
	
	# MOVE FORWARD relative to the rotation
	# Vector2(0, -1) is always "Forward" in our LogicComponent
	logic.input_axis = Vector2(0, -1)

func _look_at_target(pos: Vector3) -> void:
	var dir = (pos - entity.global_position).normalized()
	var target_yaw = atan2(-dir.x, -dir.z)
	logic.look_yaw = lerp_angle(logic.look_yaw, target_yaw, 0.5)

func _stop_inputs() -> void:
	if not logic: return
	logic.input_axis = Vector2.ZERO
	logic.is_shooting = false

func _find_nearest_target() -> void:
	var best_dist = detection_range
	var new_target = null
	
	if not _players_node: return
	
	for potential in _players_node.get_children():
		if potential == entity or potential.get("sync_is_dead"): continue
		
		# FACTION CHECK via Groups (Optimized)
		var is_potential_mob = potential.is_in_group(&"mobs")
		
		# Pets target mobs, Mobs target humans/pets
		var am_i_hostile_to_it = false
		if _is_pet:
			am_i_hostile_to_it = is_potential_mob
		elif _is_mob:
			am_i_hostile_to_it = potential.is_in_group(&"players") or potential.is_in_group(&"pets")
		
		if not am_i_hostile_to_it:
			continue
		
		var d = entity.global_position.distance_to(potential.global_position)
		if d < best_dist:
			best_dist = d
			new_target = potential
			
	target = new_target
