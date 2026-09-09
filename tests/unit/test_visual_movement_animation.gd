extends GutTest

const VISUAL_COMPONENT_SCRIPT := preload("res://client/VisualComponent.gd")
const LOGIC_COMPONENT_SCRIPT := preload("res://core/LogicComponent.gd")

func before_each() -> void:
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_each() -> void:
	multiplayer.multiplayer_peer = null

func _make_actor() -> CharacterActor:
	var actor := CharacterActor.new()
	actor.anim_idle = "Idle"
	actor.anim_run = "Run"
	var player := AnimationPlayer.new()
	var library := AnimationLibrary.new()
	var idle := Animation.new()
	idle.length = 0.2
	var run := Animation.new()
	run.length = 0.2
	library.add_animation("Idle", idle)
	library.add_animation("Run", run)
	player.add_animation_library("", library)
	actor.add_child(player)
	return actor

func _make_visual(group: StringName, authority_id: int = 2) -> Array:
	var entity := CharacterBody3D.new()
	entity.name = "MOB_REMOTE_VISUAL"
	entity.set_multiplayer_authority(authority_id)
	if group != &"":
		entity.add_to_group(group)

	var logic = LOGIC_COMPONENT_SCRIPT.new()
	logic.name = "LogicComponent"
	logic.current_velocity = Vector3.ZERO
	entity.add_child(logic)

	var visual = VISUAL_COMPONENT_SCRIPT.new()
	visual.entity = entity
	entity.add_child(visual)

	var actor := _make_actor()
	entity.add_child(actor)
	add_child_autofree(entity)
	await get_tree().process_frame
	visual.setup_with_actor(actor)
	return [entity, visual, actor, logic]

func test_remote_mob_uses_interpolated_transform_delta_for_run_and_idle() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual = setup[1]
	var actor: CharacterActor = setup[2]
	var logic = setup[3]
	logic.current_velocity = Vector3.ZERO

	visual._update_movement_animations()
	assert_eq(actor.get_current_animation(), "Idle",
		"The first remote mob animation frame must initialize safely as Idle")

	entity.global_position = Vector3(0.25, 0.0, 0.0)
	visual._update_movement_animations()
	assert_eq(actor.get_current_animation(), "Run",
		"Remote mobs should derive Run from interpolated transform movement, not synced LogicComponent velocity")

	visual._update_movement_animations()
	assert_eq(actor.get_current_animation(), "Idle",
		"A zero-delta remote mob frame should return to Idle safely")

func test_local_player_still_uses_predicted_logic_velocity() -> void:
	var setup := await _make_visual(&"", 1)
	var visual = setup[1]
	var actor: CharacterActor = setup[2]
	var logic = setup[3]
	logic.current_velocity = Vector3(1.0, 0.0, 0.0)

	visual._update_movement_animations()
	assert_eq(actor.get_current_animation(), "Run",
		"Local player movement animation should keep using predicted LogicComponent velocity")
