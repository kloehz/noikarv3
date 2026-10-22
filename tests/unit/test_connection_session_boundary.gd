extends "res://tests/isolated_gut_test.gd"
var _menu: CanvasLayer
var _old_role: String

func before_each() -> void:
	super.before_each()
	enable_client_presentation()
	_old_role = GameManager.session.role
	_menu = load("res://scenes/connection_menu.tscn").instantiate()
	add_child_autofree(_menu)

func after_each() -> void:
	GameManager.session.role = _old_role
	super.after_each()

func test_player_host_connection_never_submits_account_bearer() -> void:
	GameManager.session.role = "CLIENT"
	watch_signals(EventBus)
	_menu._on_connected_to_server()
	assert_signal_not_emitted(EventBus, "player_auth_token_submitted")

func test_legacy_provisioning_is_not_the_default_host_action() -> void:
	assert_true(_menu.has_method("_uses_legacy_provisioning"), "Default hosting must not provision a dedicated process")
	if not _menu.has_method("_uses_legacy_provisioning"): return
	_menu._on_host_pressed()
	assert_eq(_menu.current_state, _menu.State.ROOM)
	assert_false(Noray.is_connected_to_host())
