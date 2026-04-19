# res://common/TotemEntity.gd
extends CharacterBody3D

## A destructible totem used to summon pets.
## Allies can contribute souls to increase the pet's power.

signal summoned(type: String, souls: int)
signal destroyed

enum TotemType { ATTACK, TANK, HEAL }

@export var totem_type: TotemType = TotemType.ATTACK
@export var cast_duration: float = 3.0
@export var stored_souls: int = 0

@onready var server_state: Node = $ServerState
@onready var health_comp: Node = $HealthComponent

var _cast_timer: float = 0.0
var _is_active: bool = true

func _ready() -> void:
	if not multiplayer.is_server():
		set_process(false)
		return
		
	_cast_timer = cast_duration
	print("[Totem] Planted at ", global_position, " with type ", totem_type, " and souls ", stored_souls)
	
	if health_comp:
		health_comp.died.connect(_on_health_depleted)

func _process(delta: float) -> void:
	if not _is_active: return
	
	_cast_timer -= delta
	
	# Update sync_health in ServerState for clients to see (if using a health bar)
	if server_state and health_comp:
		server_state.sync_health = health_comp.current_health
	
	if _cast_timer <= 0:
		_complete_ritual()

func add_souls(amount: int) -> void:
	if not _is_active: return
	stored_souls += amount
	print("[Totem] Added ", amount, " souls. Total: ", stored_souls)

func _complete_ritual() -> void:
	_is_active = false
	print("[Totem] Ritual Complete! Summoning pet with ", stored_souls, " souls")
	summoned.emit(TotemType.keys()[totem_type], stored_souls)
	queue_free()

func _on_health_depleted() -> void:
	if not _is_active: return
	_is_active = false
	print("[Totem] DESTROYED! Souls lost: ", stored_souls)
	destroyed.emit()
	queue_free()
