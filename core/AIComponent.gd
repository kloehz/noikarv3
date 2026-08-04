# res://core/AIComponent.gd
class_name AIComponent
extends Node

## AI Brain that simulates inputs for LogicComponent.
## Only runs on the Server.

enum State { IDLE, PATROL, CHASE, ATTACK, FOLLOW_OWNER }

@export var state: State = State.IDLE
@export var detection_range: float = 15.0
@export var attack_range: float = 3.0
@export var follow_distance: float = 4.0

## Patrol behavior tuning. Mobs spend their IDLE window waiting, then
## transition to PATROL and wander between random waypoints inside
## patrol_radius of the anchor set via set_patrol_center (called by
## MatchManager at spawn). The anchor stays even if the mob is knocked
## away, so the patrol area is bounded by spawn location rather than the
## mob's current position.
@export var patrol_radius: float = 8.0
## Seconds to pause at each patrol waypoint before picking the next one.
@export var patrol_wait_time: float = 2.0
## Per-mob variation around patrol_wait_time. Stops a wave from pausing in sync.
@export var patrol_wait_time_variation: float = 1.0
## Seconds the mob must stay IDLE (no target in detection_range) before
## PATROL kicks in. Keeps freshly spawned mobs from drifting apart before
## players have a chance to walk into range.
@export var patrol_start_delay: float = 1.5
## Per-mob variation around patrol_start_delay. Keeps a fresh wave from
## beginning its first patrol step at the same instant.
@export var patrol_start_delay_variation: float = 0.75
## Fraction of max_speed used while PATROLLING (1.0 = full chase speed).
## Kept under 1.0 so the wander looks lazy compared to the focused
## sprint when a target enters detection_range.
@export var patrol_speed_factor: float = 0.4

const MOB_AVOIDANCE_RADIUS: float = 2.4
const MOB_AVOIDANCE_STRENGTH: float = 1.2

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
var _faction_cached: bool = false

# Patrol state
var _patrol_center: Vector3 = Vector3.ZERO
var _patrol_target: Vector3 = Vector3.ZERO
var _patrol_wait_timer: float = 0.0
var _idle_timer: float = 0.0
var _patrol_start_delay: float = -1.0
var _patrol_wait_duration: float = 0.0

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
	
	# NOTE: Faction cache is NOT set here — groups may not be assigned yet.
	# It's lazily evaluated on tick() or forced via refresh_faction().
	
	print("[AI] Brain started for %s" % entity.name)
	# Disable normal process, LogicComponent will call tick()
	set_process(false)

## Force refresh the faction cache. Called by MatchManager after setup_pet().
func refresh_faction() -> void:
	if not entity: return
	_is_mob = entity.is_in_group(&"mobs")
	_is_pet = entity.is_in_group(&"pets")
	_faction_cached = true
	if _is_mob and _patrol_start_delay < 0.0:
		_randomize_patrol_timing()
	print("[AI] Faction refreshed for %s (Pet: %s, Mob: %s)" % [entity.name, _is_pet, _is_mob])

## Anchor for PATROL state. MatchManager calls this at spawn so each mob
## wanders inside a bounded area around its spawn point instead of
## drifting toward the world origin. Idempotent.
func set_patrol_center(center: Vector3) -> void:
	_patrol_center = center
	if _patrol_target == Vector3.ZERO:
		_patrol_target = center

func tick(delta: float) -> void:
	if not entity or entity.get("sync_is_dead"):
		if logic: _stop_inputs()
		return

	# Lazy faction cache — ensures groups are assigned before we check
	if not _faction_cached:
		refresh_faction()

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
			_logic_idle(delta)
		State.PATROL:
			_logic_patrol(delta)
		State.CHASE:
			_logic_chase()
		State.ATTACK:
			_logic_attack()
		State.FOLLOW_OWNER:
			_logic_follow()

func _logic_idle(delta: float) -> void:
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
		return

	# After sitting idle long enough, transition to PATROL so the mob
	# spreads out instead of standing on its spawn tile.
	_idle_timer += delta
	if _idle_timer >= _patrol_start_delay:
		state = State.PATROL
		_patrol_target = _pick_patrol_point()
		_patrol_wait_timer = 0.0
		_roll_patrol_wait_duration()
		_idle_timer = 0.0

