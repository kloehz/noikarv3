extends GutTest

## Contract coverage for the threat/aggro system. Threat is per-mob: each
## mob keeps its own attacker -> threat table and reads from it when
## picking a target. This means only the mobs that actually took damage
## from a player aggro on that player — the rest of the wave keeps
## doing whatever they were doing. Tank pets naturally pull aggro on
## each mob they hit because their damage writes 1.75x + 0.05 per
## power_level onto the mob's table.

const THREAT_DECAY_PER_SECOND: float = 5.0

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

func _spawn_tank_pet(owner_id: int, owner_node: Node, pos: Vector3, power_level: int = 0) -> Node:
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

func _threat_of(mob: Node, attacker_name: String) -> int:
	return int(mob.get_node("ServerState").sync_threat_table.get(attacker_name, 0))

## Sanity: damage is written to the VICTIM's table, not the attacker's.
func test_damage_writes_threat_to_victim_table() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	await _damage(mob, player, 50)
	assert_eq(_threat_of(mob, "2"), 50,
		"Mob's table has 50 threat under attacker name '2'")
	# Attacker's own table stays empty (threat lives on the victim now).
	assert_eq(int(player.get_node("ServerState").sync_threat_table.size()), 0,
		"Attacker's own threat table stays empty — threat is per-victim")

func test_non_tank_pet_writes_one_x_threat() -> void:
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
	assert_eq(_threat_of(mob, "PET_2"), 20,
		"ATTACK pet damage writes 1.0x threat to the mob's table")

func test_tank_pet_writes_base_multiplier_threat() -> void:
	var owner := await _spawn_player(2, Vector3(0, 0, 0))
	var pet := await _spawn_tank_pet(2, owner, Vector3(2, 0, 0), 0)
	var mob := await _spawn_mob("AATROX", Vector3(5, 0, 0))
	await _damage(mob, pet, 10)
	# TANK base multiplier is 1.75; level-0 has no bonus.
	assert_eq(_threat_of(mob, "PET_2"), int(10 * 1.75),
		"TANK pet at level 0 writes 1.75x threat to the mob's table")

func test_higher_level_tank_writes_more_threat_per_damage() -> void:
	var owner := await _spawn_player(2, Vector3(0, 0, 0))
	var pet_l1 := await _spawn_tank_pet(2, owner, Vector3(2, 0, 0), 1)
	var mob := await _spawn_mob("AATROX", Vector3(5, 0, 0))
	await _damage(mob, pet_l1, 10)
	# Per-level bonus is +0.05, so level-1 -> 1.80 multiplier.
	assert_eq(_threat_of(mob, "PET_2"), int(10 * 1.80),
		"TANK pet at level 1 writes 1.80x threat (1.75 base + 0.05 per level)")

func test_threat_decays_linearly_on_server() -> void:
	# Per-mob threat lives on a Dictionary. We poke a single entry
	# directly to bypass the server-only writer; the decay path
	# doesn't care about the source, only the table entries.
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var state := player.get_node("ServerState")
	state.sync_threat_table["2"] = 100
	await get_tree().process_frame
	assert_eq(int(state.sync_threat_table.get("2", 0)), 100,
		"Threat untouched on first frame at 60Hz")
	player._process(1.0)
	assert_almost_eq(int(state.sync_threat_table.get("2", 0)), 95, 0.001,
		"One full second of decay removes ~5 threat (5/sec rate)")

func test_threat_decays_at_real_framerate() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var state := player.get_node("ServerState")
	state.sync_threat_table["2"] = 100
	for _i in 60:
		player._process(1.0 / 60.0)
	assert_almost_eq(int(state.sync_threat_table.get("2", 0)), 95, 1.0,
		"60Hz decay path sums to ~5 threat over a wall-clock second")

func test_threat_does_not_go_negative() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var state := player.get_node("ServerState")
	state.sync_threat_table["2"] = 3
	player._process(10.0)
	assert_eq(int(state.sync_threat_table.get("2", 0)), 0,
		"Decay clamps at 0, never negative")

func test_zero_entries_are_erased_from_table() -> void:
	# Prevents the table from growing unbounded over a long match.
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var state := player.get_node("ServerState")
	state.sync_threat_table["2"] = 3
	state.sync_threat_table["5"] = 10
	player._process(10.0)
	assert_eq(state.sync_threat_table.size(), 0,
		"All zero entries are erased after decay brings them down")

## THE BUG FIX: hitting one mob does NOT aggro the rest of the wave.
## Each mob has its own table. Other mobs that weren't hit see no
## threat on the attacker and don't switch to chase them.
func test_hitting_one_mob_does_not_aggro_the_whole_wave() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	# Two mobs in the same area. Only the one we hit should aggro.
	var hit_mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	var bystander_mob := await _spawn_mob("AATROX", Vector3(4, 0, 0))
	await _damage(hit_mob, player, 50)
	# Hit mob's table knows about the player; bystander mob's table does
	# not — even though they're standing next to each other.
	assert_eq(_threat_of(hit_mob, "2"), 50,
		"Hit mob has the attacker in its threat table")
	assert_eq(_threat_of(bystander_mob, "2"), 0,
		"Bystander mob has no entry for the attacker")
	# _find_nearest_target runs on each mob independently.
	_ai(hit_mob)._find_nearest_target()
	_ai(bystander_mob)._find_nearest_target()
	assert_eq(_ai(hit_mob).target, player,
		"Hit mob aggroes on the player")
	assert_ne(_ai(bystander_mob).target, player,
		"Bystander mob does NOT aggro on the player")

