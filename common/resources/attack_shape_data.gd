# res://common/resources/attack_shape_data.gd
## Pure data resource defining the collision shape for a melee hitscan attack.
## Used by AttackDefinition to configure the dynamic ShapeCast3D in CombatComponent.
## This resource contains NO logic — only shape parameters.
class_name AttackShapeData
extends Resource

enum ShapeType { SPHERE, BOX, CAPSULE }

## The type of collision shape to create.
@export var shape_type: ShapeType = ShapeType.SPHERE

## Radius of the shape (SPHERE, CAPSULE).
@export var radius: float = 1.0

## Length of the shape (BOX width, CAPSULE height).
@export var length: float = 1.0

## Height of the shape (BOX only).
@export var height: float = 1.0

## Local offset from the entity's origin where the cast starts.
## Typical melee: Vector3(0, 1, -1.5) puts it in front at chest height.
@export var offset: Vector3 = Vector3(0, 1, -1.5)

## Multiplier applied on top of AttackDefinition.base_damage.
@export var damage_multiplier: float = 1.0
