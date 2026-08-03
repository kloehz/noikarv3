extends GutTest

## Contract coverage for the threat/aggro system. The mob AI now picks
## its target by (sync_threat - distance), so a player who hits first
## holds aggro until their threat decays and a tank pet that hits more
## (or with a multiplier) naturally pulls it back. Threat is written
## by HurtboxComponent on every damage event and decays linearly on
## the server every frame.

const THREAT_DECAY_PER_SECOND: float = 5.0

var _manager: Node3D
var _director: MatchDirector

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	_manager = load("res://common/match_manager.gd").new()
	for container_name in ["Players", "Mobs", "Souls", "Totems"]:
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

func _spawn_tank_pet(owner_id: int, owner_node: Node, pos: Vector3, power_level: int = 1) -> BaseEntity:
	var scene: PackedScene = load("res://scenes/PetEntity.tscn")
	var pet: BaseEntity = scene.instantiate() as BaseEntity
	pet.name = "PET_%d" % owner_id
	pet.owner_id = owner_id
	_manager.get_node("Totems").add_child(pet, true)
	await get_tree().process_frame
	pet.global_position = pos
	await get_tree().process_frame
	pet.setup_pet(owner_id, "TANK", power_level)
	await get_tree().process_frame
	return pet

func _damage(mob: Node, source: Node, amount: int) -> void:
	var hurtbox: HurtboxComponent = mob.get_node("HurtboxComponent") as HurtboxComponent
	hurtbox.receive_hit_data(amount, source)
	await get_tree().process_frame

func _ai(mob: Node) -> Node:
	return mob.get_node("AIComponent")

func test_player_damage_writes_threat_to_attacker() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	assert_eq(int(player.get_node("ServerState").sync_threat), 0,
		"Player starts with zero threat")
	await _damage(mob, player, 50)
	assert_eq(int(player.get_node("ServerState").sync_threat), 50,
		"A 50-damage hit writes 50 threat to the attacker's ServerState")

func test_non_tank_pets_write_threat_at_one_x() -> void:
	## Damage from a non-tank pet (or any non-TANK source) uses 1.0x.
	var owner := await _spawn_player(2, Vector3(0, 0, 0))
	var scene: PackedScene = load("res://scenes/PetEntity.tscn")
	var pet: BaseEntity = scene.instantiate() as BaseEntity
	pet.name = "PET_2"
	pet.owner_id = 2
	_manager.get_node("Totems").add_child(pet, true)
	await get_tree().process_frame
	pet.setup_pet(2, "ATTACK", 1)
	await get_tree().process_frame
	var mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	await _damage(mob, pet, 20)
	assert_eq(int(pet.get_node("ServerState").sync_threat), 20,
		"ATTACK pet damage writes 1.0x threat to itself")

func test_tank_pet_writes_threat_at_base_multiplier() -> void:
	var owner := await _spawn_player(2, Vector3(0, 0, 0))
	var pet := await _spawn_tank_pet(2, owner, Vector3(2, 0, 0), 0)
	var mob := await _spawn_mob("AATROX", Vector3(5, 0, 0))
	await _damage(mob, pet, 10)
	# TANK base multiplier is 1.75; level-0 has no bonus.
	assert_eq(int(pet.get_node("ServerState").sync_threat), int(10 * 1.75),
		"TANK pet at level 0 writes 1.75x threat per damage")

func test_higher_level_tank_writes_more_threat_per_damage() -> void:
	var owner := await _spawn_player(2, Vector3(0, 0, 0))
	var pet_l1 := await _spawn_tank_pet(2, owner, Vector3(2, 0, 0), 1)
	var mob := await _spawn_mob("AATROX", Vector3(5, 0, 0))
	await _damage(mob, pet_l1, 10)
	var t_l1: int = int(pet_l1.get_node("ServerState").sync_threat)
	# Per-level bonus is +0.05, so level-1 -> 1.80 multiplier.
	assert_eq(t_l1, int(10 * 1.80),
		"TANK pet at level 1 writes 1.80x threat (1.75 base + 0.05 per level)")

func test_threat_decays_linearly_on_server() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	player.get_node("ServerState").sync_threat = 100
	await get_tree().process_frame
	assert_eq(int(player.get_node("ServerState").sync_threat), 100,
		"Threat untouched on first frame at 60Hz")
	# Manually pump the decay like _process would, since Gut doesn't
	# wait a wall-clock second reliably inside a test.
	player._process(1.0)
	assert_almost_eq(int(player.get_node("ServerState").sync_threat), 95, 0.001,
		"One full second of decay removes ~5 threat (5/sec rate)")

func test_threat_decays_at_real_framerate() -> void:
	## At 60Hz each frame passes delta ≈ 0.016. The accumulator carries
	## the partial decay forward; over a full second of 60Hz ticks it
	## still adds up to the configured 5.0/sec rate even though the
	## per-frame int truncation is zero.
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	player.get_node("ServerState").sync_threat = 100
	# 60 ticks of 1/60 second each, matching what _process sees at 60Hz.
	for _i in 60:
		player._process(1.0 / 60.0)
	# 60 * 5/60 = 5 threat total, give or take the last carry.
	assert_almost_eq(int(player.get_node("ServerState").sync_threat), 95, 1.0,
		"60Hz decay path sums to ~5 threat over a wall-clock second")

func test_threat_does_not_go_negative() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	player.get_node("ServerState").sync_threat = 3
	player._process(10.0)
	assert_eq(int(player.get_node("ServerState").sync_threat), 0,
		"Decay clamps at 0, never negative")

