@tool
# res://client/VisualComponent.gd
class_name VisualComponent
extends Node

## Client-side visual component for mesh representation and VFX.
## Now works with CharacterActor for flexible character models.

## Entity this component provides visuals for.
@export var entity: CharacterBody3D

## Current active character actor (model + animations)
var _actor: CharacterActor
var _anim_lock_time: float = 0.0

func _ready() -> void:
	if Engine.is_editor_hint():
		_setup_from_parent()
		return
	
	_connect_signals()

## Set up from parent node (for tool mode and runtime).
func _setup_from_parent() -> void:
	if not entity:
		entity = get_parent() as CharacterBody3D

## Connect to EventBus signals for game event-driven visuals.
func _connect_signals() -> void:
	EventBus.entity_spawned.connect(_on_entity_spawned)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.entity_damaged.connect(_on_entity_damaged)

## Initialize with a specific character actor
func setup_with_actor(actor: CharacterActor) -> void:
	_actor = actor
	if _actor:
		print("[VisualComponent] Setup with actor: ", _actor.name)
		var mesh = entity.get_node_or_null("MeshInstance3D")
		if mesh: mesh.visible = false

## Called when entity spawns - play spawn VFX/effects.
func _on_entity_spawned(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		play_spawn_effect()

## Update visual name (e.g., label above player).
func update_name(new_name: String) -> void:
	var name_label = get_parent().get_node_or_null("NameLabel")
	if name_label:
		name_label.text = new_name

## Play attack visual effect (melee hit).
func play_shoot_effect() -> void:
	print("[VisualComponent] play_shoot_effect called for: ", entity.name)
	if _actor:
		_actor.play_animation("Attack") 
		_anim_lock_time = 0.5 # Wait 0.5s before allowing Idle/Run to override
	else:
		_play_fallback_punch()

func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	
	if _anim_lock_time > 0:
		_anim_lock_time -= delta
		return
		
	_update_movement_animations()

func _update_movement_animations() -> void:
	if not _actor: return
	
	# Priority: If we are playing an attack, don't override it with move/idle
	if _actor.is_playing("Attack"):
		return
	
	var logic = entity.get_node_or_null("LogicComponent")
	if logic:
		var velocity = logic.get("current_velocity") as Vector3
		if velocity and velocity.length() > 0.1:
			_actor.play_animation("Run")
		else:
			_actor.play_animation("Idle")

func _play_fallback_punch() -> void:
	var mesh = entity.get_node_or_null("MeshInstance3D")
	if mesh:
		var base_pos = Vector3(0, 1, 0)
		var tween = get_tree().create_tween()
		tween.tween_property(mesh, "position", base_pos + Vector3(0, 0, -0.6), 0.05)
		tween.tween_property(mesh, "position", base_pos, 0.1)

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
	if _actor:
		_actor.play_animation("Death")
	
	# Hide UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_label = get_parent().get_node_or_null("HealthLabel")
	if name_label: name_label.visible = false
	if health_label: health_label.visible = false
	
	EventBus.visual_effect_requested.emit(entity, "death")

## Play spawn/respawn visual effect.
func play_spawn_effect() -> void:
	if _actor:
		_actor.play_animation("Idle")
	
	# Show UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_label = get_parent().get_node_or_null("HealthLabel")
	if name_label: name_label.visible = true
	if health_label: health_label.visible = true
	
	EventBus.visual_effect_requested.emit(entity, "spawn")

## Play hit/damage visual effect.
func _play_hit_effect() -> void:
	EventBus.visual_effect_requested.emit(entity, "hit")
	# Potential flash on actor mesh here

## Play an animation by name.
func play_animation(animation_name: String, blend: float = 0.2) -> void:
	if _actor:
		_actor.play_animation(animation_name, blend)

## Stop current animation.
func stop_animation() -> void:
	if _actor and _actor.animation_player:
		_actor.animation_player.stop()
