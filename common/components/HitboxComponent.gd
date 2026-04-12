# res://common/components/HitboxComponent.gd
class_name HitboxComponent
extends Area3D

## Hitbox component for dealing damage to hurtboxes.
## Used by attacks, projectiles, and environmental hazards.

signal hit(hurtbox: HurtboxComponent)

@export var damage: int = 10
@export var knockback_force: float = 200.0
@export var knockback_direction: Vector3 = Vector3.UP

var owner_node: Node

func _ready() -> void:
	owner_node = get_parent()
	area_entered.connect(_on_area_entered)

## Handle area entry - check if it's a valid hurtbox.
func _on_area_entered(area: Area3D) -> void:
	if area is HurtboxComponent:
		var hurtbox := area as HurtboxComponent
		# Don't hit our own hurtbox
		if hurtbox.owner_node != owner_node:
			hit.emit(hurtbox)
			hurtbox.receive_hit(self)

## Apply knockback to a target node.
func apply_knockback(target: Node3D) -> void:
	if target and target.has_method("apply_knockback"):
		target.apply_knockback(knockback_direction * knockback_force)
