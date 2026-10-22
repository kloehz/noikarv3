extends GutTest

func _index():
	var path := "res://common/ActorSpatialIndex.gd"
	assert_true(ResourceLoader.exists(path), "Bounded avoidance index is implemented")
	return load(path).new() if ResourceLoader.exists(path) else null

func _actor(parent: Node3D, actor_name: String, pos: Vector3) -> Node3D:
	var actor := Node3D.new()
	actor.name = actor_name
	parent.add_child(actor)
	actor.position = pos
	actor.add_to_group(&"mobs")
	return actor

func test_bounded_xz_query_matches_scan_order_and_cell_boundaries() -> void:
	var index = _index()
	if index == null: return
	var root := Node3D.new()
	add_child_autofree(root)
	var a := _actor(root, "A", Vector3(-0.1, 0, 0))
	var b := _actor(root, "B", Vector3(2.2, 900, 0))
	var far := _actor(root, "Far", Vector3(300, 0, 0))
	for actor in [a, b, far]: index.register_actor(actor, &"mobs")
	assert_eq(index.query(a.global_position, 2.4, &"mobs"), [a, b], "Vertical separation is ignored by original avoidance")
	root.move_child(b, 0)
	assert_eq(index.query(a.global_position, 2.4, &"mobs"), [b, a], "Preserve scene-tree group order after reorder")

func test_movement_teleport_parent_move_free_and_replacement_do_not_leave_stale_members() -> void:
	var index = _index()
	if index == null: return
	var root := Node3D.new()
	add_child_autofree(root)
	var a := _actor(root, "A", Vector3(100, 0, 0))
	index.register_actor(a, &"mobs")
	a.position = Vector3.ZERO
	index.update_actor(a)
	assert_eq(index.query(Vector3.ZERO, 2.4, &"mobs"), [a])
	root.position = Vector3(200, 0, 0)
	assert_eq(index.query(Vector3(200, 0, 0), 2.4, &"mobs"), [a], "Container teleports refresh world-space cells")
	assert_eq(index.query(Vector3.ZERO, 2.4, &"mobs"), [])
	index.unregister_actor(a)
	root.remove_child(a)
	a.free()
	var replacement := _actor(root, "A", Vector3.ZERO)
	index.register_actor(replacement, &"mobs")
	assert_eq(index.query(Vector3(200, 0, 0), 2.4, &"mobs"), [replacement])
	replacement.free()
	assert_eq(index.query(Vector3(200, 0, 0), 2.4, &"mobs"), [])

class IndexedActor extends BaseEntity:
	func _init() -> void:
		var state_node := Node.new()
		state_node.name = "ServerState"
		add_child(state_node)
	func _enter_tree() -> void:
		pass
	func _ready() -> void:
		add_to_group(&"mobs")
		_register_avoidance_index()

func test_base_entity_notifications_and_no_index_fallback_match_live_membership() -> void:
	var index = _index()
	if index == null: return
	var previous := multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var manager := Node3D.new()
	manager.add_to_group(&"match_manager")
	manager.set_meta(&"actor_spatial_index", index)
	add_child_autofree(manager)
	var actor := IndexedActor.new()
	actor.name = "MOB_Test"
	manager.add_child(actor)
	actor.position = Vector3(200, 0, 0)
	assert_eq(index.query(Vector3(200, 0, 0), 2.4, &"mobs"), [actor], "Movement/teleport notices update cells without a per-query full scan")
	assert_eq(index.query(Vector3.ZERO, 2.4, &"mobs"), [])
	actor.position = Vector3.ZERO
	assert_eq(actor.bounded_avoidance_allies(&"mobs", 2.4), [actor])
	actor._avoidance_index = null
	assert_eq(actor.bounded_avoidance_allies(&"mobs", 2.4), get_tree().get_nodes_in_group(&"mobs"), "No-index mode preserves original scan")
	index.unregister_actor(actor)
	multiplayer.multiplayer_peer = previous
