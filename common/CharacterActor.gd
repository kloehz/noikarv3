# res://common/CharacterActor.gd
class_name CharacterActor
extends Node3D

## Base class for visual character scenes (the "Actor").
## Provides a standard interface for Logic and Combat components.

var animation_player: AnimationPlayer

## Sockets for combat/visual effects
var socket_weapon_main: Marker3D
var socket_chest: Marker3D
var socket_feet: Marker3D

func _ready() -> void:
	_find_animation_player()
	_find_sockets()
	if play_idle_on_ready:
		play_animation("Idle", 0.0)

func _find_animation_player() -> void:
	animation_player = _recursive_find_class(self, "AnimationPlayer")

func _recursive_find_class(node: Node, class_name_to_find: String) -> Node:
	if node.get_class() == class_name_to_find:
		return node
	for child in node.get_children():
		var found = _recursive_find_class(child, class_name_to_find)
		if found: return found
	return null

func _find_sockets() -> void:
	socket_weapon_main = _find_socket_path("WeaponMain")
	socket_chest = _find_socket_path("Chest")
	socket_feet = _find_socket_path("Feet")

func _find_socket_path(socket_name: String) -> Marker3D:
	var paths = [
		"Sockets/" + socket_name,
		"Model/Sockets/" + socket_name,
		"Model/" + socket_name
	]
	for p in paths:
		var n = get_node_or_null(p)
		if n is Marker3D: return n
	return null

## Animation names mapping
@export var anim_idle: String = "Idle_Base"
@export var anim_run: String = "Run"
@export var anim_attack: String = "Cast_Damage"
@export var anim_death: String = "Death"
@export var anim_hit: String = "Damage_Hurt"
## Starts this actor's configured idle clip as soon as its AnimationPlayer is ready.
## Enable only for imported scenes that otherwise enter their bind pose on spawn.
@export var play_idle_on_ready: bool = false
## Yaw (radians) applied to the actor node at spawn to align the imported
## mesh's visible forward with the entity's local -Z (Godot movement axis).
## Set to PI for models imported with +Z as forward; leave 0 for models
## that already face -Z. BaseEntity applies this to character_actor, never
## to the entity, so AI/chase/look driving entity.rotation.y stays correct.
@export var visual_forward_yaw: float = 0.0

# --- New: Combat Hints for Logic ---
@export_group("Combat Specs")
@export var suggested_attack_range: float = 2.5
@export var suggested_detection_range: float = 15.0
@export var suggested_follow_distance: float = 4.0

# --- Attack Definitions (read by BaseEntity → CombatComponent.configure()) ---
@export_group("Attacks")
## Primary attack definition (left-click / main attack).
@export var primary_attack: AttackDefinition
## Secondary attack definition (right-click / alt attack). Optional.
@export var secondary_attack: AttackDefinition

## Play an animation by standard name
func play_animation(anim_name: String, blend: float = 0.2) -> void:
	if not animation_player:
		_find_animation_player()

	if not animation_player:
		return

	var actual_anim := _resolve_animation_name(anim_name)
	if actual_anim != "" and animation_player.current_animation != actual_anim:
		animation_player.play(actual_anim, blend)

## Resolves a standard alias to the exact AnimationPlayer playback name.
## Named animation libraries require the library/clip form for current_animation.
func _resolve_animation_name(anim_name: String) -> String:
	if not animation_player:
		return ""

	var configured_anim := anim_name
	match anim_name:
		"Idle": configured_anim = anim_idle
		"Run": configured_anim = anim_run
		"Attack": configured_anim = anim_attack
		"Death": configured_anim = anim_death
		"Hit": configured_anim = anim_hit

	if animation_player.has_animation(configured_anim):
		return configured_anim

	# Some importers nest animations under a library ("library/Idle").
	for lib_name in animation_player.get_animation_library_list():
		var lib := animation_player.get_animation_library(lib_name)
		if lib and lib.has_animation(configured_anim):
			return ("%s/%s" % [lib_name, configured_anim]).trim_prefix("/")
		if anim_name == "Idle" and lib:
			for imported_name in lib.get_animation_list():
				if imported_name.to_lower().contains("idle"):
					return ("%s/%s" % [lib_name, imported_name]).trim_prefix("/")
	return ""

## Check if a specific animation or any one-shot is playing
func is_playing(anim_name: String) -> bool:
	if not animation_player:
		return false
	var actual_anim := _resolve_animation_name(anim_name)
	return actual_anim != "" and animation_player.is_playing() and animation_player.current_animation == actual_anim

func get_current_animation() -> String:
	return animation_player.current_animation if animation_player else &""

## Get a socket by name or type
func get_socket(socket_name: String) -> Marker3D:
	match socket_name:
		"WeaponMain": return socket_weapon_main
		"Chest": return socket_chest
		"Feet": return socket_feet
	return _find_socket_path(socket_name)
