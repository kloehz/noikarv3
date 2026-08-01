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
	var expected_socket_spawn: Vector3 = Vector3(2.0, 2.3, 3.0) + downward_aim * 1.6
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
	var expected: Vector3 = Vector3(4.0, 0.0, 5.0) + Vector3(0.0, 2.9, 0.0) + direction * 1.6
	assert_almost_eq(spawn_position.x, expected.x, 0.0001)
	assert_almost_eq(spawn_position.y, expected.y, 0.0001)
	assert_almost_eq(spawn_position.z, expected.z, 0.0001)