func _logic_patrol(delta: float) -> void:
	if _target_search_timer <= 0:
		_find_nearest_target()
		_target_search_timer = _target_search_interval

	if target:
		state = State.CHASE
		_patrol_wait_timer = 0.0
		return

	var dist = entity.global_position.distance_to(_patrol_target)
	if dist < 1.0:
		_stop_inputs()
		_patrol_wait_timer += delta
		if _patrol_wait_timer >= _patrol_wait_duration:
			_patrol_target = _pick_patrol_point()
			_patrol_wait_timer = 0.0
			_roll_patrol_wait_duration()
	else:
		_move_towards(_patrol_target, patrol_speed_factor)
		_patrol_wait_timer = 0.0

## Picks a waypoint uniformly inside patrol_radius. Using sqrt(randf) for
## the radial distance gives uniform area distribution; raw randf would
## cluster points near the center.
func _pick_patrol_point() -> Vector3:
	var angle: float = randf() * TAU
	var distance: float = sqrt(randf()) * patrol_radius
	return _patrol_center + Vector3(cos(angle) * distance, 0, sin(angle) * distance)

func _randomize_patrol_timing() -> void:
	_patrol_start_delay = maxf(0.2, patrol_start_delay + randf_range(
		-patrol_start_delay_variation, patrol_start_delay_variation
	))
	_roll_patrol_wait_duration()

func _roll_patrol_wait_duration() -> void:
	_patrol_wait_duration = maxf(0.2, patrol_wait_time + randf_range(
		-patrol_wait_time_variation, patrol_wait_time_variation
	))

func _logic_chase() -> void:
	_refresh_threat_target()
	if not is_instance_valid(target) or target.get("sync_is_dead"):
		target = null
		# Pets go back to following owner, mobs to idle
		state = State.FOLLOW_OWNER if _is_pet and is_instance_valid(owner_node) else State.IDLE
		return

	var dist = entity.global_position.distance_to(target.global_position)

	if dist <= attack_range:
		state = State.ATTACK
		return

	# A target stays valid as long as it has threat on the board, even
	# outside detection_range. Without this, a long-range attacker
	# would force the mob to switch off the target the moment the mob
	# stepped back, breaking the aggro lock the threat system just
	# set up. The mob keeps chasing; once threat decays the next
	# _find_nearest_target will pick a closer candidate (or null).
	# Threat lives on THIS mob's own table keyed by the target's name.
	var target_threat: float = _threat_of_potential_on_self(target)
	if dist > detection_range and target_threat <= 0.0:
		target = null
		state = State.FOLLOW_OWNER if _is_pet and is_instance_valid(owner_node) else State.IDLE
		return

	# Move towards target
	_move_towards(target.global_position)

func _logic_attack() -> void:
	_refresh_threat_target()
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

## Re-evaluate active combat targets too. Restricting this to IDLE/PATROL
## meant a mob kept its first victim forever, even when a pet earned more
## threat by continuing to damage it.
func _refresh_threat_target() -> void:
	if _target_search_timer > 0:
		return
	_find_nearest_target()
	_target_search_timer = _target_search_interval

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

## Immediately switches a pet from following to chasing the mob that landed a
## real hit. HurtboxComponent has already recorded the threat on this pet, so
## later target refreshes keep this attacker even outside sight range.
func engage_attacker(attacker: Node) -> void:
	if not _faction_cached:
		refresh_faction()
	if not _is_pet or attacker == null or not attacker.is_in_group(&"mobs"):
		return
	if attacker.get("sync_is_dead"):
		return
	target = attacker as Node3D
	if target:
		state = State.CHASE
		_target_search_timer = 0.0

func _move_towards(pos: Vector3, speed_factor: float = 1.0) -> void:
	var dir := (pos - entity.global_position).normalized()
	dir = _steer_around_nearby_allies(dir)

	# Point the character at the target
	var target_yaw = atan2(-dir.x, -dir.z)

	# Force look_yaw to the target instantly (faster rotation)
	logic.look_yaw = lerp_angle(logic.look_yaw, target_yaw, 0.4)

	# MOVE FORWARD relative to the rotation
	# Vector2(0, -1) is always "Forward" in our LogicComponent
	# speed_factor scales the input magnitude so PATROL can wander lazily
	# (speed_factor 0.4 = 40% of chase speed) while CHASE keeps the full
	# Vector2(0, -1) sprint.
	logic.input_axis = Vector2(0, -1) * clampf(speed_factor, 0.0, 1.0)

