extends GutTest

const DECISION_CLOCK := preload("res://common/npc_decision_clock.gd")
const MELEE_QUERY := preload("res://common/melee_query.gd")

# These tests use production helpers with real engine collision queries.
# Full AI/movement integration must be verified before enabling either experiment.
func test_clock_counts_are_rate_independent_and_preserve_elapsed_time() -> void:
	for tickrate in [30, 60]:
		for rate in [5.0, 10.0]:
			var clock := DECISION_CLOCK.new()
			clock.configure("MOB_A", rate)
			var calls := 0
			var elapsed := 0.0
			for i in tickrate * 3:
				var step := clock.advance(1.0 / tickrate)
				if step > 0.0:
					calls += 1
					elapsed += step
			assert_between(calls, int(rate * 3) - 1, int(rate * 3) + 1)
			assert_almost_eq(elapsed + clock.pending_elapsed(), 3.0, 0.00001)

func test_clock_staggers_entities_and_wakes_on_next_tick() -> void:
	var phases := {}
	for i in 24:
		var clock := DECISION_CLOCK.new()
		clock.configure("MOB_%d" % i, 10.0)
		phases[clock.remaining] = true
		clock.wake()
		assert_gt(clock.advance(1.0 / 30.0), 0.0)
	assert_gt(phases.size(), 3)

func test_disabled_production_melee_query_hits_real_hurtbox_on_demand() -> void:
	var root := Node3D.new()
	add_child_autofree(root)
	var attacker := CharacterBody3D.new()
	root.add_child(attacker)
	var cast := ShapeCast3D.new()
	attacker.add_child(cast)
	var data := AttackShapeData.new()
	data.radius = 1.0
	data.offset = Vector3.ZERO
	MELEE_QUERY.configure(cast, data, attacker)
	var area := Area3D.new()
	area.collision_layer = 8
	area.collision_mask = 0
	var collision := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.25
	collision.shape = sphere
	area.add_child(collision)
	root.add_child(area)
	area.position = Vector3(0.5, 0.0, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	assert_false(cast.enabled)
	assert_false(cast.is_colliding(), "Idle physics does not update the disabled query")
	cast.force_shapecast_update()
	assert_true(cast.is_colliding(), "Actual attack-time query finds a native Area3D")
	assert_eq(cast.get_collider(0), area)
	assert_eq(cast.max_results, 8)
	assert_eq(cast.collision_mask, 8)
	area.position = Vector3(8.0, 0.0, 0.0)
	area.force_update_transform()
	await get_tree().physics_frame
	cast.force_shapecast_update()
	assert_false(cast.is_colliding(), "Later attack-time queries discard stale hits")

func test_all_melee_shape_types_keep_geometry_and_query_policy() -> void:
	var attacker := CharacterBody3D.new()
	add_child_autofree(attacker)
	for kind in [AttackShapeData.ShapeType.SPHERE, AttackShapeData.ShapeType.BOX, AttackShapeData.ShapeType.CAPSULE]:
		var cast := ShapeCast3D.new()
		attacker.add_child(cast)
		var data := AttackShapeData.new()
		data.shape_type = kind
		MELEE_QUERY.configure(cast, data, attacker)
		assert_not_null(cast.shape)
		assert_false(cast.enabled)
		assert_true(cast.collide_with_areas)
		assert_false(cast.collide_with_bodies)
		assert_eq(cast.target_position, Vector3.ZERO)
