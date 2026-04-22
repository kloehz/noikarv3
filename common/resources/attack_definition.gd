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
