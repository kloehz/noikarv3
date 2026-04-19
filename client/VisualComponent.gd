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
	
	print("[DEBUG] VisualComponent ready on %s" % (entity.name if entity else "Unknown"))
	_connect_signals()

## Set up from parent node (for tool mode and runtime).
func _setup_from_parent() -> void:
	if not entity:
		entity = get_parent() as CharacterBody3D
		if entity:
			print("[DEBUG] VisualComponent auto-assigned entity: %s" % entity.name)

## Connect to EventBus signals for game event-driven visuals.
func _connect_signals() -> void:
	if not entity:
		print("[ERROR] VisualComponent: Cannot connect signals, entity is null!")
		return
		
	print("[DEBUG] VisualComponent %s connecting signals" % entity.name)
	EventBus.entity_spawned.connect(_on_entity_spawned)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.entity_damaged.connect(_on_entity_damaged)
	
	var health = entity.get_node_or_null("HealthComponent")
	if health:
		print("[DEBUG] VisualComponent %s connected to HealthComponent" % entity.name)
		health.health_changed.connect(_on_health_changed)
		_on_health_changed(health.current_health, health.max_health)
	
	var combat = entity.get_node_or_null("CombatComponent")
	if combat:
		print("[DEBUG] VisualComponent %s connected to CombatComponent" % entity.name)
		combat.attack_started.connect(play_shoot_effect)

func _on_health_changed(current: int, maximum: int) -> void:
	# Update new Pro Health Bar (2D node inside SubViewport)
	var health_bar_2d = entity.get_node_or_null("HealthViewport/HealthBar2D")
	if health_bar_2d and health_bar_2d.has_method("update_health"):
		health_bar_2d.update_health(current, maximum)
	
	# Legacy Label support (now hidden in TSCN)
	var health_label = get_parent().get_node_or_null("HealthLabel") as Label3D
	if health_label:
		health_label.text = "%d/%d" % [current, maximum]

## Initialize with a specific character actor
func setup_with_actor(actor: CharacterActor) -> void:
	_actor = actor
	if _actor:
		print("[DEBUG] VisualComponent %s setup with actor: %s" % [entity.name if entity else "Entity", _actor.name])
		if entity:
			var mesh = entity.get_node_or_null("MeshInstance3D")
			if mesh: mesh.visible = false
	else:
		print("[WARNING] VisualComponent setup_with_actor called with null actor")

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
		# Force restart if already playing
		if _actor.animation_player:
			_actor.animation_player.stop()
		_actor.play_animation("Attack") 
		_anim_lock_time = 0.5 # Wait 0.5s before allowing Idle/Run to override
	else:
		_play_fallback_punch()

func _update_debug_pos(debug_mesh: MeshInstance3D) -> void:
	var combat = entity.get_node_or_null("CombatComponent")
	if not combat or not combat.shapecast: return
	
	# Match exactly what the server is checking
	debug_mesh.global_position = combat.shapecast.global_position

func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	
	# Handle Attack Debug visuals deterministically based on synchronized state
	_handle_attack_debug_visuals()
	
	if _anim_lock_time > 0:
		_anim_lock_time -= delta
		return
		
	_update_movement_animations()

func _handle_attack_debug_visuals() -> void:
	var debug_mesh = get_parent().get_node_or_null("AttackDebugMesh") as MeshInstance3D
	if not debug_mesh: return
	
	var combat = entity.get_node_or_null("CombatComponent")
	if not combat:
		debug_mesh.visible = false
		return
	
	# AttackState.ACTIVE is 2
	if combat.get("current_attack_state") == 2:
		debug_mesh.visible = true
		_update_debug_pos(debug_mesh)
	else:
		debug_mesh.visible = false

func _update_movement_animations() -> void:
	if not _actor: return
	
	# CRITICAL: If dead, don't play movement/idle animations
	if entity.get("sync_is_dead"):
		return
	
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
		
		# Optional: Hide the model after the animation ends (approx 1-2 seconds)
		var timer = get_tree().create_timer(1.5)
		timer.timeout.connect(func(): 
			if entity.get("sync_is_dead"):
				_actor.visible = false
		)
	
	# Hide UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_label = get_parent().get_node_or_null("HealthLabel")
	var health_bar_3d = get_parent().get_node_or_null("HealthBar3D")
	
	if name_label: name_label.visible = false
	if health_label: health_label.visible = false
	if health_bar_3d: health_bar_3d.visible = false
	
	EventBus.visual_effect_requested.emit(entity, "death")

## Play spawn/respawn visual effect.
func play_spawn_effect() -> void:
	if _actor:
		_actor.visible = true
		_actor.play_animation("Idle")
	
	# Show UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_label = get_parent().get_node_or_null("HealthLabel")
	var health_bar_3d = get_parent().get_node_or_null("HealthBar3D")
	
	if name_label: name_label.visible = true
	# We keep legacy label hidden
	if health_bar_3d: health_bar_3d.visible = true
	
	EventBus.visual_effect_requested.emit(entity, "spawn")

## Play hit/damage visual effect.
func _play_hit_effect() -> void:
	if _actor:
		_actor.play_animation("Hit")
		# Short lock to ensure hit animation is visible
		_anim_lock_time = 0.3 
		
	_apply_hitstop(0.08) # Freeze for 80ms for weight
	EventBus.visual_effect_requested.emit(entity, "hit")

func _apply_hitstop(duration: float) -> void:
	if _actor and _actor.animation_player:
		var original_speed = _actor.animation_player.speed_scale
		_actor.animation_player.speed_scale = 0.0
		await get_tree().create_timer(duration).timeout
		_actor.animation_player.speed_scale = original_speed

## Play an animation by name.
func play_animation(animation_name: String, blend: float = 0.2) -> void:
	if _actor:
		_actor.play_animation(animation_name, blend)

## Stop current animation.
func stop_animation() -> void:
	if _actor and _actor.animation_player:
		_actor.animation_player.stop()
