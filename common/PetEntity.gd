# res://common/PetEntity.gd
extends CharacterBody3D

## A summoned pet that follows its owner and attacks enemies.

@export var owner_id: int = 1
@export var pet_type: String = "ATTACK"
@export var power_level: int = 0

@onready var server_state: Node = $ServerState
@onready var health_comp: Node = $HealthComponent

func _ready() -> void:
	if not multiplayer.is_server():
		return
		
	# Scale stats based on power level
	_apply_power_scaling()
	print("[Pet] Summoned for ", owner_id, " Power: ", power_level)

func _apply_power_scaling() -> void:
	var multiplier = 1.0 + (power_level * 0.1)
	
	if health_comp:
		var base_hp = 100 if pet_type != "TANK" else 200
		health_comp.max_health = int(base_hp * multiplier)
		health_comp.reset_health()
	
	# Visual scaling (sent to clients via scale property if synced, 
	# but for now we'll just log it)
	scale = Vector3.ONE * (1.0 + (power_level * 0.05))

func _rollback_tick(_delta: float, _tick: int, is_fresh: bool) -> void:
	if not is_fresh or not multiplayer.is_server(): return
	
	# Basic AI: Follow owner or attack nearest
	# (To be implemented in the next IA phase)
	pass
