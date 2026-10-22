"""Source-contract checks only; these do not claim native gameplay or CPU proof."""
from pathlib import Path
import unittest, sys
ROOT = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
class ServerBudgetContracts(unittest.TestCase):
    def text(self, path): return (ROOT / path).read_text()
    def test_authored_casts_are_attack_only(self):
        for path in ['scenes/BaseEntity.tscn', 'scenes/PetEntity.tscn']:
            block = self.text(path).split('[node name="ShapeCast3D"')[1].split('\n[node ')[0]
            self.assertIn('enabled = false', block)
    def test_dynamic_and_legacy_casts_are_disabled(self):
        combat = self.text('core/CombatComponent.gd')
        self.assertIn('MELEE_QUERY.configure(cast, data, get_parent())', combat)
        self.assertIn('_melee_shapecast.enabled = false', combat)
        self.assertEqual(combat.count('force_shapecast_update()'), 2)
    def test_soul_scene_has_no_eager_visual_dependency(self):
        scene = self.text('scenes/SoulEntity.tscn')
        self.assertNotIn('loot_vfx_rare.tscn', scene)
        self.assertIn('name="LootVFXRare" type="Node3D"', scene)
        for name in ['CollisionShape3D', 'MultiplayerSynchronizer']:
            self.assertIn('name="' + name + '"', scene)
        soul = self.text('common/SoulEntity.gd')
        self.assertIn('not GameManager._is_headless_environment()', soul)
        self.assertIn('load(SOUL_VFX_PATH)', soul)
        self.assertNotIn('preload(', soul)
    def test_experiments_fail_closed_by_default(self):
        ai = self.text('core/AIComponent.gd')
        self.assertIn('@export var decision_budget_enabled: bool = false', ai)
        self.assertIn('@export var distant_dormancy_enabled: bool = false', ai)
        self.assertIn('if decision_budget_enabled and _is_ordinary_mob():', ai)
        self.assertIn('func _tick_legacy_passive', ai)
    def test_both_experiments_share_ordinary_mob_exclusions_and_legacy_route(self):
        ai = self.text('core/AIComponent.gd')
        guard = ai.split('func _is_ordinary_mob() -> bool:')[1].split('\nfunc ')[0]
        for exclusion in ['entity != null', '_is_mob and not _is_pet', 'begins_with("BOSS_")', 'begins_with("ELITE")', 'is_in_group(&"bosses")']:
            self.assertIn(exclusion, guard)
        routing = ai.split('if decision_budget_enabled and _is_ordinary_mob():')[1].split('# Ensure we have the players node')[0]
        self.assertIn('else:', routing)
        self.assertIn('_distant_passive = false', routing)
        self.assertIn('delta = _tick_legacy_passive(delta)', routing)
        cadence = ai.split('func _tick_budgeted_passive(delta: float) -> bool:')[1].split('\nfunc ')[0]
        dormancy = ai.split('func wants_movement_dormancy() -> bool:')[1].split('\nfunc ')[0]
        self.assertIn('not _is_ordinary_mob()', cadence)
        self.assertIn('and _is_ordinary_mob()', dormancy)
        for body in [cadence, dormancy]:
            self.assertNotIn('begins_with("BOSS_")', body)
            self.assertNotIn('begins_with("ELITE")', body)
            self.assertNotIn('is_in_group(&"bosses")', body)
    def test_dormancy_has_recovery_and_wake_boundaries(self):
        logic = self.text('core/LogicComponent.gd')
        self.assertIn('NPC_DORMANT_RECOVERY_INTERVAL := 0.2', logic)
        self.assertIn('entity.global_transform != _npc_last_movement_pose', logic)
        self.assertIn('ai.wake_from_dormancy()', logic)
        self.assertIn('entity.velocity != Vector3.ZERO', logic)
        ai = self.text('core/AIComponent.gd')
        for guard in ['_is_pet', 'BOSS_', 'ELITE', 'bosses', '_has_threat()', 'sync_health']:
            self.assertIn(guard, ai)
    def test_clocks_and_human_route_are_unchanged(self):
        logic = self.text('core/LogicComponent.gd')
        self.assertIn('if not is_human and multiplayer.is_server():', logic)
        self.assertIn('NetworkTime.physics_factor', logic)
        self.assertNotIn('NetworkTime.tickrate =', logic)
        ai = self.text('core/AIComponent.gd')
        self.assertIn('_logic_chase()', ai)
        self.assertIn('_logic_attack()', ai)
        self.assertIn('_move_towards(_patrol_target, patrol_speed_factor)', ai)
if __name__ == '__main__': unittest.main(verbosity=2)
