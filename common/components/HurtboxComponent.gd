# res://common/components/HurtboxComponent.gd
class_name HurtboxComponent
extends Area3D

## Hurtbox component for receiving damage from hitboxes.
## Attached to entities that can take damage.

signal hurt(hitbox: HitboxComponent)

@export var health_component: HealthComponent

var owner_node: Node

func _ready() -> void:
	owner_node = get_parent()

## Receive a hit from a hitbox.
func receive_hit(hitbox: HitboxComponent) -> void:
	hurt.emit(hitbox)
	
	if health_component:
		health_component.take_damage(hitbox.damage, hitbox.owner_node)

## Receive direct damage data (useful for Raycasts).
func receive_hit_data(damage_amount: int, source: Node) -> void:
	if health_component:
		health_component.take_damage(damage_amount, source)
