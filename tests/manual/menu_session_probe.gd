extends SceneTree
## Ordinary graphical startup, intentionally without test-bootstrap isolation.

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var world = load("res://scenes/main.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	for frame in 12: await process_frame
	var manager = root.get_node("GameManager")
	var auth = root.get_node("AuthService")
	var clock = root.get_node("NetworkTime")
	var noray = root.get_node("Noray")
	var result := {"role": str(manager.session.role), "phase": str(manager.session.phase),
		"clock_inactive": clock._state == clock._STATE_INACTIVE,
		"noray_connected": noray.is_connected_to_host(), "http_requests": auth.get_child_count(),
		"menu_present": world.has_node("ConnectionMenu"), "player_entities": world.get_node("Players").get_child_count(),
		"headless_display": DisplayServer.get_name() == "headless"}
	var ok: bool = result.role == "MENU" and result.phase == "menu" and result.clock_inactive and not result.noray_connected and result.http_requests == 0 and result.menu_present and result.player_entities == 0
	result["ok"] = ok
	print("MENU_SESSION_RESULT ", JSON.stringify(result))
	quit(0 if ok else 1)
