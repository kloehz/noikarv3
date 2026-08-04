extends GutTest

## Pet HUD contracts: roles have a stable visual identity and the gameplay
## scene mounts the HUD under its existing CanvasLayer.

func test_each_pet_role_has_a_distinct_icon_color() -> void:
	var icon_script := load("res://client/ui/PetRoleIcon.gd")
	assert_ne(icon_script.color_for("ATTACK"), icon_script.color_for("TANK"))
	assert_ne(icon_script.color_for("TANK"), icon_script.color_for("HEAL"))
	assert_ne(icon_script.color_for("HEAL"), icon_script.color_for("ATTACK"))

func test_main_scene_mounts_pet_hud_in_the_existing_hud_layer() -> void:
	var main_scene: PackedScene = load("res://scenes/main.tscn")
	var main := main_scene.instantiate()
	assert_true(main.has_node("HUD/PetHUD"))
	assert_eq(main.get_node("HUD/PetHUD").get_script().resource_path, "res://client/ui/PetHud.gd")
	main.queue_free()

func test_pet_filter_uses_pet_api_instead_of_generated_name() -> void:
	var hud_script := load("res://client/ui/PetHud.gd")
	var hud := hud_script.new()
	var pet := _PetHudTestPet.new()
	pet.owner_id = 7
	assert_true(hud._belongs_to_local_player(pet, 7))
	assert_false(hud._belongs_to_local_player(pet, 8))

func test_portrait_card_builds_before_its_camera_enters_the_viewport_tree() -> void:
	var card_script := load("res://client/ui/PetPortraitCard.gd")
	var card := card_script.new()
	add_child_autofree(card)
	await get_tree().process_frame
	assert_eq(card.custom_minimum_size, Vector2(38, 38))

func test_totems_own_their_charge_vfx_materials() -> void:
	var totem_scene: PackedScene = load("res://scenes/TotemEntity.tscn")
	var attack_totem := totem_scene.instantiate()
	var tank_totem := totem_scene.instantiate()
	attack_totem.totem_type = 0
	tank_totem.totem_type = 1
	add_child_autofree(attack_totem)
	add_child_autofree(tank_totem)
	await get_tree().process_frame
	var attack_material: ShaderMaterial = attack_totem.get_node("ChargeVFX/Surface").material_override
	var tank_material: ShaderMaterial = tank_totem.get_node("ChargeVFX/Surface").material_override
	assert_ne(attack_material.get_instance_id(), tank_material.get_instance_id())
	assert_ne(attack_material.get_shader_parameter("primary_color"), tank_material.get_shader_parameter("primary_color"))

class _PetHudTestPet:
	extends Node

	var owner_id := 0

	func setup_pet(_owner: int, _type: String, _souls: int) -> void:
		pass
