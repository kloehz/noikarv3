extends GutTest

## Contract coverage for the per-enemy AttackDefinition data. Verifies that
## every enemy CharacterSpec declares a primary_attack so
## CombatComponent.configure() actually wires a melee hitscan or ranged
## projectile attack instead of falling back to the legacy zero-damage path.
## Specs are loaded straight from CharacterSpecRegistry — no actor scenes
## (and no .glb models) are instantiated here, same as the headless server.

func _primary_attack_for(scene_path: String) -> AttackDefinition:
	var spec := CharacterSpecRegistry.load_for(scene_path)
	assert_not_null(spec, "%s must have a registered CharacterSpec" % scene_path)
	var attack := spec.primary_attack
	assert_not_null(attack, "%s spec must declare a primary_attack AttackDefinition" % scene_path)
	return attack

func test_hecarim_tank_melee_hitscan_attack() -> void:
	var attack := _primary_attack_for("res://scenes/characters/HecarimTank.tscn")
	assert_eq(attack.attack_type, AttackDefinition.AttackType.MELEE_HITSCAN)
	assert_not_null(attack.shape_data, "melee attack needs shape_data")
	# Hecarim matches the Aatrox default melee profile: small forward arc.
	assert_gte(attack.shape_data.radius, 0.5,
		"melee radius must reach at least 0.5m so it overlaps the mob's own collider")
	assert_gte(attack.base_damage, 15.0)
	assert_gte(attack.knockback_force, 10.0, "tank should push targets around")

func test_ivern_ranger_ranged_projectile_attack() -> void:
	var attack := _primary_attack_for("res://scenes/characters/IvernRanger.tscn")
	assert_eq(attack.attack_type, AttackDefinition.AttackType.PROJECTILE)
	assert_not_null(attack.projectile_scene, "ranged attack needs a projectile scene")
	assert_gte(attack.projectile_speed, 15.0)
	assert_gte(attack.base_damage, 15.0)
	# PROJECTILE attacks don't use shape_data; the projectile scene handles
	# its own collision shape via the CharacterBody3D inside it.

func test_ivern_heal_ranged_projectile_attack() -> void:
	# Healer needs SOMETHING for self-defense; ranged projectile is the cheapest
	# fit. Damage should be lower than a dedicated DPS spec.
	var attack := _primary_attack_for("res://scenes/characters/IvernHeal.tscn")
	assert_eq(attack.attack_type, AttackDefinition.AttackType.PROJECTILE)
	assert_not_null(attack.projectile_scene)
	assert_lt(attack.base_damage, 18.0,
		"healer should deal below-average damage so the role stays utility-focused")

func test_kogmaw_dmg_ranged_projectile_attack() -> void:
	# Pure DPS — highest ranged damage of the team.
	var attack := _primary_attack_for("res://scenes/characters/KogMawDmg.tscn")
	assert_eq(attack.attack_type, AttackDefinition.AttackType.PROJECTILE)
	assert_not_null(attack.projectile_scene)
	assert_gte(attack.base_damage, 18.0)

func test_ezreal_pet_projectile_compensates_for_its_raised_weapon_socket() -> void:
	var attack := _primary_attack_for("res://scenes/characters/pets/dps/PetDpsT4Ezreal.tscn")
	assert_eq(attack.attack_type, AttackDefinition.AttackType.PROJECTILE)
	assert_almost_eq(attack.projectile_height_offset, -1.5, 0.001)

func _actor_attack_range_for(scene_path: String) -> float:
	var spec := CharacterSpecRegistry.load_for(scene_path)
	assert_not_null(spec, "%s must have a registered CharacterSpec" % scene_path)
	return spec.suggested_attack_range

func test_ranged_enemies_have_tripled_attack_range() -> void:
	# Both Ivern variants and KogMaw should fire from long range so the
	# player can't close distance for free. We required 3x the melee default
	# (2.5 m -> 7.5 m) so ranged AI trades chasing for kiting.
	const RANGED_FLOOR: float = 7.0
	for path in [
		"res://scenes/characters/IvernRanger.tscn",
		"res://scenes/characters/IvernHeal.tscn",
		"res://scenes/characters/KogMawDmg.tscn",
	]:
		var atk_range: float = _actor_attack_range_for(path)
		assert_gte(atk_range, RANGED_FLOOR,
			"%s attack_range %.2f must be >= %.2f" % [path, atk_range, RANGED_FLOOR])

func test_atrox_boss_melee_cleave() -> void:
	var attack := _primary_attack_for("res://scenes/characters/Aatrox.tscn")
	assert_eq(attack.attack_type, AttackDefinition.AttackType.MELEE_HITSCAN)
	assert_not_null(attack.shape_data, "boss melee needs a configured shape")
	# Aatrox uses the default melee profile (small forward arc) — bigger
	# spheres made the boss hit targets well outside its visual silhouette.
	assert_gte(attack.shape_data.radius, 0.5,
		"melee radius must reach at least 0.5m so it overlaps the boss's own collider")
	assert_gte(attack.base_damage, 30.0,
		"Boss should hit harder than regular mobs")
	assert_gte(attack.knockback_force, 15.0)

func test_every_enemy_scene_declares_primary_attack() -> void:
	# Single-source-of-truth check: if any future enemy scene ships without
	# primary_attack, this test fails and forces the author to wire combat.
	var paths := [
		"res://scenes/characters/Aatrox.tscn",
		"res://scenes/characters/HecarimTank.tscn",
		"res://scenes/characters/IvernHeal.tscn",
		"res://scenes/characters/IvernRanger.tscn",
		"res://scenes/characters/KogMawDmg.tscn",
	]
	for path in paths:
		var attack := _primary_attack_for(path)
		assert_not_null(attack,
			"%s is missing primary_attack; CombatComponent would fall back to zero-damage legacy path" % path)
		assert_ne(attack.attack_type, -1, "%s has uninitialized attack_type" % path)
		if attack.attack_type == AttackDefinition.AttackType.MELEE_HITSCAN:
			assert_not_null(attack.shape_data, "%s melee attack has no shape_data" % path)
		elif attack.attack_type == AttackDefinition.AttackType.PROJECTILE:
			assert_not_null(attack.projectile_scene, "%s projectile attack has no scene" % path)

func test_every_registered_spec_loads_with_primary_attack() -> void:
	# The headless server loads specs without actor scenes, so every registry
	# entry must resolve to a spec that fully describes the character's combat.
	for actor_path in CharacterSpecRegistry.SPEC_BY_ACTOR_PATH:
		var spec := CharacterSpecRegistry.load_for(actor_path)
		assert_not_null(spec, "spec for %s must load" % actor_path)
		assert_not_null(spec.primary_attack, "spec for %s needs a primary_attack" % actor_path)

func test_actor_scenes_reference_their_registered_spec() -> void:
	# Single-source guard: the visual actor scene and the registry must point
	# at the same .tres, otherwise server and client could read diverging data.
	for actor_path in CharacterSpecRegistry.SPEC_BY_ACTOR_PATH:
		var scene: PackedScene = load(actor_path)
		assert_not_null(scene, "%s must load" % actor_path)
		var actor: CharacterActor = scene.instantiate()
		add_child_autofree(actor)
		assert_not_null(actor.spec, "%s actor must reference a spec" % actor_path)
		assert_eq(actor.spec.resource_path, CharacterSpecRegistry.spec_path_for(actor_path),
			"%s actor spec must match the registry entry" % actor_path)
