extends GutTest

## Contract coverage for pet ally exclusion across every damage path.
## Pets must be completely invisible to other pets' attacks: no melee
## damage, no projectile damage, no AoE stun, no AoE taunt. This
## extends the threat/aggro system so pet roles compose cleanly without
## accidentally turning pets into friendly fire hazards.

var _manager: Node3D
var _director: MatchDirector

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_manager = load("res://common/match_manager.gd").new()
	for container_name in ["Players", "Mobs", "Souls", "Totems", "Projectiles"]:
		var container := Node3D.new()
		container.name = container_name
		_manager.add_child(container)
	var state := MatchState.new()
	state.name = "MatchState"
	_manager.add_child(state)
	_director = MatchDirector.new()
	_director.rules = load("res://common/resources/default_match_rules.tres")
	_director.match_state = state
	_manager.add_child(_director)
	add_child_autofree(_manager)
	NetworkTime.after_tick.disconnect(_director._on_after_tick)
	await get_tree().process_frame

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _spawn_player(peer_id: int, pos: Vector3) -> Node3D:
	var scene: PackedScene = load("res://scenes/BaseEntity.tscn")
	var player: BaseEntity = scene.instantiate() as BaseEntity
	player.name = str(peer_id)
	_manager.get_node("Players").add_child(player, true)
	await get_tree().process_frame
	player.global_position = pos
	await get_tree().process_frame
	return player

func _spawn_mob(enemy_type: String, pos: Vector3, team: int = TeamId.RED) -> Node:
	var mob: Node = _manager._spawn_named_enemy(enemy_type, pos, "MOB_", 1.0, 0.0, team)
	await get_tree().process_frame
	return mob

func _spawn_tank_pet(owner_id: int, pos: Vector3, power_level: int = 0, spawn_grace_duration: float = 0.0) -> BaseEntity:
	var scene: PackedScene = load("res://scenes/PetEntity.tscn")
	var pet: BaseEntity = scene.instantiate() as BaseEntity
	pet.name = "PET_%d" % owner_id
	pet.owner_id = owner_id
	pet.spawn_grace_duration = spawn_grace_duration
	_manager.get_node("Totems").add_child(pet, true)
	await get_tree().process_frame
	pet.global_position = pos
	await get_tree().process_frame
	pet.setup_pet(owner_id, "TANK", power_level)
	await get_tree().process_frame
	return pet

func _spawn_pet_at(owner_id: int, pos: Vector3, pet_type: String) -> BaseEntity:
	var scene: PackedScene = load("res://scenes/PetEntity.tscn")
	var pet: BaseEntity = scene.instantiate() as BaseEntity
	pet.name = "PET_%d_%s" % [owner_id, pet_type]
	pet.owner_id = owner_id
	_manager.get_node("Totems").add_child(pet, true)
	await get_tree().process_frame
	pet.global_position = pos
	await get_tree().process_frame
	pet.setup_pet(owner_id, pet_type, 1)
	await get_tree().process_frame
	return pet

func test_pet_flanks_nearby_allies_instead_of_stacking() -> void:
	var rear_pet := await _spawn_tank_pet(2, Vector3.ZERO)
	await _spawn_tank_pet(3, Vector3(-0.6, 0, -1.2))
	await _spawn_tank_pet(4, Vector3(0.6, 0, -1.2))
	var ai: Node = rear_pet.get_node("AIComponent")
	var steering: Vector3 = ai._steer_around_nearby_allies(Vector3.FORWARD)
	assert_gt(absf(steering.x), 0.01,
		"A pet blocked by allied pets must choose a lateral flank path")
	assert_lt(steering.z, 0.0,
		"Pet flanking must still make progress toward the target")

