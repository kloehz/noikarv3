# res://common/BaseEntity.gd
class_name BaseEntity
extends CharacterBody3D

#region Signals
signal health_changed(current: int, maximum: int)
signal died
#endregion

#region Exports
@export var max_health: int = 100
@export var entity_name: String = "Entity"
@export var player_name: String = "Player":
	set(value):
		if player_name == value: return # PROTECTION: Avoid spam
		player_name = value
		_update_visuals()
#endregion

#region Public Variables
@export var is_dead: bool = false:
	set(v):
		if is_dead == v: return
		is_dead = v
		_on_death_state_changed()

var is_alive: bool:
	get:
		var hc = get_node_or_null("HealthComponent")
		return hc.current_health > 0 if hc else not is_dead
#endregion

func _ready() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())
	else:
		set_multiplayer_authority(1)
	
	# Authority for components
	if has_node("HealthComponent"): $HealthComponent.set_multiplayer_authority(1)
	if has_node("StateSynchronizer"): $StateSynchronizer.set_multiplayer_authority(1)

	_setup_visuals()
	_setup_netfox()
	_setup_health_component()

func _setup_visuals() -> void:
	if GameManager._is_headless_environment(): return
	var is_local_player = (name == str(multiplayer.get_unique_id()))
	var camera = get_node_or_null("CameraPivot/Camera3D")
	if camera:
		if is_local_player: camera.make_current()
		else:
			camera.current = false
			camera.hide()

func _setup_netfox() -> void:
	var interpolator = get_node_or_null("TickInterpolator")
	if interpolator and is_multiplayer_authority():
		interpolator.enabled = false

func _setup_health_component() -> void:
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.health_changed.connect(func(c, m): health_changed.emit(c, m))
		hc.died.connect(_on_health_component_died)

func _on_health_component_died() -> void:
	if multiplayer.is_server():
		is_dead = true
		EventBus.entity_died.emit(self)

func _on_death_state_changed() -> void:
	if is_dead:
		if has_node("VisualComponent"): $VisualComponent.play_death_effect()
		collision_layer = 0
		collision_mask = 0
	else:
		if has_node("VisualComponent"): $VisualComponent.play_spawn_effect()
		if has_node("HealthComponent"): $HealthComponent.reset_health()
		collision_layer = 1
		collision_mask = 1

func respawn(new_position: Vector3) -> void:
	if not multiplayer.is_server(): return
	is_dead = false
	global_position = new_position

func _update_visuals() -> void:
	if has_node("VisualComponent"): $VisualComponent.update_name(player_name)

func _is_server_authority() -> bool:
	return multiplayer == null or multiplayer.is_server()
