extends GutTest

func test_recursive_strip_preserves_gameplay_paths_and_transforms() -> void:
	var manager = load("res://common/match_manager.gd").new()
	var map := Node3D.new()
	var visual := MeshInstance3D.new()
	visual.name = "Visual"
	visual.transform = Transform3D(Basis.from_euler(Vector3(0.2, 0.3, 0.1)), Vector3(4, 5, 6))
	map.add_child(visual)
	var marker := Marker3D.new()
	marker.name = "Spawn"
	marker.position = Vector3(1, 2, 3)
	visual.add_child(marker)
	var body := StaticBody3D.new()
	body.name = "Body"
	visual.add_child(body)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	body.add_child(collision)
	var expected := visual.transform
	manager._strip_visual_nodes_recursive(map)
	assert_true(map.has_node("Visual/Spawn"), "Preserve gameplay NodePaths through visual ancestors")
	assert_true(map.has_node("Visual/Body/Collision"))
	if map.has_node("Visual/Spawn"):
		assert_eq(map.get_node("Visual").transform, expected)
		assert_eq(map.get_node("Visual/Spawn").position, Vector3(1, 2, 3))
		assert_false(map.get_node("Visual") is MeshInstance3D)
	map.free()
	manager.free()

func test_collision_enabled_csg_is_not_stripped() -> void:
	var manager = load("res://common/match_manager.gd").new()
	var map := Node3D.new()
	var csg := CSGBox3D.new()
	csg.name = "Solid"
	csg.use_collision = true
	map.add_child(csg)
	manager._strip_visual_nodes_recursive(map)
	assert_true(map.has_node("Solid"), "CSG geometry owns collision and cannot be removed")
	map.free()
	manager.free()

func test_totem_scene_has_client_only_placeholder_and_identical_gameplay_paths() -> void:
	var scene_text := FileAccess.get_file_as_string("res://scenes/TotemEntity.tscn")
	assert_false(scene_text.contains('id="6_charge"'), "Client VFX must not be an eager server dependency")
	var scene = load("res://scenes/TotemEntity.tscn").instantiate()
	assert_true(scene.get_node("ChargeVFX").get_script() == null)
	assert_eq(scene.get_node("ChargeVFX").position, Vector3(0, 1, 0))
	for path in ["ServerState/StateSynchronizer", "HealthComponent", "HurtboxComponent/CollisionShape3D", "CollisionShape3D", "MultiplayerSynchronizer"]:
		assert_true(scene.has_node(path), path)
	var filter = scene.get_node("ServerState/StateSynchronizer").visibility_filter
	if filter.get_parent() == null: filter.free()
	scene.free()

func test_visual_resource_cache_is_lazy_and_headless_client_role_is_preserved() -> void:
	var script = load("res://client/VisualComponent.gd")
	assert_true(script.get("_client_resource_cache") is Dictionary, "Presentation resources are loaded only on demand")
	assert_false(GameManager.server_role_for_display(true, false, true))
	assert_true(GameManager.server_role_for_display(true, true, false))
