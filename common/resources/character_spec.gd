# res://common/resources/character_spec.gd
## Pure data resource with everything the SERVER needs from a character:
## attack definitions, AI range hints, and the projectile socket height.
## The dedicated server loads this instead of instantiating the visual
## CharacterActor scene, so model assets (.glb) can stay out of the server pck.
## CharacterActor scenes reference the same spec, keeping a single source of
## truth for both server and client.
class_name CharacterSpec
extends Resource

## Primary attack definition (left-click / main attack).
@export var primary_attack: AttackDefinition
## Secondary attack definition (right-click / alt attack). Optional.
@export var secondary_attack: AttackDefinition

@export_group("AI Hints")
@export var suggested_attack_range: float = 2.5
@export var suggested_detection_range: float = 15.0
@export var suggested_follow_distance: float = 4.0

@export_group("Combat Presentation")
## World-space height of the WeaponMain socket above the entity origin.
## Used by the headless server to spawn player projectiles from the same
## position the client computes with the real Marker3D. 0 means the actor
## has no socket and CombatComponent keeps its default fallback origin.
@export var weapon_socket_height: float = 0.0
