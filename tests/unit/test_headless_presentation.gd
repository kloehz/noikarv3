extends GutTest

## Focused tests for stripping presentation-only nodes from headless servers.

func test_match_manager_strips_top_level_presentation_nodes() -> void:
	var match_manager: Node = load("res://common/match_manager.gd").new()
	for node_name in ["Players", "Mobs", "Souls", "Totems", "HUD", "ConnectionMenu", "WorldEnvironment", "Sun"]:
		var node := Node3D.new()
		node.name = node_name
		match_manager.add_child(node)
	add_child(match_manager)

	match_manager._strip_headless_presentation()
	await get_tree().process_frame

	for node_name in ["HUD", "ConnectionMenu", "WorldEnvironment", "Sun"]:
		assert_null(match_manager.get_node_or_null(node_name), "%s should be removed on headless server" % node_name)
	match_manager.queue_free()

func test_base_entity_strips_presentation_without_simulation_nodes() -> void:
	var entity: BaseEntity = BaseEntity.new()
	for node_name in ["MeshInstance3D", "CameraPivot", "VisualComponent", "HealthViewport", "HealthBar3D", "NameLabel", "TickInterpolator"]:
		var node := Node.new()
		node.name = node_name
		entity.add_child(node)
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	entity.add_child(collision)
	var server_state := Node.new()
	server_state.name = "ServerState"
	entity.add_child(server_state)

	entity._strip_server_presentation()

	for node_name in ["MeshInstance3D", "CameraPivot", "VisualComponent", "HealthViewport", "HealthBar3D", "NameLabel", "TickInterpolator"]:
		assert_null(entity.get_node_or_null(node_name), "%s should be removed on headless server" % node_name)
	assert_not_null(entity.get_node_or_null("CollisionShape3D"), "collision must remain for simulation")
	assert_not_null(entity.get_node_or_null("ServerState"), "synchronized state must remain")
	entity.free()
