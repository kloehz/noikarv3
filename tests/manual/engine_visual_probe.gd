extends SceneTree
## Render the actual inherited game without account/network/service side effects.

func _init() -> void:
	call_deferred("run")

func run() -> void:
	if DisplayServer.get_name() == "headless":
		print("ENGINE_VISUAL_RESULT ", JSON.stringify({"ok": false, "reason": "Rendered display required"}))
		quit(1)
		return
	root.multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var app = load("res://scenes/main.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await process_frame
	app._on_room_creator_ticket_validated("compatibility-fixture")
	var admitted: bool = app._admit_authenticated_identity(1, {"account_id": "compatibility-fixture", "username": "Compatibility fixture"})
	if not admitted:
		print("ENGINE_VISUAL_RESULT ", JSON.stringify({"ok": false, "reason": "Local fixture identity not admitted"}))
		quit(1)
		return
	app._lobby[1]["team"] = TeamId.RED
	app._lobby[1]["character_id"] = "warrior"
	app._spawn_player(1)
	var player = app.get_node("Players/1")
	var menu = app.get_node("ConnectionMenu")
	menu._switch_state(menu.State.IN_GAME)
	await physics_frame
	var origin: Vector3 = player.global_position
	var logic = player.get_node("LogicComponent")
	var combat = player.get_node("CombatComponent")
	var initial_attacks: int = combat.sync_attack_count
	for frame in 45:
		await physics_frame
		logic.input_axis = Vector2(0, -1)
		logic.is_shooting = frame >= 15
		logic._rollback_tick(1.0 / 30.0, frame, true)
		combat._rollback_tick(1.0 / 30.0, frame, true)
	logic.input_axis = Vector2.ZERO
	logic.is_shooting = false
	await process_frame
	await RenderingServer.frame_post_draw
	var image = root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/artifacts"))
	var saved: int = image.save_png("res://tests/artifacts/godot-4.8-compatibility.png")
	var distance: float = player.global_position.distance_to(origin)
	var camera_active: bool = root.get_camera_3d() != null
	var attacked: bool = combat.sync_attack_count > initial_attacks
	var ok: bool = distance > 0.1 and camera_active and attacked and saved == OK
	print("ENGINE_VISUAL_RESULT ", JSON.stringify({"ok": ok, "display": DisplayServer.get_name(), "distance": distance, "camera": camera_active, "attack": attacked, "screenshot": saved == OK, "networked": false, "authenticated_against_backend": false}))
	quit(0 if ok else 1)
