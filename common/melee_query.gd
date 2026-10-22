class_name MeleeQuery
extends RefCounted

## Geometry and collision policy shared by authored and dynamic attack casts.
## Disabled casts still support force_shapecast_update at the ACTIVE event.
static func configure(cast: ShapeCast3D, data: AttackShapeData, attacker: Node) -> void:
	var shape: Shape3D
	match data.shape_type:
		AttackShapeData.ShapeType.SPHERE:
			var sphere := SphereShape3D.new()
			sphere.radius = data.radius
			shape = sphere
		AttackShapeData.ShapeType.BOX:
			var box := BoxShape3D.new()
			box.size = Vector3(data.radius * 2, data.height, data.length)
			shape = box
		AttackShapeData.ShapeType.CAPSULE:
			var capsule := CapsuleShape3D.new()
			capsule.radius = data.radius
			capsule.height = data.length
			shape = capsule
	cast.enabled = false
	cast.shape = shape
	cast.transform.origin = data.offset
	cast.target_position = Vector3.ZERO
	cast.max_results = 8
	cast.collision_mask = 8
	cast.collide_with_areas = true
	cast.collide_with_bodies = false
	cast.add_exception(attacker)
