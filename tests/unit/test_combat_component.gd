# tests/unit/test_combat_component.gd
extends GutTest

var _combat: Node
var _mock_entity: Node3D

func before_each() -> void:
	_combat = load("res://core/CombatComponent.gd").new()
	_mock_entity = Node3D.new()
	_mock_entity.position = Vector3(4.0, 0.0, 5.0)
	add_child_autofree(_mock_entity)
	_combat.entity = _mock_entity

func after_each() -> void:
	if is_instance_valid(_combat):
		_combat.entity = null
		_combat.free()
	_mock_entity = null

## The spawn offset is applied along the full aim direction so the projectile
## travels where the player is pointing. The spawn sits 1 m above the socket
## (or the entity fallback) to match the raised third-person camera.
func test_projectile_spawn_offset_uses_full_direction() -> void:
	var downward_aim := Vector3(0.0, -0.5, -0.866).normalized()

	var with_socket: Vector3 = _combat.spawn_pos_for(downward_aim, Vector3(2.0, 1.0, 3.0))
	var expected_socket_spawn: Vector3 = Vector3(2.0, 3.0, 3.0) + downward_aim * 1.6
	assert_almost_eq(with_socket.x, expected_socket_spawn.x, 0.0001)
	assert_almost_eq(with_socket.y, expected_socket_spawn.y, 0.0001)
	assert_almost_eq(with_socket.z, expected_socket_spawn.z, 0.0001)

func test_projectile_spawn_offset_without_socket_anchors_to_entity() -> void:
	var direction := Vector3(0.0, 0.0, -1.0)
	var fresh_entity := Node3D.new()
	fresh_entity.position = Vector3(4.0, 0.0, 5.0)
	add_child_autofree(fresh_entity)
	_combat.entity = fresh_entity
	var spawn_position: Vector3 = _combat.spawn_pos_for(direction, Vector3.ZERO)
	var expected: Vector3 = Vector3(4.0, 0.0, 5.0) + Vector3(0.0, 3.6, 0.0) + direction * 1.6
	assert_almost_eq(spawn_position.x, expected.x, 0.0001)
	assert_almost_eq(spawn_position.y, expected.y, 0.0001)
	assert_almost_eq(spawn_position.z, expected.z, 0.0001)

## Difficulty is a pure multiplicative pass-through so a misconfigured
## spawn payload (zero/negative) can never zero out a mob's damage.
func test_apply_difficulty_multiplies_amount() -> void:
	_combat.difficulty = 1.4
	assert_almost_eq(_combat._apply_difficulty(50.0), 70.0, 0.0001,
		"+40% difficulty must scale 50 → 70")
	assert_almost_eq(_combat._apply_difficulty(0.0), 0.0, 0.0001,
		"Zero damage stays zero")

func test_apply_difficulty_identity_at_one() -> void:
	_combat.difficulty = 1.0
	assert_almost_eq(_combat._apply_difficulty(123.0), 123.0, 0.0001,
		"Default difficulty (1.0) is identity")

func test_apply_difficulty_guards_against_zero_and_negative() -> void:
	_combat.difficulty = 0.0
	assert_almost_eq(_combat._apply_difficulty(80.0), 80.0, 0.0001,
		"Zero difficulty falls back to identity (never zero the damage)")
	_combat.difficulty = -1.5
	assert_almost_eq(_combat._apply_difficulty(80.0), 80.0, 0.0001,
		"Negative difficulty falls back to identity")

func test_attack_cooldown_range_is_deterministic_and_bounded() -> void:
	var attack := AttackDefinition.new()
	attack.cooldown = 0.8
	attack.cooldown_min = 0.7
	attack.cooldown_max = 1.1
	var first := attack.get_cooldown("PET_2_ATTACK", 5)
	var repeated := attack.get_cooldown("PET_2_ATTACK", 5)
	assert_gte(first, 0.7)
	assert_lte(first, 1.1)
	assert_almost_eq(first, repeated, 0.000001,
		"Same entity and attack sequence must resolve identically on every peer")

func test_fixed_attack_cooldown_remains_unchanged() -> void:
	var attack := AttackDefinition.new()
	attack.cooldown = 1.25
	assert_almost_eq(attack.get_cooldown("MOB_1", 1), 1.25, 0.000001)

func test_attack_event_identity_uses_attack_counter_not_processing_tick() -> void:
	_mock_entity.name = "77"
	_combat.sync_attack_count = 8
	assert_eq(_combat._attack_event_id(), "77:8")
	assert_true(_combat._record_attack_event(_combat._attack_event_id()))
	assert_false(_combat._record_attack_event(_combat._attack_event_id()),
		"Reprocessing the same attack counter on another tick must not dispatch twice")

func test_attack_event_ledger_is_per_component_and_bounded() -> void:
	_mock_entity.name = "77"
	_combat.sync_attack_count = 1
	assert_true(_combat._record_attack_event(_combat._attack_event_id()))

	var new_combat := CombatComponent.new()
	new_combat.entity = _mock_entity
	new_combat.sync_attack_count = 1
	assert_true(new_combat._record_attack_event(new_combat._attack_event_id()),
		"A newly spawned component has its own irreversible-event ledger")
	new_combat.free()

	for i in range(CombatComponent.MAX_RECORDED_ATTACK_EVENTS + 1):
		assert_true(_combat._record_attack_event("77:%d" % [i + 2]))
	assert_lte(_combat._dispatched_attack_event_order.size(), CombatComponent.MAX_RECORDED_ATTACK_EVENTS)
	assert_false(_combat._dispatched_attack_events.has("77:1"),
		"Old attack IDs are evicted so the server ledger remains bounded")
