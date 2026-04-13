@tool
# res://client/VisualComponent.gd
class_name VisualComponent
extends Node

## Client-side visual component for mesh representation and interpolation.
## 
## CLIENT INTERPOLATION MATHEMATICS:
## ============================================================
## Instead of immediately snapping to server positions (which causes
## jittery movement), we interpolate between received positions using
## a simple lerp (linear interpolation) approach.
##
## The movement follows these steps:
##
## 1. RECEIVE SNAPSHOT: When MultiplayerSynchronizer updates position,
##    we don't set the mesh directly - we store the target position.
##    target_position = entity.global_position
##
## 2. LERP TOWARD TARGET: Each frame, we move a fraction of the distance
##    toward the target: current = current.lerp(target, lerp_factor * delta)
##    Where lerp_factor is typically 10-15 for responsive but smooth motion.
##
## 3. ADVANTAGES OF LERP:
##    - Smooths out network jitter without adding significant latency
##    - Works well with typical 10-20 tick server updates
##    - Easy to tune via lerp_factor parameter
##    - No need for buffer/queue like full interpolation
##
## ROTATION INTERPOLATION:
## Similar approach for rotation using slerp (spherical lerp) or simple lerp
## on individual Euler angles for Y-axis (yaw) rotation.
##
## ANIMATION PLAYBACK:
## Animation state is driven by the server-authoritative LogicComponent via
## EventBus signals. The VisualComponent listens and triggers appropriate
## animations on the AnimationPlayer node.
##
## VFX/SFX HOOKS:
## When the LogicComponent or HealthComponent emits events (via EventBus),
## the VisualComponent responds by playing visual effects (particles, flashes)
## and sound effects. This keeps visuals decoupled from game logic.
## ============================================================

## Entity this component provides visuals for (set via Editor or spawner).
## When used as a tool, this will be resolved from the parent node.
@export var entity: CharacterBody3D

## Cached reference to the mesh node (first child with MeshInstance3D).
var _mesh: MeshInstance3D

## Cached reference to the AnimationPlayer if present.
var _animation_player: AnimationPlayer

func _ready() -> void:
	# In tool mode, resolve entity from parent for editor preview
	if Engine.is_editor_hint():
		_setup_from_parent()
		return
	
	_setup_references()
	_connect_signals()

## Set up from parent node (for tool mode and runtime).
func _setup_from_parent() -> void:
	if not entity:
		entity = get_parent() as CharacterBody3D

## Cache node references for efficient access.
func _setup_references() -> void:
	if not entity:
		_setup_from_parent()
	
	if entity:
		# Find mesh node - typically first MeshInstance3D child
		_mesh = entity.get_node_or_null("MeshInstance3D") as MeshInstance3D
		
		# Find AnimationPlayer if present
		_animation_player = entity.get_node_or_null("AnimationPlayer") as AnimationPlayer

## Connect to EventBus signals for game event-driven visuals.
func _connect_signals() -> void:
	# EventBus is an autoload singleton - direct connections are safe
	# because the autoload always exists when the game runs
	EventBus.entity_spawned.connect(_on_entity_spawned)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.entity_damaged.connect(_on_entity_damaged)

## Called when entity spawns - play spawn VFX/effects.
func _on_entity_spawned(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		_play_spawn_effect()

## Update visual name (e.g., label above player).
func update_name(new_name: String) -> void:
	print("[VisualComponent] Name updated to: ", new_name)

## Play attack visual effect (melee hit).
func play_shoot_effect() -> void:
	# Basic visual feedback: a quick flash or print
	print("[Combat] SWING! (Area Attack)")
	
	if _mesh:
		# Quick punch forward animation using Tweens
		var tween = get_tree().create_tween()
		var original_pos = _mesh.position
		
		# Move forward and grow slightly
		tween.tween_property(_mesh, "position", original_pos + Vector3(0, 0, -0.5), 0.05)
		tween.parallel().tween_property(_mesh, "scale", Vector3(1.1, 1.1, 1.1), 0.05)
		
		# Return to original
		tween.tween_property(_mesh, "position", original_pos, 0.1)
		tween.parallel().tween_property(_mesh, "scale", Vector3(1.0, 1.0, 1.0), 0.1)


## Called when entity dies - play death VFX/effects.
func _on_entity_died(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		_play_death_effect()

## Called when entity takes damage - play hit flash/effects.
func _on_entity_damaged(p_entity: Node3D, _amount: int, _source: Node) -> void:
	if p_entity == self.entity:
		_play_hit_effect()

## Play spawn visual effect.
func _play_spawn_effect() -> void:
	EventBus.visual_effect_requested.emit(entity, "spawn")

## Play death visual effect.
func _play_death_effect() -> void:
	EventBus.visual_effect_requested.emit(entity, "death")

## Play hit/damage visual effect.
func _play_hit_effect() -> void:
	EventBus.visual_effect_requested.emit(entity, "hit")

## Play an animation by name if AnimationPlayer exists.
func play_animation(animation_name: String, force: bool = false) -> void:
	if _animation_player:
		if _animation_player.has_animation(animation_name):
			if force or not _animation_player.is_playing() or _animation_player.current_animation != animation_name:
				_animation_player.play(animation_name)
		else:
			push_warning("VisualComponent: Animation '%s' not found" % animation_name)

## Stop current animation.
func stop_animation() -> void:
	if _animation_player and _animation_player.is_playing():
		_animation_player.stop()

## Check if current context has server authority.
func _is_server_authority() -> bool:
	# In single-player (no multiplayer context), server has authority
	if multiplayer == null:
		return true
	return multiplayer.is_server()

# EventBus signal for VFX requests (extend as needed)
# This allows a separate VFX system to handle the actual effects
# while VisualComponent just requests them
signal visual_effect_requested(entity: Node3D, effect_name: String)
