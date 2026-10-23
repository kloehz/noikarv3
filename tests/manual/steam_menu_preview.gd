extends SceneTree
## Render the real Noikar menu with only the external SDK replaced.

func _init() -> void:
	call_deferred("run")

func run() -> void:
	if OS.get_environment("NOIKAR_TEST_MODE") != "1" or DisplayServer.get_name() == "headless":
		quit(64)
		return
	root.size = Vector2i(1280, 720)
	# SceneTree scripts compile before autoload globals are registered.
	var fixture = load("res://tests/fixtures/steam_platform.gd")
	var game := root.get_node("GameManager")
	var accounts = fixture.Accounts.new()
	root.add_child(accounts)
	var adapter = fixture.Adapter.new()
	adapter.configure(game.session, accounts)
	adapter._steam = fixture.Platform.new()
	root.add_child(adapter)
	game.steam = adapter
	var manager: Node3D = fixture.add_match_manager(root)
	var menu = load("res://scenes/connection_menu.tscn").instantiate()
	root.add_child(menu)
	menu._switch_state(menu.State.ROOM)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.superpowers/sdd/2026-10-22-noikar-godot-4.8-listen-server/steam-room-menu.png")
	adapter.initialize()
	game.session.role = "LISTEN_HOST"
	game.session.phase = "lobby"
	game.session.transport = "steam"
	adapter.lobby_id = fixture.LOBBY
	adapter._host_steam_id = fixture.HOST
	menu._switch_state(menu.State.TEAM_LOBBY)
	menu.get_node("SteamFriendPicker").open()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.superpowers/sdd/2026-10-22-noikar-godot-4.8-listen-server/steam-friend-picker.png")
	game.session.phase = "menu"
	game.session.role = "MENU"
	game.session.transport = ""
	game.steam = null
	menu.free()
	manager.free()
	adapter.free()
	accounts.free()
	quit()
