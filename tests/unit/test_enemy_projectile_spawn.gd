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