func test_mob_targets_highest_threat_attacker() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var owner := await _spawn_player(3, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(3, owner, Vector3(-5, 0, 0), 0)
	var mob := await _spawn_mob("AATROX", Vector3(2, 0, 0))
	# Damage the mob from BOTH attackers; tank has 1.75x multiplier.
	await _damage(mob, player, 50)
	await _damage(mob, tank, 10)
	# player threat = 50, tank threat = 17.5. Score = threat - distance.
	# Distance to player ~ 2m, distance to tank ~ 7m.
	# player score = 50 - 2 = 48
	# tank score   = 17.5 - 7 = 10.5
	# player wins despite being a tank.
	await get_tree().process_frame
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, player,
		"Mob targets the highest-threat attacker even when a closer tank is around")

func test_tank_pulls_aggro_after_player_stops_hitting() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var owner := await _spawn_player(3, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(3, owner, Vector3(-5, 0, 0), 0)
	var mob := await _spawn_mob("AATROX", Vector3(2, 0, 0))
	await _damage(mob, player, 50)
	await _damage(mob, tank, 10)
	# Wait long enough for player threat to decay below tank threat.
	# Player starts at 50, tank at 17.5. Tank + 10*1.75 = 35 dmg * (1.75 mult) = ?
	# Actually each of these is 17.5. Let me just spam tank hits.
	for _i in 10:
		await _damage(mob, tank, 10)
	# tank threat ~ 10 * 10 * 1.75 = 175 (modulo decay, but instant)
	# player threat = 50, decaying.
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, tank,
		"Tank pet pulls aggro after writing enough threat to outrank the player")

func test_taunt_aoe_writes_flat_threat_spike() -> void:
	var owner := await _spawn_player(3, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(3, owner, Vector3(-5, 0, 0), 0)
	# Add a mob in range so _apply_aoe_taunt has a target to spike against.
	var mob := await _spawn_mob("AATROX", Vector3(-4, 0, 0))
	var before: int = int(tank.get_node("ServerState").sync_threat)
	tank._apply_aoe_taunt(tank.global_position, 8.0)
	var after: int = int(tank.get_node("ServerState").sync_threat)
	assert_eq(after - before, 200,
		"Taunt AoE writes a flat 200-threat spike on the tank so aggro locks")

func test_ai_score_is_threat_minus_distance() -> void:
	## Sanity-check the score formula at the boundary.
	# mob at z=10; close_player at z=8 (distance 2), far_player at z=2 (distance 8).
	var close_player := await _spawn_player(2, Vector3(0, 0, 8))
	var far_player := await _spawn_player(3, Vector3(0, 0, 2))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 10))
	# Equal damage. close_player wins on distance tiebreaker.
	await _damage(mob, close_player, 30)
	await _damage(mob, far_player, 30)
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, close_player,
		"Equal-threat targets fall to the closer one (distance tiebreaker)")

func test_threat_pulls_aggro_beyond_detection_range() -> void:
	## Regression: a long-range attacker used to be ignored by mobs because
	## they sit outside detection_range. With a small threat spike the
	## mob must still aggro on the far player — otherwise ranged classes
	## snipe short-range mobs for free.
	var far_player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 100))  # 100m apart
	# Mob's detection_range is 10m (EnemyEntity.tscn default) so the
	# far player is well outside the natural aggro leash.
	var ai := _ai(mob)
	assert_gt(ai.detection_range, 0)
	assert_gt(mob.global_position.distance_to(far_player.global_position), ai.detection_range,
		"Player sits outside the mob's detection_range (test setup)")
	# Even 1 damage of threat must pull aggro across the whole map.
	await _damage(mob, far_player, 1)
	_ai(mob)._find_nearest_target()
	assert_eq(ai.target, far_player,
		"1 threat from a 100m attacker pulls aggro past the detection_range leash")

func test_threat_holder_outranks_close_idle_attacker() -> void:
	## A far threat source (1 threat at 100m) must outrank a close
	## idle player (0 threat at 2m). Without the threat bypass, the
	## close idle player would win on distance alone and the long-range
	## attacker would never be engaged.
	var close_player := await _spawn_player(2, Vector3(0, 0, 0))
	var far_player := await _spawn_player(3, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 2))  # 2m from close_player
	# 100m from far_player.
	far_player.global_position = Vector3(0, 0, 100)
	await get_tree().process_frame
	await _damage(mob, far_player, 1)
	# close_player has 0 threat. far_player has 1 threat. far_player wins
	# despite being 100m away.
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, far_player,
		"Threat holder outranks close idle attacker regardless of distance")

func test_threat_zero_drops_target_even_when_far() -> void:
	## A target that was held by threat decays out of the leash once
	## its threat hits 0. Verifies the inverse of the pull-beyond-leash
	## rule: the mob chases the threat source, but only as long as the
	## threat is real.
	var far_player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 50))
	far_player.global_position = Vector3(0, 0, 200)
	await get_tree().process_frame
	# Write threat, then verify the mob picks far_player.
	await _damage(mob, far_player, 5)
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, far_player,
		"Mob pulls aggro on far threat source")
	# Now zero the threat (simulating full decay) and re-search.
	far_player.get_node("ServerState").sync_threat = 0
	_ai(mob)._find_nearest_target()
	# With 0 threat, the far player is beyond detection_range and no
	# longer a valid candidate. The mob should drop the target.
	assert_null(_ai(mob).target,
		"Threat = 0 + beyond leash = no target, mob waits for a closer attacker")