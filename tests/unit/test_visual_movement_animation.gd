extends GutTest

const VISUAL_COMPONENT_SCRIPT := preload("res://client/VisualComponent.gd")
const LOGIC_COMPONENT_SCRIPT := preload("res://core/LogicComponent.gd")

var _previous_multiplayer_peer: MultiplayerPeer

func before_each() -> void:
	_previous_multiplayer_peer = multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_each() -> void:
	# Restore the runner's peer instead of breaking suites that execute next.
	multiplayer.multiplayer_peer = _previous_multiplayer_peer
	_previous_multiplayer_peer = null

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

func _prime_remote_motion(visual: VisualComponent, delta: float = 1.0 / 60.0) -> void:
	visual._update_movement_animations(delta)

func test_remote_mob_uses_interpolated_transform_delta_for_run_and_bounded_idle() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]
	var logic = setup[3]
	logic.current_velocity = Vector3.ZERO

	_prime_remote_motion(visual)
	assert_eq(actor.get_current_animation(), "Idle",
		"The first remote mob animation frame must initialize safely as Idle")

	entity.global_position = Vector3(0.25, 0.0, 0.0)
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Run",
		"Remote mobs should derive Run from interpolated transform movement, not synced LogicComponent velocity")

	visual._update_movement_animations(0.10)
	assert_eq(actor.get_current_animation(), "Run",
		"A single sparse zero-gap frame should not make remote mobs flicker to Idle")

	visual._update_movement_animations(0.09)
	assert_eq(actor.get_current_animation(), "Idle",
		"A true remote stop must become Idle within the bounded hold window")

func test_remote_motion_classification_matches_at_30_60_and_120_fps() -> void:
	for fps in [30.0, 60.0, 120.0]:
		var setup := await _make_visual(&"mobs", 2)
		var entity: CharacterBody3D = setup[0]
		var visual: VisualComponent = setup[1]
		var actor: CharacterActor = setup[2]
		var delta: float = 1.0 / fps

		_prime_remote_motion(visual, delta)
		entity.global_position += Vector3.RIGHT * 0.20 * delta
		visual._update_movement_animations(delta)
		assert_eq(actor.get_current_animation(), "Run", "Remote motion should classify as Run at %d FPS" % int(fps))

func test_remote_sparse_repeated_samples_stay_run_without_gap_idle_restart() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]

	_prime_remote_motion(visual)
	for sample_index in 4:
		entity.global_position += Vector3(0.04, 0.0, 0.0)
		visual._update_movement_animations(1.0 / 60.0)
		assert_eq(actor.get_current_animation(), "Run")
		for gap_frame in 5:
			visual._update_movement_animations(1.0 / 60.0)
			assert_eq(actor.get_current_animation(), "Run",
				"Repeated 10Hz samples must not insert Idle between Run samples")

func test_remote_motion_reset_after_attack_prevents_unobserved_displacement_burst() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]

	_prime_remote_motion(visual)
	visual._begin_remote_motion_reset()
	entity.global_position += Vector3(3.0, 0.0, 0.0)
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Resetting after an unobserved transition must sample the new position without a spurious Run burst")

func test_remote_motion_reset_on_authority_change_samples_without_burst() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]

	_prime_remote_motion(visual)
	entity.set_multiplayer_authority(multiplayer.get_unique_id())
	visual._update_movement_animations(1.0 / 60.0)
	entity.global_position += Vector3(4.0, 0.0, 0.0)
	entity.set_multiplayer_authority(2)
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Authority changes must reset remote sampling before comparing positions")

func test_local_player_still_uses_predicted_logic_velocity() -> void:
	var setup := await _make_visual(&"", 1)
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]
	var logic = setup[3]
	logic.current_velocity = Vector3(1.0, 0.0, 0.0)

	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Run",
		"Local player movement animation should keep using predicted LogicComponent velocity")

func test_local_tiny_velocity_below_existing_threshold_stays_idle() -> void:
	var setup := await _make_visual(&"", 1)
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]
	var logic = setup[3]
	logic.current_velocity = Vector3(0.001, 0.0, 0.0)

	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Local player animation must preserve the existing 0.0001 squared velocity threshold")

func test_public_spawn_effect_resets_remote_motion_sample_without_burst() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]

	_prime_remote_motion(visual)
	entity.global_position += Vector3(3.0, 0.0, 0.0)
	visual.play_spawn_effect()
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Public spawn effects must reset remote sampling before movement animation resumes")

func test_public_death_effect_resets_remote_motion_sample_without_burst() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]

	_prime_remote_motion(visual)
	entity.global_position += Vector3(3.0, 0.0, 0.0)
	visual.play_death_effect()
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Public death effects must reset remote sampling before movement animation resumes")

func test_post_animation_lock_gap_resamples_without_false_run() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]

	_prime_remote_motion(visual)
	visual._anim_lock_time = 0.05
	entity.global_position += Vector3(2.0, 0.0, 0.0)
	visual._process(0.10)
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Movement sampling must restart after animation lock gaps instead of accumulating displacement")

func test_post_dash_gap_resamples_without_false_run() -> void:
	var setup := await _make_visual(&"mobs", 2)
	var entity: CharacterBody3D = setup[0]
	var visual: VisualComponent = setup[1]
	var actor: CharacterActor = setup[2]
	var logic = setup[3]

	_prime_remote_motion(visual)
	logic.is_dashing = true
	entity.global_position += Vector3(2.0, 0.0, 0.0)
	visual._update_movement_animations(1.0 / 60.0)
	logic.is_dashing = false
	visual._update_movement_animations(1.0 / 60.0)
	assert_eq(actor.get_current_animation(), "Idle",
		"Movement sampling must restart after dash-only frames instead of accumulating displacement")