func test_damaged_pet_chases_the_attacking_mob() -> void:
	var pet := await _spawn_tank_pet(2, Vector3.ZERO)
	var mob := await _spawn_mob("AATROX", Vector3(20, 0, 0))
	var hurtbox: HurtboxComponent = pet.get_node("HurtboxComponent") as HurtboxComponent
	hurtbox.receive_hit_data(1, mob)
	var ai: Node = pet.get_node("AIComponent")
	assert_eq(ai.target, mob, "A damaged pet immediately targets its attacking mob")
	assert_eq(ai.state, 2, # AIComponent.State.CHASE
		"A damaged pet leaves follow/idle state to counterattack")
	assert_gt(int(pet.get_node("ServerState").sync_threat_table.get(mob.name, 0)), 0,
		"The attacker is retained as reactive threat beyond the pet sight range")

## Spawn grace must cover direct damage too: collision disabling alone does
## not protect against AoE helpers that call HurtboxComponent directly.
func test_pet_spawn_grace_blocks_direct_damage() -> void:
	var pet := await _spawn_tank_pet(2, Vector3.ZERO, 0, 1.0)
	var health: HealthComponent = pet.get_node("HealthComponent") as HealthComponent
	var hp_before := health.current_health
	var hurtbox: HurtboxComponent = pet.get_node("HurtboxComponent") as HurtboxComponent
	hurtbox.receive_hit_data(hp_before, null)
	assert_eq(health.current_health, hp_before,
		"A pet is immune to direct damage during summon grace")

## Melee: pet tanks never deal damage to other pets even at point blank.
func test_pet_melee_does_not_damage_other_pets() -> void:
	var owner_a := await _spawn_player(2, Vector3(-5, 0, 0))
	var owner_b := await _spawn_player(3, Vector3(5, 0, 0))
	var tank_a := await _spawn_tank_pet(2, Vector3(0, 0, 0), 0)
	var tank_b := await _spawn_tank_pet(3, Vector3(0.5, 0, 0), 0)
	var hp_a_before: int = int(tank_a.get_node("HealthComponent").current_health)
	var hp_b_before: int = int(tank_b.get_node("HealthComponent").current_health)
	# Drive melee via the CombatComponent the way the production attack does.
	var combat: Node = tank_a.get_node("CombatComponent")
	combat.sync_attack_count += 1
	# We need the attack to actually fire a hit check, so wait for the
	# AI / CombatComponent to find a target in range. The simplest
	# shortcut is the public _handle_hit path used by the shapecast.
	var hurtbox_b: HurtboxComponent = tank_b.get_node("HurtboxComponent") as HurtboxComponent
	combat._handle_hit(tank_b, 100, 0)
	await get_tree().process_frame
	assert_eq(int(tank_b.get_node("HealthComponent").current_health), hp_b_before,
		"Tank pet A's melee against tank pet B does 0 damage (ally exclusion)")
	assert_eq(int(tank_a.get_node("HealthComponent").current_health), hp_a_before,
		"Tank pet A is untouched by its own attack animation")

## Projectile: pet projectiles never damage other pets, even cross-team.
func test_pet_projectile_does_not_damage_other_pets() -> void:
	var owner_a := await _spawn_player(2, Vector3(-5, 0, 0))
	var owner_b := await _spawn_player(3, Vector3(5, 0, 0))
	var tank_a := await _spawn_tank_pet(2, Vector3(-3, 0, 0), 0)
	var dmg_pet := await _spawn_pet_at(3, Vector3(-2, 0, 0), "ATTACK")
	# Build a projectile owned by tank_a heading toward dmg_pet.
	var proj_scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	var proj: ProjectileEntity = proj_scene.instantiate() as ProjectileEntity
	_manager.get_node("Projectiles").add_child(proj, true)
	await get_tree().process_frame
	proj.initialize(Vector3.RIGHT, 10.0, 100.0, tank_a.owner_id, 0.0, tank_a)
	proj.global_position = tank_a.global_position
	await get_tree().process_frame
	# Manually pump _try_hit against the dmg_pet's hurtbox (simulating
	# the projectile having reached the target).
	var hurtbox: HurtboxComponent = dmg_pet.get_node("HurtboxComponent") as HurtboxComponent
	var hp_before: int = int(dmg_pet.get_node("HealthComponent").current_health)
	var hit: bool = proj._try_hit(dmg_pet)
	await get_tree().process_frame
	assert_false(hit, "Projectile fired by tank A reports no valid hit on pet B")
	assert_eq(int(dmg_pet.get_node("HealthComponent").current_health), hp_before,
		"Cross-team pet projectile did not damage the other pet")

