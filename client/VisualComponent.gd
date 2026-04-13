@tool
# res://client/VisualComponent.gd
class_name VisualComponent
extends Node

## Client-side visual component for mesh representation and VFX.

## Entity this component provides visuals for.
@export var entity: CharacterBody3D

## Cached reference to the mesh node (first child with MeshInstance3D).
var _mesh: MeshInstance3D

## Cached reference to the AnimationPlayer if present.
var _animation_player: AnimationPlayer

func _ready() -> void:
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
		_mesh = entity.get_node_or_null("MeshInstance3D") as MeshInstance3D
		_animation_player = entity.get_node_or_null("AnimationPlayer") as AnimationPlayer

## Connect to EventBus signals for game event-driven visuals.
func _connect_signals() -> void:
	EventBus.entity_spawned.connect(_on_entity_spawned)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.entity_damaged.connect(_on_entity_damaged)

## Called when entity spawns - play spawn VFX/effects.
func _on_entity_spawned(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		play_spawn_effect()

## Update visual name (e.g., label above player).
func update_name(new_name: String) -> void:
	print("[VisualComponent] Name updated to: ", new_name)
	var name_label = get_parent().get_node_or_null("NameLabel")
	if name_label:
		name_label.text = new_name

## Play attack visual effect (melee hit).
func play_shoot_effect() -> void:
	# Basic visual feedback
	print("[Combat] SWING! (Area Attack)")
	
	if _mesh:
		# Define the fixed base position (feet at 0, center at 1)
		var base_pos = Vector3(0, 1, 0)
		
		# Create a new tween and kill the previous one if it exists to avoid 'stretching'
		var tween = get_tree().create_tween()
		
		# Move forward (punch)
		tween.tween_property(_mesh, "position", base_pos + Vector3(0, 0, -0.6), 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.parallel().tween_property(_mesh, "scale", Vector3(1.1, 1.1, 1.1), 0.05)
		
		# Return to original
		tween.tween_property(_mesh, "position", base_pos, 0.1).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tween.parallel().tween_property(_mesh, "scale", Vector3(1.0, 1.0, 1.0), 0.1)


## Called when entity dies - play death VFX/effects.
func _on_entity_died(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		play_death_effect()

## Called when entity takes damage - play hit flash/effects.
func _on_entity_damaged(p_entity: Node3D, _amount: int, _source: Node) -> void:
	if p_entity == self.entity:
		_play_hit_effect()

## Play death visual effect.
func play_death_effect() -> void:
	print("[VisualComponent] DIED!")
	if _mesh:
		_mesh.visible = false
	
	# Hide UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_label = get_parent().get_node_or_null("HealthLabel")
	if name_label: name_label.visible = false
	if health_label: health_label.visible = false
	
	# VFX signal
	EventBus.visual_effect_requested.emit(entity, "death")

## Play spawn/respawn visual effect.
func play_spawn_effect() -> void:
	print("[VisualComponent] SPAWNED/RESPAWNED!")
	if _mesh:
		_mesh.visible = true
		_mesh.scale = Vector3.ZERO
		var tween = get_tree().create_tween()
		tween.tween_property(_mesh, "scale", Vector3.ONE, 0.3).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	
	# Show UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_label = get_parent().get_node_or_null("HealthLabel")
	if name_label: name_label.visible = true
	if health_label: health_label.visible = true
	
	# VFX signal
	EventBus.visual_effect_requested.emit(entity, "spawn")

## Play hit/damage visual effect.
func _play_hit_effect() -> void:
	# Placeholder: Emit signal for VFX system to hook into
	EventBus.visual_effect_requested.emit(entity, "hit")
	
	# Basic red flash effect
	if _mesh:
		var tween = get_tree().create_tween()
		tween.tween_property(_mesh, "modulate", Color.RED, 0.1)
		tween.tween_property(_mesh, "modulate", Color.WHITE, 0.1)

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
signal visual_effect_requested(entity: Node3D, effect_name: String)