func test_damage_acquires_mob_target_on_regular_ai_tick() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	await _damage(mob, player, 1)
	var ai := _ai(mob)
	ai.tick(0.2)
	assert_eq(ai.target, player,
		"A damaged mob acquires its attacker during the normal AI tick")
	assert_eq(ai.state, 2, "A damaged mob transitions from idle to chase")

func test_pet_acquires_mob_target_on_regular_ai_tick() -> void:
	var owner := await _spawn_player(2, Vector3(0, 0, 0))
	var pet := await _spawn_tank_pet(2, owner, Vector3(2, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(4, 0, 0))
	await _damage(mob, pet, 1)
	var pet_ai := _ai(pet)
	pet_ai.tick(0.2)
	assert_eq(pet_ai.target, mob,
		"A pet that damages a mob keeps it as its regular AI target")
	assert_eq(pet_ai.state, 2, "A pet with a mob target transitions to chase")

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
	for _i in 10:
		await _damage(mob, tank, 10)
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, tank,
		"Tank pet pulls aggro after writing enough threat to outrank the player")

func test_active_mob_retargets_when_an_attacker_overtakes_threat() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var owner := await _spawn_player(3, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(3, owner, Vector3(-5, 0, 0), 0)
	var mob := await _spawn_mob("AATROX", Vector3(2, 0, 0))
	var ai := _ai(mob)
	await _damage(mob, player, 50)
	ai._find_nearest_target()
	assert_eq(ai.target, player, "Mob initially targets the player")
	for _i in 10:
		await _damage(mob, tank, 10)
	ai.state = 2 # AIComponent.State.CHASE
	ai._target_search_timer = 0.0
	ai._logic_chase()
	assert_eq(ai.target, tank,
		"A mob already chasing a player switches once the tank overtakes threat")

func test_taunt_aoe_writes_flat_threat_spike_per_mob() -> void:
	var owner := await _spawn_player(3, Vector3(-5, 0, 0))
	var tank := await _spawn_tank_pet(3, owner, Vector3(-5, 0, 0), 0)
	# Two mobs in the taunt radius. Both should get the spike.
	var mob_a := await _spawn_mob("AATROX", Vector3(-4, 0, 0))
	var mob_b := await _spawn_mob("AATROX", Vector3(-3, 0, 0))
	tank._apply_aoe_taunt(tank.global_position, 8.0)
	await get_tree().process_frame
	assert_eq(_threat_of(mob_a, "PET_3"), 200,
		"First mob's table got the +200 taunt spike under the tank's name")
	assert_eq(_threat_of(mob_b, "PET_3"), 200,
		"Second mob's table got the same +200 taunt spike")

func test_ai_score_is_threat_minus_distance() -> void:
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
	# A long-range attacker used to be ignored because they sat outside
	# detection_range. With a small threat spike the mob must still
	# aggro on the far player — otherwise ranged classes snipe
	# short-range mobs for free.
	var far_player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 100))
	var ai := _ai(mob)
	assert_gt(ai.detection_range, 0)
	assert_gt(mob.global_position.distance_to(far_player.global_position), ai.detection_range,
		"Player sits outside the mob's detection_range (test setup)")
	await _damage(mob, far_player, 1)
	_ai(mob)._find_nearest_target()
	assert_eq(ai.target, far_player,
		"1 threat from a 100m attacker pulls aggro past the detection_range leash")

func test_threat_holder_outranks_close_idle_attacker() -> void:
	var close_player := await _spawn_player(2, Vector3(0, 0, 0))
	var far_player := await _spawn_player(3, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 2))
	far_player.global_position = Vector3(0, 0, 100)
	await get_tree().process_frame
	await _damage(mob, far_player, 1)
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, far_player,
		"Threat holder outranks close idle attacker regardless of distance")

func test_threat_zero_drops_target_even_when_far() -> void:
	var far_player := await _spawn_player(2, Vector3(0, 0, 0))
	var mob := await _spawn_mob("AATROX", Vector3(0, 0, 50))
	far_player.global_position = Vector3(0, 0, 200)
	await get_tree().process_frame
	await _damage(mob, far_player, 5)
	_ai(mob)._find_nearest_target()
	assert_eq(_ai(mob).target, far_player,
		"Mob pulls aggro on far threat source")
	# Now zero the threat (simulating full decay) and re-search.
	mob.get_node("ServerState").sync_threat_table.erase("2")
	_ai(mob)._find_nearest_target()
	assert_null(_ai(mob).target,
		"Threat = 0 + beyond leash = no target, mob waits for a closer attacker")

## Per-mob defense: the bystander mob's table is unaffected by damage
## the player deals to a DIFFERENT mob, even at the same time. Defends
## against the "whole wave aggros" regression we just fixed.
func test_damage_to_one_mob_does_not_leak_into_another_mobs_table() -> void:
	var player := await _spawn_player(2, Vector3(0, 0, 0))
	var hit_mob := await _spawn_mob("AATROX", Vector3(2, 0, 0))
	var other_mob := await _spawn_mob("AATROX", Vector3(3, 0, 0))
	await _damage(hit_mob, player, 30)
	assert_eq(_threat_of(hit_mob, "2"), 30)
	assert_eq(_threat_of(other_mob, "2"), 0,
		"The other mob's table is untouched by damage dealt to its neighbour")
