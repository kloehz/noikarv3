extends GutTest

const ABILITY_SCRIPT := preload("res://common/components/AbilityComponent.gd")
const LOGIC_SCRIPT := preload("res://core/LogicComponent.gd")
const COMBAT_SCRIPT := preload("res://core/CombatComponent.gd")

class TestEntity:
	extends CharacterBody3D
	var sync_is_dead := false

func _make_entity(entity_name: String) -> TestEntity:
	var entity := TestEntity.new()
	entity.name = entity_name
	var state := ServerState.new()
	state.name = "ServerState"
	entity.add_child(state)
	return entity

func _make_ability(entity_name: String = "2") -> Node:
	var entity := _make_entity(entity_name)
	add_child_autofree(entity)
	var ability: Node = ABILITY_SCRIPT.new()
	ability.name = "AbilityComponent"
	entity.add_child(ability)
	ability.entity = entity
	ability.server_state = entity.get_node("ServerState")
	return ability

func test_q_and_e_intent_plumbing_is_noop() -> void:
	var logic: LogicComponent = autofree(LOGIC_SCRIPT.new())
	logic.ability_q_pressed = true
	logic.ability_e_pressed = true
	assert_true(logic.consume_ability_q_intent(), "Q seam should expose a named consumable intent")
	assert_true(logic.consume_ability_e_intent(), "E seam should expose a named consumable intent")
	assert_false(logic.consume_ability_q_intent(), "Q no-op seam should reset after consumption")
	assert_false(logic.consume_ability_e_intent(), "E no-op seam should reset after consumption")

func test_r_activation_starts_window_and_cooldown_for_players_only() -> void:
	var ability: Node = _make_ability("2")
	assert_true(ability.server_try_activate_r(), "Human player should activate R on the server")
	assert_almost_eq(ability.r_window_remaining, 3.0, 0.001)
	assert_almost_eq(ability.r_cooldown_remaining, 30.0, 0.001)
	assert_eq(ability.current_r_activation_token, 1)
	assert_false(ability.server_try_activate_r(), "Cooldown starts immediately and rejects replay")

	var mob_ability: Node = _make_ability("MOB_AATROX_1")
	assert_false(mob_ability.server_try_activate_r(), "Mobs must never activate player R")
	var pet_ability: Node = _make_ability("PET_2")
	assert_false(pet_ability.server_try_activate_r(), "Pets must never activate player R")

func test_r_token_snapshotted_during_window_survives_projectile_late_hit() -> void:
	var ability: Node = _make_ability("2")
	assert_true(ability.server_try_activate_r())
	var token: int = ability.snapshot_r_attack_token()
	ability.server_tick(3.1)
	assert_almost_eq(ability.r_window_remaining, 0.0, 0.001)
	var target := _make_entity("3")
	add_child_autofree(target)
	assert_true(ability.server_consume_r_stun_token(token, target), "Projectile token captured during window stays valid after the window")
	assert_true(target.get_node("ServerState").is_stunned)
	assert_almost_eq(target.get_node("ServerState").stun_remaining_time, 1.5, 0.001)

func test_r_resimulation_does_not_advance_cooldown_window_stun_or_replay_intent() -> void:
	var entity := _make_entity("2")
	add_child_autofree(entity)
	var state: ServerState = entity.get_node("ServerState")
	state.apply_stun(1.5)
	var ability: Node = ABILITY_SCRIPT.new()
	ability.name = "AbilityComponent"
	entity.add_child(ability)
	ability.entity = entity
	ability.server_state = state
	ability.r_window_remaining = 2.5
	ability.r_cooldown_remaining = 29.5
	ability.current_r_activation_token = 1

	var logic: LogicComponent = LOGIC_SCRIPT.new()
	logic.entity = entity
	logic._server_state = state
	logic._ability_component = ability
	logic.ability_r_pressed = true
	entity.add_child(logic)

	logic._rollback_tick(0.5, 10, false)
	assert_almost_eq(ability.r_window_remaining, 2.5, 0.001, "Resimulation must not advance R window")
	assert_almost_eq(ability.r_cooldown_remaining, 29.5, 0.001, "Resimulation must not advance R cooldown")
	assert_almost_eq(state.stun_remaining_time, 1.5, 0.001, "Resimulation must not advance stun timer")
	assert_true(logic.ability_r_pressed, "Resimulation must not consume one-shot R intent")


