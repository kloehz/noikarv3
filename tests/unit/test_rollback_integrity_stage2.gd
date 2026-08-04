extends GutTest

const COMBAT_COMPONENT_SCRIPT := preload("res://core/CombatComponent.gd")
const REQUIRED_COMBAT_STATE := [
	"CombatComponent:current_attack_state",
	"CombatComponent:_state_timer",
	"CombatComponent:sync_attack_count",
	"CombatComponent:is_charging",
	"CombatComponent:current_charge_time",
	"CombatComponent:_projectile_direction",
	"CombatComponent:_active_damage_multiplier",
	"CombatComponent:_active_attack_slot",
	"CombatComponent:_primary_cooldown",
	"CombatComponent:_secondary_cooldown",
]

func test_server_attack_event_ledger_rejects_replay() -> void:
	var combat: Node = COMBAT_COMPONENT_SCRIPT.new()
	add_child_autofree(combat)

	assert_true(combat.call("_record_attack_event", "attacker:1:10"))
	assert_false(combat.call("_record_attack_event", "attacker:1:10"),
		"Restoring an attack tick must not dispatch its world side effect twice")
	assert_true(combat.call("_record_attack_event", "attacker:2:11"))

func test_enemy_and_pet_snapshot_full_combat_state() -> void:
	for path in ["res://scenes/EnemyEntity.tscn", "res://scenes/PetEntity.tscn"]:
		var properties := _rollback_state_properties(path)
		for property in REQUIRED_COMBAT_STATE:
			assert_true(properties.has(property), "%s must snapshot %s" % [path, property])

func test_projectiles_are_server_authoritative_without_prediction() -> void:
	var scene: PackedScene = load("res://scenes/ProjectileEntity.tscn")
	var state := scene.get_state()
	var properties := _rollback_state_properties("res://scenes/ProjectileEntity.tscn")

	assert_false(_node_property(state, "RollbackSynchronizer", "enable_prediction"),
		"Server-owned projectile movement must not run on clients")
	for property in [":damage", ":knockback", ":owner_entity_id", ":_lifetime_remaining", ":_has_hit"]:
		assert_true(properties.has(property), "Projectile state must include %s" % property)

func test_enemy_and_pet_expose_spawn_grace_to_child_components() -> void:
	var logic_source := FileAccess.get_file_as_string("res://core/LogicComponent.gd")
	var combat_source := FileAccess.get_file_as_string("res://core/CombatComponent.gd")
	assert_true(logic_source.contains("is_spawn_grace_active"),
		"LogicComponent must reject rollback movement during entity spawn grace")
	assert_true(combat_source.contains("is_spawn_grace_active"),
		"CombatComponent must reject rollback attacks during entity spawn grace")

func _rollback_state_properties(path: String) -> Array:
	var scene: PackedScene = load(path)
	return _node_property(scene.get_state(), "RollbackSynchronizer", "state_properties")

func _node_property(state: SceneState, node_name: String, property_name: String):
	for node_index in state.get_node_count():
		if state.get_node_name(node_index) != node_name:
			continue
		for property_index in state.get_node_property_count(node_index):
			if state.get_node_property_name(node_index, property_index) == property_name:
				return state.get_node_property_value(node_index, property_index)
	return null
