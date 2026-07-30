extends GutTest

## Contract coverage for the per-enemy AttackDefinition exports. Verifies
## that every enemy character scene declares a primary_attack so
## CombatComponent.configure() actually wires a melee hitscan or ranged
## projectile attack instead of falling back to the legacy zero-damage path.

func _primary_attack_for(scene_path: String) -> AttackDefinition:
	var scene: PackedScene = load(scene_path)
	var actor: CharacterActor = scene.instantiate()
	add_child_autofree(actor)
	var attack := actor.primary_attack
	assert_not_null(attack, "%s must declare a primary_attack AttackDefinition" % scene_path)
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
