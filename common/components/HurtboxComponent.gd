# res://common/components/HurtboxComponent.gd
class_name HurtboxComponent
extends Area3D

## Hurtbox component for receiving damage from hitboxes.
## Attached to entities that can take damage.

signal hurt(hitbox: HitboxComponent)

@export var health_component: HealthComponent

## Constant base threat multiplier a tank pet generates on every damage
## event. Stacks on top of any per-level bonus the pet declares (see
## _threat_multiplier_for). 1.75 means a tank that deals X damage
## writes 1.75 * X threat to the aggro system, so tanks naturally hold
## mob attention without needing extra targeting logic.
const TANK_PET_THREAT_MULTIPLIER: float = 1.75
## Per-power_level bonus added to the tank multiplier. A level-5 tank
## pulls threat at 1.75 + 5 * 0.05 = 2.0x, so leveling a tank makes it
## measurably better at holding aggro without changing its damage.
const TANK_PET_THREAT_PER_LEVEL: float = 0.05

var owner_node: Node

func _ready() -> void:
	owner_node = get_parent()

## Receive a hit from a hitbox.
func receive_hit(hitbox: HitboxComponent) -> void:
	hurt.emit(hitbox)
	_apply_threat(hitbox.damage, hitbox.owner_node)

	if health_component:
		var damage_dealt := health_component.take_damage(hitbox.damage, hitbox.owner_node)
		_react_to_damage_source(hitbox.owner_node, damage_dealt)

## Receive direct damage data (useful for Raycasts).
func receive_hit_data(damage_amount: int, source: Node) -> void:
	_apply_threat(damage_amount, source)
	if health_component:
		var damage_dealt := health_component.take_damage(damage_amount, source)
		_react_to_damage_source(source, damage_dealt)

## A damaged pet should defend itself even when it was merely following its
## owner. This only reacts to mobs; pets still never retaliate against pets.
func _react_to_damage_source(source: Node, damage_dealt: int) -> void:
	if damage_dealt <= 0 or owner_node == null or not owner_node.is_in_group(&"pets"):
		return
	if source == null or not source.is_in_group(&"mobs"):
		return
	var ai := owner_node.get_node_or_null("AIComponent")
	if ai and ai.has_method("engage_attacker"):
		ai.engage_attacker(source)

## Writes the per-attacker threat to THIS victim's ServerState.
## Threat is keyed by the attacker's entity name, so each mob tracks
## its own aggro independently. A hit on mob A only writes to
## mob A's table — mob B (which wasn't hit) keeps an empty table
## and ignores the threat source. The damage event is still
## multiplied by the attacker's pet_type (1.75 + level for TANK,
## 1.0 for everything else) so tank pets pull more aggro per hit.
func _apply_threat(damage_amount: int, source: Node) -> void:
	if source == null:
		return
	if owner_node == null or not owner_node.has_node("ServerState"):
		return
	var victim_state := owner_node.get_node("ServerState")
	var mult: float = _threat_multiplier_for(source)
	if mult <= 0.0:
		return
	var attacker_name: String = str(source.name)
	victim_state.add_threat(attacker_name, int(damage_amount * mult))

## Returns the threat multiplier the attacker contributes to the aggro
## total. Players, projectiles and non-tank pets are 1.0. Tank pets
## stack the constant base + a per-power-level bonus so a level-5
## tank writes ~14% more threat than a fresh one per damage point.
func _threat_multiplier_for(source: Node) -> float:
	if source == null:
		return 1.0
	if source.get("pet_type") == "TANK":
		var power_level: int = int(source.get("power_level") or 0)
		return TANK_PET_THREAT_MULTIPLIER + float(power_level) * TANK_PET_THREAT_PER_LEVEL
	return 1.0