## Mobs and pets retain physical collisions, so their steering must account for
## nearby allies. A blocked unit gets a stable side preference and flanks the
## frontline instead of continuously walking into it.
func _steer_around_nearby_allies(direction: Vector3) -> Vector3:
	if direction == Vector3.ZERO:
		return direction
	var ally_group: StringName
	if _is_mob:
		ally_group = &"mobs"
	elif _is_pet:
		ally_group = &"pets"
	else:
		return direction

	var separation := Vector3.ZERO
	var blocker_weight := 0.0
	for other in get_tree().get_nodes_in_group(ally_group):
		if other == entity or not is_instance_valid(other) or other.get("sync_is_dead"):
			continue
		var other_entity := other as Node3D
		if other_entity == null:
			continue
		var offset: Vector3 = other_entity.global_position - entity.global_position
		offset.y = 0.0
		var distance: float = offset.length()
		if distance <= 0.001 or distance >= MOB_AVOIDANCE_RADIUS:
			continue
		var proximity: float = 1.0 - distance / MOB_AVOIDANCE_RADIUS
		var other_direction: Vector3 = offset / distance
		separation -= other_direction * proximity
		if other_direction.dot(direction) > 0.4:
			blocker_weight += proximity

	if blocker_weight > 0.0:
		var lateral := Vector3(-direction.z, 0.0, direction.x)
		if (entity.name.hash() & 1) == 0:
			lateral = -lateral
		separation += lateral * blocker_weight

	return (direction + separation * MOB_AVOIDANCE_STRENGTH).normalized()

func _look_at_target(pos: Vector3) -> void:
	var dir = (pos - entity.global_position).normalized()
	var target_yaw = atan2(-dir.x, -dir.z)
	logic.look_yaw = lerp_angle(logic.look_yaw, target_yaw, 0.5)

func _stop_inputs() -> void:
	if not logic: return
	logic.input_axis = Vector2.ZERO
	logic.is_shooting = false

func _find_nearest_target() -> void:
	## Aggro / threat selection. Mobs acquire any hostile target within
	## detection_range. Threat sources always outrank proximity targets
	## and bypass detection_range, so a long-range attacker (e.g. a 50m
	## projectile) cannot snipe a short-range mob for free.
	##
	## Tank pets naturally pull aggro because their damage writes 1.75x
	## threat (see HurtboxComponent._threat_multiplier_for).
	var best_score: float = -INF
	var new_target = null

	# Determine which groups to search based on MY faction
	var hostile_groups: Array[StringName] = []
	var my_owner_id = entity.get("owner_id") if entity.has_method("get") else 0

	if _is_pet:
		hostile_groups = [&"mobs"]
	elif _is_mob:
		hostile_groups = [&"players", &"pets"]
	else:
		# Unknown faction, can't find target
		target = new_target
		return

	# Search ALL entities in hostile groups (not just Players container)
	for group_name in hostile_groups:
		for potential in get_tree().get_nodes_in_group(group_name):
			if potential == entity: continue
			if not is_instance_valid(potential): continue
			if potential.get("sync_is_dead"): continue

			# === ALLY EXCLUSION LOGIC ===
			# Pets should never target their owner or other pets
			if _is_pet:
				if potential.name == str(my_owner_id): continue
				if potential.is_in_group(&"pets"): continue

			# Mobs should never target other mobs
			if _is_mob and potential.is_in_group(&"mobs"):
				continue

			var d = entity.global_position.distance_to(potential.global_position)
			# Threat is per-mob: this entity's own sync_threat_table maps
			# attacker name -> threat. Only the mob that actually took
			# damage has an entry for a given attacker; bystander mobs
			# see 0 threat and stay passive.
			var threat: float = _threat_of_potential_on_self(potential)

			var score: float
			if _is_mob:
				if threat > 0.0:
					# A damaged mob keeps its aggro target even if another hostile
					# walks closer. Distance only resolves equal-threat ties.
					score = 1000000.0 + threat - d * 0.001
				elif d <= detection_range:
					score = -d
				else:
					continue
			else:
				# Pets own threat only when a mob damages them. That reactive
				# threat keeps their counterattack target valid beyond sight range;
				# otherwise they acquire nearby mobs by sight as before.
				if threat > 0.0:
					score = 1000000.0 + threat - d * 0.001
				elif d <= detection_range:
					score = -d
				else:
					continue
			if score > best_score:
				best_score = score
				new_target = potential

	target = new_target

## Reads the per-mob threat table on this AI's own entity for the given
## potential attacker. Returns 0 when either side has no ServerState.
## Decoupled from the older per-attacker design so the per-mob split
## stays explicit at the call site.
func _threat_of_potential_on_self(potential: Node) -> float:
	if potential == null:
		return 0.0
	if not entity.has_node("ServerState"):
		return 0.0
	var table: Dictionary = entity.get_node("ServerState").sync_threat_table
	if table.is_empty():
		return 0.0
	return float(int(table.get(String(potential.name), 0)))
