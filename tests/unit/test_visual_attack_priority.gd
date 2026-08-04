extends GutTest

const VISUAL_COMPONENT_SCRIPT := preload("res://client/VisualComponent.gd")

func _make_actor() -> CharacterActor:
	var actor := CharacterActor.new()
	actor.anim_attack = "Attack"
	actor.anim_hit = "Hit"
	var player := AnimationPlayer.new()
	var library := AnimationLibrary.new()
	var attack := Animation.new()
	attack.length = 0.2
	var hit := Animation.new()
	hit.length = 0.2
	library.add_animation("Attack", attack)
	library.add_animation("Hit", hit)
	player.add_animation_library("", library)
	actor.add_child(player)
	return actor

func _make_visual(group: StringName = &"") -> Array:
	var entity := CharacterBody3D.new()
	if group != &"":
		entity.add_to_group(group)
	var visual = VISUAL_COMPONENT_SCRIPT.new()
	visual.entity = entity
	entity.add_child(visual)
	var actor := _make_actor()
	entity.add_child(actor)
	add_child_autofree(entity)
	await get_tree().process_frame
	visual.setup_with_actor(actor)
	return [visual, actor]

func test_mob_attack_preempts_and_blocks_hurt_animation() -> void:
	var setup := await _make_visual(&"mobs")
	var visual = setup[0]
	var actor: CharacterActor = setup[1]

	visual.play_shoot_effect()
	assert_true(visual._attack_visual_active, "Mobs protect an active attack visual")
	assert_eq(actor.get_current_animation(), "Attack")

	visual._play_hit_effect()
	assert_eq(actor.get_current_animation(), "Attack",
		"Damage VFX must not replace a mob attack animation")

func test_pet_attack_finishes_and_releases_visual_priority() -> void:
	var setup := await _make_visual(&"pets")
	var visual = setup[0]

	visual.play_shoot_effect()
	assert_true(visual._attack_visual_active)
	await get_tree().create_timer(0.35).timeout
	assert_false(visual._attack_visual_active,
		"The completed attack clip must release the visual lock")

func test_pet_attack_lock_ignores_early_animation_finished_signal() -> void:
	var setup := await _make_visual(&"pets")
	var visual = setup[0]
	var actor: CharacterActor = setup[1]

	visual.play_shoot_effect()
	actor.animation_player.animation_finished.emit(&"Attack")
	assert_true(visual._attack_visual_active,
		"Only the measured clip duration may release an attack lock")

func test_player_damage_behavior_is_unchanged() -> void:
	var setup := await _make_visual()
	var visual = setup[0]
	var actor: CharacterActor = setup[1]

	visual.play_shoot_effect()
	visual._play_hit_effect()
	assert_eq(actor.get_current_animation(), "Hit",
		"Players retain the current hurt-animation behavior until explicitly redesigned")

func test_every_tiered_pet_actor_resolves_an_attack_clip() -> void:
	for scene_path in [
		"res://scenes/characters/pets/dps/PetDpsT1Vladimir.tscn",
		"res://scenes/characters/pets/dps/PetDpsT2Gwen.tscn",
		"res://scenes/characters/pets/dps/PetDpsT3Jax.tscn",
		"res://scenes/characters/pets/dps/PetDpsT4Ezreal.tscn",
		"res://scenes/characters/pets/tank/PetTankT1Alistar.tscn",
		"res://scenes/characters/pets/tank/PetTankT2Garen.tscn",
		"res://scenes/characters/pets/tank/PetTankT3Thresh.tscn",
		"res://scenes/characters/pets/tank/PetTankT4Galio.tscn",
		"res://scenes/characters/pets/support/PetSupT1Yuumi.tscn",
		"res://scenes/characters/pets/support/PetSupT2Bard.tscn",
		"res://scenes/characters/pets/support/PetSupT3Janna.tscn",
		"res://scenes/characters/pets/support/PetSupT4Nami.tscn",
	]:
		var actor: CharacterActor = load(scene_path).instantiate()
		add_child_autofree(actor)
		await get_tree().process_frame
		assert_ne(actor.resolve_animation_name("Attack"), "", "%s needs a playable attack clip" % scene_path)
