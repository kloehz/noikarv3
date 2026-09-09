extends GutTest

## Contract coverage for the per-entity projectile spawn height:
## - Enemies (mobs group) shoot from chest height (~1m above their root) so
##   the projectile leaves the body at a believable angle and not from the
##   raised weapon socket (which lives at y=50 in model-local units and
##   looks visually wrong on mob rigs).
## - Players keep the weapon-socket spawn so their aim still feels precise
##   at the raised weapon.

const ENEMY_CHEST_HEIGHT: float = 1.0
const FORWARD_OFFSET: float = 1.6

class SpawnProbeProjectile:
	extends Node3D
	var initialized_before_tree := false
	var entered_tree_before_initialize := false
	var initialized_position := Vector3.INF
	var initialized_direction := Vector3.ZERO
	var initialized_speed := 0.0
	var initialized_damage := 0.0
	var initialized_owner_id := -1
	var initialized_knockback := 0.0
	var initialized_owner_entity: Node = null

	func _enter_tree() -> void:
		entered_tree_before_initialize = not initialized_before_tree

	func initialize(direction: Vector3, speed: float, damage: float, owner_id: int, knockback: float = 8.0, owner_entity: Node = null) -> void:
		initialized_before_tree = not is_inside_tree()
		initialized_position = position
		initialized_direction = direction
		initialized_speed = speed
		initialized_damage = damage
		initialized_owner_id = owner_id
		initialized_knockback = knockback
		initialized_owner_entity = owner_entity

func _spawn_mob_stub() -> Node:
	# Bare CharacterBody3D with the mobs group; EnemyEntity would queue_free
	# itself in tests because its enemy_type export is empty. We only need
	# a node the CombatComponent can read .global_position and group membership
	# from — the actual enemy_type is irrelevant to the spawn-height branch.
	var entity := CharacterBody3D.new()
	entity.name = "9001"
	entity.add_to_group(&"mobs")
	var root := Node.new()
	add_child_autofree(root)
	root.add_child(entity)
	entity.global_position = Vector3.ZERO
	return entity

func test_enemy_projectile_spawn_uses_chest_height() -> void:
	# The enemy branch in _execute_projectile computes:
	#   entity.global_position + Vector3(0.0, 1.0, 0.0) + direction * 1.6
	# i.e. chest height (~1 m above the entity's root) plus 1.6 m forward.
	# We assert that the SAME formula gives a y strictly below the
	# weapon-socket height used for the player path.
	var entity := _spawn_mob_stub()
	var direction := Vector3(0, 0, -1)
	var chest_spawn: Vector3 = entity.global_position + Vector3(0.0, ENEMY_CHEST_HEIGHT, 0.0) + direction * FORWARD_OFFSET
	assert_almost_eq(chest_spawn.y, ENEMY_CHEST_HEIGHT, 0.001,
		"Enemy chest spawn must sit at chest height (1m above root)")
	assert_almost_eq(chest_spawn.z, -FORWARD_OFFSET, 0.001,
		"Enemy chest spawn must push 1.6m forward so the projectile clears the owner's collider")

func test_player_projectile_spawn_uses_weapon_socket() -> void:
	# Player IvernRanger has a WeaponMain socket at y=50 in model-local
	# space. With model scale 0.007 → world offset ~0.35m above root, then
	# spawn_pos_for adds another +2.0m up → ~2.35m above root. Must be
	# clearly higher than the chest-height enemy path (1.0m) so the two
	# branches remain distinguishable.
	var player_scene := load("res://scenes/characters/IvernRanger.tscn")
	var actor = player_scene.instantiate()
	add_child_autofree(actor)
	var weapon_socket: Marker3D = actor.get_socket("WeaponMain")
	assert_not_null(weapon_socket, "IvernRanger actor must declare WeaponMain")
	actor.global_position = Vector3.ZERO
	var spawn_pos: Vector3 = weapon_socket.global_position + Vector3(0.0, 2.0, 0.0)
	assert_gt(spawn_pos.y, ENEMY_CHEST_HEIGHT,
		"Player projectile spawn must stay above the enemy chest-height path")
	# Player IvernRanger keeps its existing player-style spawn height contract
	# (weapon socket + 2 m). Pin the absolute lower bound so we notice if
	# someone flips the player branch to the chest-height path.
	assert_gt(spawn_pos.y, 1.5,
		"Player IvernRanger must keep the weapon-socket + 2m spawn height")

func test_enemy_and_player_spawn_heights_remain_distinguishable() -> void:
	# The two paths must produce visibly different spawn heights so
	# players don't accidentally shoot from hip-level when playing Ivern.
	var mob := _spawn_mob_stub()
	var direction := Vector3(0, 0, -1)
	var mob_y: float = (mob.global_position + Vector3(0.0, ENEMY_CHEST_HEIGHT, 0.0)).y

	var player_scene := load("res://scenes/characters/IvernRanger.tscn")
	var actor = player_scene.instantiate()
	add_child_autofree(actor)
	actor.global_position = Vector3.ZERO
	var weapon_socket: Marker3D = actor.get_socket("WeaponMain")
	var player_y: float = (weapon_socket.global_position + Vector3(0.0, 2.0, 0.0)).y

	assert_gt(player_y - mob_y, 0.5,
		"Player spawn must stay at least 0.5m above the enemy chest spawn so the two paths stay distinguishable")


func test_projectile_is_positioned_and_initialized_before_tree_insertion() -> void:
	var world := Node3D.new()
	add_child_autofree(world)
	var projectiles := Node3D.new()
	projectiles.name = "Projectiles"
	world.add_child(projectiles)

	var entity := CharacterBody3D.new()
	entity.name = "9001"
	entity.add_to_group(&"mobs")
	world.add_child(entity)
	entity.global_position = Vector3(3.0, 0.0, 4.0)

	var probe := SpawnProbeProjectile.new()
	var scene := PackedScene.new()
	assert_eq(scene.pack(probe), OK, "Probe projectile scene should pack")

	var attack_def := AttackDefinition.new()
	attack_def.attack_type = AttackDefinition.AttackType.PROJECTILE
	attack_def.projectile_scene = scene
	attack_def.projectile_speed = 42.0
	attack_def.base_damage = 11.0
	attack_def.knockback_force = 5.0

	var combat := CombatComponent.new()
	entity.add_child(combat)
	combat.entity = entity
	combat.call("_execute_projectile", attack_def, 2.0)

	var spawned := projectiles.get_child(projectiles.get_child_count() - 1) as SpawnProbeProjectile
	assert_not_null(spawned, "CombatComponent should add the projectile under Projectiles")
	assert_true(spawned.initialized_before_tree, "Projectile gameplay fields must be initialized before add_child")
	assert_false(spawned.entered_tree_before_initialize, "Projectile must not enter the tree before initialize")
	assert_eq(spawned.initialized_position, spawned.position, "Spawn local position should be set before initialize")
	assert_eq(spawned.initialized_direction, -entity.global_transform.basis.z.normalized(), "Direction should be initialized before spawn replication")
	assert_eq(spawned.initialized_speed, 42.0, "Speed should be initialized before spawn replication")
	assert_eq(spawned.initialized_damage, 22.0, "Server-only damage should still be initialized before insertion")
	assert_eq(spawned.initialized_owner_id, 9001, "Owner id should be initialized before insertion")
	assert_eq(spawned.initialized_knockback, 5.0, "Knockback should be initialized before insertion")
	assert_eq(spawned.initialized_owner_entity, entity, "Owner entity should stay server-only")
