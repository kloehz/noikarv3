# res://common/EnemyEntity.gd
class_name EnemyEntity
extends BaseEntity

## Server-authoritative enemy entity.
## Works exactly like PetEntity: a networking shell that loads
## different Actor scenes (MobAatrox.tscn, MobGoblin.tscn, etc.)
## to get different visuals, stats, and attack definitions.
##
## Usage:
##   var enemy = ENEMY_SCENE.instantiate()
##   enemy.name = "MOB_" + str(randi() % 10000)
##   players_container.add_child(enemy, true)
##   enemy.setup_enemy("AATROX", Vector3(0, 0, -5))

## Enemy variant identifier (maps to an actor scene).
@export var enemy_type: String = "AATROX"

## Difficulty scaling multiplier (future use for wave scaling).
@export var difficulty: float = 1.0
@export var spawn_grace_duration: float = 0.0

# --- Actor scene mapping ---
const ENEMY_ACTORS := {
	"AATROX": "res://scenes/characters/Aatrox.tscn",
	# Add new enemy types here:
	# "GOBLIN": "res://scenes/characters/MobGoblin.tscn",
	# "DRAGON": "res://scenes/characters/MobDragon.tscn",
}

var _has_setup: bool = false
var _spawn_grace_active: bool = false
var _saved_collision_layer: int = 0
var _saved_collision_mask: int = 0

func _ready() -> void:
	if spawn_grace_duration > 0.0:
		_begin_spawn_grace()
	super._ready()
	if _spawn_grace_active:
		_finish_spawn_grace.call_deferred()

func _begin_spawn_grace() -> void:
	_spawn_grace_active = true
	_saved_collision_layer = collision_layer
	_saved_collision_mask = collision_mask
	collision_layer = 0
	collision_mask = 0
	_set_hurtbox_enabled(false)
	_set_spawn_visibility(false)

func _finish_spawn_grace() -> void:
	await get_tree().create_timer(spawn_grace_duration).timeout
	if not is_instance_valid(self):
		return
	_spawn_grace_active = false
	collision_layer = _saved_collision_layer
	collision_mask = _saved_collision_mask
	_set_hurtbox_enabled(true)
	_set_spawn_visibility(true)
	if has_node("VisualComponent"):
		$VisualComponent.play_spawn_effect()

func _set_spawn_visibility(is_visible: bool) -> void:
	visible = is_visible

func _set_hurtbox_enabled(is_enabled: bool) -> void:
	var hurtbox = get_node_or_null("HurtboxComponent")
	if hurtbox:
		hurtbox.monitorable = is_enabled
		hurtbox.monitoring = is_enabled

## Configure this enemy with a type and position.
## Call on the SERVER after add_child().
func setup_enemy(p_type: String, p_position: Vector3 = Vector3.ZERO) -> void:
	if _has_setup and enemy_type == p_type: return
	
	enemy_type = p_type
	_has_setup = true
	
	# Resolve actor path
	var actor_path = ENEMY_ACTORS.get(p_type, ENEMY_ACTORS["AATROX"])
	character_actor_path = actor_path
	
	# Re-load model via BaseEntity logic
	if character_actor:
		character_actor.queue_free()
		character_actor = null
	
	_load_character_actor()
	
	# Position
	if p_position != Vector3.ZERO:
		global_position = p_position
	
	# Hide base placeholder mesh if it exists
	if has_node("MeshInstance3D"):
		get_node("MeshInstance3D").visible = false
	
	# Re-link VisualComponent
	if has_node("VisualComponent"):
		var vis = get_node("VisualComponent")
		vis.setup_with_actor(character_actor)
		vis.update_name(enemy_type)
		if not _spawn_grace_active:
			vis.play_spawn_effect()
	
	_set_spawn_visibility(not _spawn_grace_active)
	
	# Apply actor specs to AI (attack_range, detection_range)
	_apply_actor_specs_to_ai()
	
	# Configure AI state
	var ai = get_node_or_null("AIComponent")
	if ai:
		ai.refresh_faction()
		ai.state = 1  # State.CHASE
	
	# Ensure server authority
	set_multiplayer_authority(1)
	
	print("[Enemy] %s spawned at %s (type: %s)" % [name, global_position, enemy_type])

func _rollback_tick(delta: float, tick: int, is_fresh: bool) -> void:
	if _spawn_grace_active:
		var logic = get_node_or_null("LogicComponent")
		if logic:
			logic.input_axis = Vector2.ZERO
			logic.is_shooting = false
			logic.current_velocity = Vector3.ZERO
		return

	super._rollback_tick(delta, tick, is_fresh)

func _apply_actor_specs_to_ai() -> void:
	if not is_instance_valid(character_actor): return
	var ai = get_node_or_null("AIComponent")
	if ai:
		ai.attack_range = character_actor.suggested_attack_range
		ai.detection_range = character_actor.suggested_detection_range
		ai.follow_distance = character_actor.suggested_follow_distance
