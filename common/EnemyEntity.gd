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

# --- Actor scene mapping ---
const ENEMY_ACTORS := {
	"AATROX": "res://scenes/characters/Aatrox.tscn",
	# Add new enemy types here:
	# "GOBLIN": "res://scenes/characters/MobGoblin.tscn",
	# "DRAGON": "res://scenes/characters/MobDragon.tscn",
}

var _has_setup: bool = false

func _ready() -> void:
	super._ready()

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
		vis.play_spawn_effect()
	
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

func _apply_actor_specs_to_ai() -> void:
	if not is_instance_valid(character_actor): return
	var ai = get_node_or_null("AIComponent")
	if ai:
		ai.attack_range = character_actor.suggested_attack_range
		ai.detection_range = character_actor.suggested_detection_range
		ai.follow_distance = character_actor.suggested_follow_distance
