extends GutTest

const VISUAL_COMPONENT_SCRIPT := preload("res://client/VisualComponent.gd")
const IVERN_SPEC := preload("res://common/resources/specs/ivern_ranger.tres")

func _make_aiming_visual() -> Array:
	var scene_root := Node3D.new()
	scene_root.name = "SceneRoot"
	add_child_autofree(scene_root)

	var hud := CanvasLayer.new()
	hud.name = "HUD"
	scene_root.add_child(hud)

	var entity := CharacterBody3D.new()
	entity.name = "1"
	scene_root.add_child(entity)

	var camera_pivot := Node3D.new()
	camera_pivot.name = "CameraPivot"
	entity.add_child(camera_pivot)
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.fov = 75.0
	camera_pivot.add_child(camera)

	var logic := LogicComponent.new()
	logic.name = "LogicComponent"
	logic.is_shooting = true
	entity.add_child(logic)

	var combat := CombatComponent.new()
	combat.name = "CombatComponent"
	combat.configure(IVERN_SPEC.primary_attack)
	combat.current_charge_time = IVERN_SPEC.primary_attack.charge_duration * 0.5
	entity.add_child(combat)

	var visual = VISUAL_COMPONENT_SCRIPT.new()
	visual.entity = entity
	entity.add_child(visual)
	await get_tree().process_frame
	return [visual, camera, hud]

func test_ivern_aim_fov_matches_base_camera_fov() -> void:
	assert_eq(IVERN_SPEC.primary_attack.aim_fov, 75.0)

func test_ivern_charged_aim_preserves_reticle_without_camera_zoom() -> void:
	var setup := await _make_aiming_visual()
	var visual = setup[0]
	var camera: Camera3D = setup[1]
	var hud: CanvasLayer = setup[2]

	visual._handle_local_aim_presentation(0.1)

	var reticle := hud.get_node_or_null("AimReticle") as Control
	assert_not_null(reticle)
	assert_true(reticle.visible)
	assert_almost_eq(reticle.get("charge_progress"), 0.5, 0.01)
	assert_almost_eq(camera.fov, 75.0, 0.01)