## Enemy projectiles must damage pets when their body collider is hit first.
func test_mob_projectile_damages_pet() -> void:
	var pet := await _spawn_tank_pet(2, Vector3.ZERO)
	var mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	var proj_scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	var proj: ProjectileEntity = proj_scene.instantiate() as ProjectileEntity
	_manager.get_node("Projectiles").add_child(proj, true)
	await get_tree().process_frame
	proj.initialize(Vector3.LEFT, 10.0, 100.0, -1, 0.0, mob)
	var health: HealthComponent = pet.get_node("HealthComponent") as HealthComponent
	var hp_before: int = health.current_health

	assert_true(proj._try_hit(pet), "Mob projectile registers a pet body collision as a valid hit")
	assert_eq(health.current_health, hp_before - 100,
		"Mob projectile applies damage to the pet's HurtboxComponent")

## AoE stun: tank pet's stun never lands on any pet.
func test_pet_aoe_stun_skips_pets() -> void:
	var owner := await _spawn_player(2, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(2, Vector3(0, 0, 0), 0)
	var friend_pet := await _spawn_pet_at(2, Vector3(0.5, 0, 0), "HEAL")
	var enemy_pet := await _spawn_pet_at(3, Vector3(-0.5, 0, 0), "ATTACK")
	# Stun both pets directly. Without the filter, both would have
	# is_stunned == true afterwards.
	tank._apply_aoe_stun(tank.global_position, 8.0, 1.5)
	await get_tree().process_frame
	assert_false(bool(friend_pet.get_node("ServerState").is_stunned),
		"Same-team pet is not stunned by tank's AoE stun")
	assert_false(bool(enemy_pet.get_node("ServerState").is_stunned),
		"Enemy-team pet is not stunned by tank's AoE stun (cross-team invisibility)")

## AoE taunt: tank pet's taunt never redirects any pet's AI target.
func test_pet_aoe_taunt_skips_pets() -> void:
	var owner := await _spawn_player(2, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(2, Vector3(0, 0, 0), 0)
	var mob := await _spawn_mob("AATROX", Vector3(0.5, 0, 0))
	var friend_pet := await _spawn_pet_at(2, Vector3(-0.5, 0, 0), "HEAL")
	var enemy_pet := await _spawn_pet_at(3, Vector3(0.7, 0, 0), "ATTACK")
	# Capture each AI's current target so we can verify it doesn't flip
	# to the tank after taunt.
	var mob_ai_target_before: Node = mob.get_node("AIComponent").target
	tank._apply_aoe_taunt(tank.global_position, 8.0)
	await get_tree().process_frame
	# Mob AI redirected to the tank (the whole point of the taunt).
	assert_eq(mob.get_node("AIComponent").target, tank,
		"Mob AI redirects to the tank on taunt")
	# Pets' AI must NOT be touched. friendly pet: never had a target; enemy
	# pet: had a target (or null), still doesn't point at the tank.
	var friend_target: Node = friend_pet.get_node("AIComponent").target
	var enemy_target: Node = enemy_pet.get_node("AIComponent").target
	assert_ne(friend_target, tank,
		"Friendly pet AI is not redirected by enemy tank's taunt")
	assert_ne(enemy_target, tank,
		"Enemy pet AI is not redirected by ally tank's taunt")
