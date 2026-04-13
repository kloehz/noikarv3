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
#endregion

#region Public Accessors (delegate to ServerState)
var player_name: String:
	get: return server_state.player_name if server_state else "Player"
	set(v):
		if server_state and multiplayer.is_server():
			server_state.player_name = v

var sync_is_dead: bool:
	get: return server_state.sync_is_dead if server_state else false
	set(v):
		if server_state and multiplayer.is_server():
			server_state.sync_is_dead = v

var sync_health: int:
	get: return server_state.sync_health if server_state else 100
	set(v):
		if server_state and multiplayer.is_server():
			server_state.sync_health = v
#endregion

@onready var server_state: ServerState = $ServerState

func _ready() -> void:
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())
	else:
		set_multiplayer_authority(1)
	
	# Connect ServerState signals for visual/logic updates
	if server_state:
		server_state.health_changed.connect(_on_sync_health_changed)
		server_state.death_changed.connect(_on_sync_death_changed)
		server_state.name_changed.connect(func(_n): _update_visuals())
		
		if multiplayer.is_server():
			server_state.max_health = max_health
			server_state.sync_health = max_health

	_setup_visuals()
	_setup_netfox()
	_setup_health_component()

func _on_sync_health_changed(current: int, maximum: int) -> void:
	var hc = get_node_or_null("HealthComponent")
	if hc: hc.current_health = current
	health_changed.emit(current, maximum)

func _on_sync_death_changed(is_dead: bool) -> void:
	if is_dead:
		if has_node("VisualComponent"): $VisualComponent.play_death_effect()
		collision_layer = 0
		collision_mask = 0
		EventBus.entity_died.emit(self)
	else:
		if has_node("VisualComponent"): $VisualComponent.play_spawn_effect()
		if has_node("HealthComponent"): $HealthComponent.reset_health()
		collision_layer = 1
		collision_mask = 1

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
		hc.health_changed.connect(func(c, m): 
			if multiplayer.is_server() and server_state:
				server_state.sync_health = c
			health_changed.emit(c, m)
		)
		hc.died.connect(func(): 
			if multiplayer.is_server() and server_state:
				server_state.sync_is_dead = true
		)

func respawn(new_position: Vector3) -> void:
	if not multiplayer.is_server(): return
	global_position = new_position
	if server_state:
		server_state.sync_is_dead = false
		server_state.sync_health = max_health

func _update_visuals() -> void:
	if has_node("VisualComponent"): $VisualComponent.update_name(player_name)

func _is_server_authority() -> bool:
	return multiplayer == null or multiplayer.is_server()
