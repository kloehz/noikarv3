# res://common/TotemEntity.gd
extends CharacterBody3D

## A 3-second charge ritual that summons a mob of the chosen type.
## Visually driven by vfx_blank_charge (one-shot, colored by totem_type).
## Allies can still contribute souls to scale the summoned mob.

signal summoned(type: int, souls: int)
signal destroyed

enum TotemType { ATTACK, TANK, HEAL }

const TYPE_COLORS := {
	TotemType.ATTACK: {
		"primary": Color(1.0, 0.25, 0.25, 1),
		"secondary": Color(0.75, 0.05, 0.05, 1),
		"tertiary": Color(0.45, 0.0, 0.0, 1),
		"emission": 2.5,
	},
	TotemType.TANK: {
		"primary": Color(0.3, 0.6, 1.0, 1),
		"secondary": Color(0.1, 0.3, 0.75, 1),
		"tertiary": Color(0.0, 0.1, 0.45, 1),
		"emission": 2.5,
	},
	TotemType.HEAL: {
		"primary": Color(0.3, 1.0, 0.45, 1),
		"secondary": Color(0.1, 0.65, 0.2, 1),
		"tertiary": Color(0.0, 0.35, 0.1, 1),
		"emission": 2.5,
	},
}

@export var totem_type: TotemType = TotemType.ATTACK
@export var cast_duration: float = 3.0
@export var stored_souls: int = 0

## Owning faction, set by MatchManager at spawn from the summoner's team.
## HurtboxComponent uses it to reject friendly fire: allies can no longer
## destroy their own ritual, enemies (and mobs) still can.
var team_id: int = TeamId.NONE

@onready var server_state: Node = $ServerState
@onready var health_comp: Node = $HealthComponent
@onready var _vfx: Node3D = $ChargeVFX

var _is_active: bool = true

func _ready() -> void:
	_setup_charge_vfx()

	if not multiplayer.is_server():
		return

	if health_comp:
		health_comp.died.connect(_on_health_depleted)

	print("[Totem] Ritual started at ", global_position, " with type ", totem_type, " and souls ", stored_souls)

	await get_tree().create_timer(cast_duration).timeout
	_complete_ritual()

func _setup_charge_vfx() -> void:
	_make_charge_materials_unique()
	var palette: Dictionary = TYPE_COLORS.get(totem_type, TYPE_COLORS[TotemType.ATTACK])
	_vfx.set("primary_color", palette["primary"])
	_vfx.set("secondary_color", palette["secondary"])
	_vfx.set("tertiary_color", palette["tertiary"])
	_vfx.set("emission", palette["emission"])
	_vfx.set("one_shot", true)
	_vfx.call("play")

## Packed-scene ShaderMaterials are shared by default. Each totem must own its
## copies, otherwise configuring a later summon recolors an active earlier VFX.
func _make_charge_materials_unique() -> void:
	for child in _vfx.get_children():
		if child is GPUParticles3D or child is MeshInstance3D:
			if child.material_override:
				child.material_override = child.material_override.duplicate()

func add_souls(amount: int) -> void:
	if not _is_active: return
	stored_souls += amount
	print("[Totem] Added ", amount, " souls. Total: ", stored_souls)

func _complete_ritual() -> void:
	if not _is_active: return
	_is_active = false
	print("[Totem] Ritual Complete! Summoning mob with ", stored_souls, " souls")
	summoned.emit(int(totem_type), stored_souls)
	queue_free()

func _on_health_depleted() -> void:
	if not _is_active: return
	_is_active = false
	print("[Totem] DESTROYED! Souls lost: ", stored_souls)
	destroyed.emit()
	queue_free()
