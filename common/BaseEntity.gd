# res://common/BaseEntity.gd
class_name BaseEntity
extends CharacterBody3D

## Base entity class for all game entities.
## Extends CharacterBody3D for physics integration.
## Uses Netfox for rollback and state synchronization.

#region Signals
signal health_changed(current: int, maximum: int)
signal died
#endregion

#region Exports
@export var max_health: int = 100
@export var entity_name: String = "Entity"
@export var player_name: String = "Player":
	set(value):
		player_name = value
		_update_visuals()
#endregion

#region Public Variables
@export var current_health: int:
	set(value):
		var old := current_health
		current_health = clampi(value, 0, max_health)
		if current_health != old:
			health_changed.emit(current_health, max_health)
			if current_health <= 0:
				died.emit()

var is_alive: bool:
	get: return current_health > 0
#endregion

#region Private Variables
var _health_component: Node
var _rollback_synchronizer: RollbackSynchronizer
var _state_synchronizer: StateSynchronizer
#endregion

func _ready() -> void:
	# Set authority based on name if the name is a valid peer ID
	if name.is_valid_int():
		set_multiplayer_authority(name.to_int())
		print("[BaseEntity] Authority set to ", name, " for node ", get_path())

	_setup_visuals()
	_setup_netfox()
	_setup_health_component()
	
	if _is_server_authority():
		current_health = max_health

func _setup_visuals() -> void:
	# If we are a headless server, we don't need cameras
	if GameManager._is_headless_environment():
		return

	# We use the node name which is set to the peer_id string
	# This is the most reliable way to check ownership during spawn
	var is_local_player = (name == str(multiplayer.get_unique_id()))
	
	var camera: Camera3D = get_node_or_null("CameraPivot/Camera3D")
	if camera:
		if is_local_player:
			camera.make_current()
			print("[BaseEntity] Camera activated for local player: ", name)
		else:
			camera.current = false
			# Instead of deleting, we just disable it to avoid race conditions
			camera.process_mode = Node.PROCESS_MODE_DISABLED
			camera.hide()

func _setup_netfox() -> void:
	_rollback_synchronizer = $RollbackSynchronizer
	_state_synchronizer = $StateSynchronizer
	
	# Disable interpolation for the local player to avoid visual delay ( Rakion style )
	var interpolator = get_node_or_null("TickInterpolator")
	if interpolator and is_multiplayer_authority():
		interpolator.enabled = false
		print("[BaseEntity] Interpolation disabled for local authority: ", name)

## Set up health component integration.
func _setup_health_component() -> void:
	_health_component = $HealthComponent
	if _health_component and _health_component.has_signal("health_changed"):
		_health_component.health_changed.connect(_on_health_component_changed)
		_health_component.died.connect(_on_health_component_died)

func _on_health_component_changed(current: int, _maximum: int) -> void:
	current_health = current

func _on_health_component_died() -> void:
	died.emit()

func take_damage(amount: int, source: Node = null) -> void:
	if not is_alive or not _is_server_authority():
		return
	
	if _health_component and _health_component.has_method("take_damage"):
		_health_component.take_damage(amount, source)
	else:
		current_health -= amount

func heal(amount: int) -> void:
	if not is_alive or not _is_server_authority():
		return
	
	if _health_component and _health_component.has_method("heal"):
		_health_component.heal(amount)
	else:
		current_health = mini(current_health + amount, max_health)

func _update_visuals() -> void:
	if has_node("VisualComponent"):
		$VisualComponent.update_name(player_name)

func _is_server_authority() -> bool:
	return multiplayer == null or multiplayer.is_server()
