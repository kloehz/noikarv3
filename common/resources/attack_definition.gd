# res://common/resources/attack_definition.gd
## Pure data resource defining a complete attack (melee, ranged, or AoE).
## Consumed by CombatComponent.configure() to set up attack behavior.
## This resource contains NO logic — only attack parameters.
class_name AttackDefinition
extends Resource

enum AttackType { MELEE_HITSCAN, PROJECTILE, AOE_DELAYED }

## The type of attack this definition represents.
@export var attack_type: AttackType = AttackType.MELEE_HITSCAN

## --- MELEE_HITSCAN ---
## Shape data for the ShapeCast3D. Only used when attack_type == MELEE_HITSCAN.
@export var shape_data: AttackShapeData

## --- PROJECTILE ---
## Scene to instantiate for projectile attacks. Only used when attack_type == PROJECTILE.
@export var projectile_scene: PackedScene

## Speed of the projectile (units/sec). Only used when attack_type == PROJECTILE.
@export var projectile_speed: float = 20.0

## Per-attack vertical correction after the standard projectile origin is
## calculated. Keeps unusual rigs, such as Ezreal's raised weapon socket,
## from firing above valid targets without changing other projectile actors.
@export var projectile_height_offset: float = 0.0

## Holding the primary input charges a projectile when this is greater than zero.
## A zero duration preserves the immediate-fire behavior used by existing actors.
@export var charge_duration: float = 0.0

## Damage multiplier applied when a charged projectile is released immediately.
@export var minimum_charge_multiplier: float = 1.0

## Damage multiplier applied after charge_duration has elapsed.
@export var maximum_charge_multiplier: float = 1.0

## Local-only aiming presentation for charged projectile attacks.
@export var aim_fov: float = 58.0

## --- AOE_DELAYED (stub) ---
## Radius of the AoE effect. Only used when attack_type == AOE_DELAYED.
@export var aoe_radius: float = 3.0

## Delay before AoE triggers (seconds). Only used when attack_type == AOE_DELAYED.
@export var aoe_delay: float = 1.0

## --- Shared Parameters ---
## Base damage dealt by this attack.
@export var base_damage: float = 15.0

## Cooldown between uses (seconds).
@export var cooldown: float = 0.7
## Optional lower bound for a varied attack cadence. Leave both range values
## at zero to use the fixed cooldown above.
@export var cooldown_min: float = 0.0
## Optional upper bound for a varied attack cadence.
@export var cooldown_max: float = 0.0

## Knockback force applied to hit targets.
@export var knockback_force: float = 12.0

## Energy cost (reserved for energy system, stored but not consumed yet).
@export var energy_cost: int = 0

## --- Animation Timing ---
## Startup time before the attack becomes active (windup).
@export var startup_time: float = 0.1

## Duration of the active hit window.
@export var active_time: float = 0.3

## Recovery time after the active window (backswing).
@export var recovery_time: float = 0.3

## Returns a repeatable value in the configured cooldown range. The key must
## identify the entity and attack sequence so server and clients choose the
## same cadence without advancing a shared random-number generator.
func get_cooldown(entity_key: String, attack_sequence: int) -> float:
	var lower := cooldown_min if cooldown_min > 0.0 else cooldown
	var upper := cooldown_max if cooldown_max > 0.0 else cooldown
	lower = maxf(0.0, lower)
	upper = maxf(lower, upper)
	if is_equal_approx(lower, upper):
		return lower
	var seed := ("%s:%d" % [entity_key, attack_sequence]).hash()
	var ratio := float(seed & 0xffff) / 65535.0
	return lerpf(lower, upper, ratio)