func test_r_consumes_only_first_eligible_human_hit_and_rejects_stale_or_replayed_tokens() -> void:
	var ability: Node = _make_ability("2")
	assert_true(ability.server_try_activate_r())
	var token: int = ability.snapshot_r_attack_token()
	var mob := _make_entity("MOB_AATROX_1")
	var first_player := _make_entity("3")
	var second_player := _make_entity("4")
	add_child_autofree(mob)
	add_child_autofree(first_player)
	add_child_autofree(second_player)

	assert_false(ability.server_consume_r_stun_token(token, mob), "Mob hits must not stun or consume R")
	assert_true(ability.server_consume_r_stun_token(token, first_player), "First eligible human consumes R")
	assert_false(ability.server_consume_r_stun_token(token, second_player), "Later tagged hits from the same activation fail")
	assert_false(ability.server_consume_r_stun_token(token - 1, second_player), "Stale tokens are rejected")
	assert_false(second_player.get_node("ServerState").is_stunned)

func test_r_rejects_allied_player_without_consuming_token_or_stunning() -> void:
	var ability: Node = _make_ability("2")
	ability.server_state.team_id = TeamId.RED
	assert_true(ability.server_try_activate_r())
	var token: int = ability.snapshot_r_attack_token()
	var ally := _make_entity("3")
	add_child_autofree(ally)
	ally.get_node("ServerState").team_id = TeamId.RED

	assert_false(ability.server_consume_r_stun_token(token, ally), "Allied players must not consume R or receive stun")
	assert_ne(ability.consumed_r_activation_token, token, "Rejected allied hits must leave token available")
	assert_false(ally.get_node("ServerState").is_stunned, "Allied players must not be stunned")

func test_stun_blocks_movement_and_attack_initiation() -> void:
	var entity := _make_entity("2")
	add_child_autofree(entity)
	var state: ServerState = entity.get_node("ServerState")
	state.apply_stun(1.5)

	var logic: LogicComponent = LOGIC_SCRIPT.new()
	logic.entity = entity
	logic.input_axis = Vector2.RIGHT
	logic.is_shooting = true
	logic._server_state = state
	entity.add_child(logic)
	logic.is_dashing = true
	logic.dash_timer = 0.1
	logic.dash_cooldown = 0.7
	logic.dash_direction = Vector3.RIGHT
	logic.current_velocity = Vector3.RIGHT * 30.0
	logic._simulate_tick(0.1, 1)
	assert_eq(logic.input_axis, Vector2.ZERO)
	assert_false(logic.is_shooting)
	assert_false(logic.is_dashing, "Stun must cancel an active dash")
	assert_almost_eq(logic.dash_timer, 0.0, 0.001, "Stun must clear active dash duration")
	assert_almost_eq(logic.dash_cooldown, 0.7, 0.001, "Stun should preserve existing dash cooldown")
	assert_eq(logic.current_velocity, Vector3.ZERO, "Stun must clear movement velocity")

	var combat: CombatComponent = COMBAT_SCRIPT.new()
	entity.add_child(combat)
	combat.entity = entity
	combat.logic = logic
	combat._try_start_attack(null, true)
	assert_eq(combat.current_attack_state, CombatComponent.AttackState.READY, "Stunned players cannot start attacks")

func test_server_state_clear_stun_resets_stun_state() -> void:
	var state: ServerState = autofree(ServerState.new())
	state.apply_stun(1.5)
	state.clear_stun()
	assert_false(state.is_stunned)
	assert_almost_eq(state.stun_remaining_time, 0.0, 0.001)
