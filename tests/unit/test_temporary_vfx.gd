extends "res://tests/isolated_gut_test.gd"
## Temporary presentation must stay visible without the faulty GPU particle path.

func before_each() -> void:
	super.before_each()
	enable_client_presentation()

func test_soul_is_visible_without_gpu_particles_and_collection_still_works() -> void:
	var soul: Area3D = load("res://scenes/SoulEntity.tscn").instantiate()
	add_child_autofree(soul)
	assert_eq(soul.find_children("*", "GPUParticles3D", true, false).size(), 0)
	var meshes := soul.find_children("*", "MeshInstance3D", true, false)
	assert_gt(meshes.size(), 0, "Temporary soul must remain visible")
	for mesh in meshes:
		assert_false(mesh.material_override is ShaderMaterial)
	var player := BaseEntity.new()
	player.name = "1"
	var state := ServerState.new()
	player.add_child(state)
	player.server_state = state
	state.sync_souls = 4
	autofree(player)
	watch_signals(soul)
	soul._collect(player)
	assert_eq(state.sync_souls, 5)
	assert_signal_emitted_with_parameters(soul, "collected", [player])
	assert_true(soul.is_queued_for_deletion())

func test_impact_remains_visible_then_releases_itself_without_gpu_particles() -> void:
	var path: String = load("res://client/VisualComponent.gd").VFX_HIT_02_PATH
	var impact: Node3D = load(path).instantiate()
	add_child_autofree(impact)
	assert_eq(impact.find_children("*", "GPUParticles3D", true, false).size(), 0)
	assert_gt(impact.find_children("*", "MeshInstance3D", true, false).size(), 0)
	assert_true(impact.has_method("play"))
	if impact.has_method("play"): impact.play()
	await get_tree().create_timer(0.6).timeout
	assert_false(is_instance_valid(impact), "Short-lived impact must clean up after playback")
