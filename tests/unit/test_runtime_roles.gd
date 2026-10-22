extends GutTest
var _manager: Node

func before_each() -> void:
	_manager = load("res://common/game_manager.gd").new()

func after_each() -> void:
	_manager.free()

func _has_roles() -> bool:
	assert_true(_manager.has_method("runtime_role_for"), "Roles must not be inferred from display")
	return _manager.has_method("runtime_role_for")

func test_rendered_host_keeps_presentation() -> void:
	if not _has_roles(): return
	_manager._ensure_session()
	_manager.session.role = "LISTEN_HOST"
	assert_true(_manager.should_present_world())
	assert_false(_manager.is_dedicated_runtime())
	assert_false(_manager._is_headless_environment())

func test_headless_client_keeps_client_role() -> void:
	if not _has_roles(): return
	assert_eq(_manager.runtime_role_for(["--client"], false, false), "CLIENT")
	_manager._runtime_role = "CLIENT"
	assert_false(_manager.is_dedicated_runtime())
	assert_true(_manager.should_present_world())
	assert_false(_manager._is_headless_environment())

func test_menu_has_no_active_simulation() -> void:
	if not _has_roles(): return
	assert_eq(_manager.runtime_role_for([], false, false), "MENU")
	assert_eq(_manager.runtime_role_for(["--server"], false, false), "DEDICATED")
	assert_eq(_manager.runtime_role_for([], true, false), "DEDICATED")
	_manager._ensure_session()
	assert_eq(_manager.session.role, "MENU")
	assert_eq(_manager.session.phase, "menu")
	assert_false(_manager.is_dedicated_runtime())

func test_benchmark_client_role_remains_explicit() -> void:
	if not _has_roles(): return
	assert_eq(_manager.runtime_role_for([], false, true), "CLIENT")
