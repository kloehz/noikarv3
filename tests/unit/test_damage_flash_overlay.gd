extends GutTest

const DAMAGE_FLASH_SCENE := preload("res://scenes/ui/DamageFlashOverlay.tscn")
const VISUAL_COMPONENT_SCRIPT := preload("res://client/VisualComponent.gd")

func test_overlay_uses_one_full_rect_shader_vignette_and_ignores_mouse_input() -> void:
	var overlay := DAMAGE_FLASH_SCENE.instantiate() as Control
	add_child_autofree(overlay)
	await get_tree().process_frame

	assert_eq(overlay.anchor_left, 0.0)
	assert_eq(overlay.anchor_top, 0.0)
	assert_eq(overlay.anchor_right, 1.0)
	assert_eq(overlay.anchor_bottom, 1.0)
	assert_eq(overlay.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_eq(overlay.get_child_count(), 1, "Damage feedback is one full-screen shader surface, not four edge bands")
	var vignette := overlay.get_child(0) as ColorRect
	assert_not_null(vignette)
	assert_eq(vignette.name, "Vignette")
	assert_eq(vignette.anchor_left, 0.0)
	assert_eq(vignette.anchor_top, 0.0)
	assert_eq(vignette.anchor_right, 1.0)
	assert_eq(vignette.anchor_bottom, 1.0)
	assert_eq(vignette.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	assert_true(vignette.material is ShaderMaterial, "The full-rect surface must be shader-backed for nearest-edge vignette falloff")

func test_flash_is_brief_and_resets_visibility() -> void:
	var overlay := DAMAGE_FLASH_SCENE.instantiate() as Control
	overlay.set("flash_alpha", 0.4)
	overlay.set("flash_in_seconds", 0.01)
	overlay.set("flash_out_seconds", 0.03)
	add_child_autofree(overlay)
	await get_tree().process_frame

	overlay.call("flash")
	assert_true(overlay.visible)
	var vignette := overlay.get_node("Vignette") as ColorRect
	var material := vignette.material as ShaderMaterial
	await get_tree().create_timer(0.02).timeout
	assert_gt(material.get_shader_parameter(&"flash_strength"), 0.0, "The shader vignette strength rises during the flash")
	await get_tree().create_timer(0.08).timeout
	assert_false(overlay.visible)
	assert_almost_eq(material.get_shader_parameter(&"flash_strength"), 0.0, 0.01)

func test_local_player_damage_triggers_overlay_flash_only_for_authoritative_player() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	var overlay := DAMAGE_FLASH_SCENE.instantiate() as Control
	hud.add_child(overlay)
	add_child_autofree(hud)

	var local_entity := CharacterBody3D.new()
	local_entity.add_to_group(&"players")
	var local_visual = VISUAL_COMPONENT_SCRIPT.new()
	local_visual.entity = local_entity
	local_entity.add_child(local_visual)
	add_child_autofree(local_entity)
	await get_tree().process_frame

	local_visual._on_damage_received(7, null)
	assert_true(overlay.visible, "Authoritative local player damage should flash the HUD vignette overlay")

	overlay.visible = false
	overlay.modulate.a = 0.0
	var local_mob := CharacterBody3D.new()
	local_mob.add_to_group(&"mobs")
	var mob_visual = VISUAL_COMPONENT_SCRIPT.new()
	mob_visual.entity = local_mob
	local_mob.add_child(mob_visual)
	add_child_autofree(local_mob)
	await get_tree().process_frame

	mob_visual._on_damage_received(7, null)
	assert_false(overlay.visible, "Authoritative mob damage must not flash this client's HUD")

	var remote_entity := CharacterBody3D.new()
	remote_entity.add_to_group(&"players")
	remote_entity.set_multiplayer_authority(2)
	var remote_visual = VISUAL_COMPONENT_SCRIPT.new()
	remote_visual.entity = remote_entity
	remote_entity.add_child(remote_visual)
	add_child_autofree(remote_entity)
	await get_tree().process_frame

	remote_visual._on_damage_received(7, null)
	assert_false(overlay.visible, "Remote player damage must not flash this client's HUD")
