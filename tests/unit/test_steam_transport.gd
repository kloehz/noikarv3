extends "res://tests/isolated_gut_test.gd"
## Missing platform must fail closed without affecting LAN or touching accounts.

func test_missing_optional_platform_keeps_lan_available() -> void:
	assert_true(ResourceLoader.exists("res://common/net/steam_transport.gd"))
	if not ResourceLoader.exists("res://common/net/steam_transport.gd"): return
	var adapter = load("res://common/net/steam_transport.gd").new()
	adapter.configure(GameManager.session, AuthService)
	add_child_autofree(adapter)
	if not Engine.has_singleton("Steam"):
		assert_false(adapter.initialize())
		assert_false(adapter.last_error.is_empty())
		assert_eq(GameManager.session.phase, "menu")
		assert_eq(adapter.lobby_id, 0)
	var result: Dictionary = load("res://common/net/enet_transport.gd").host(0)
	assert_eq(result.error, OK)
	result.peer.close()
