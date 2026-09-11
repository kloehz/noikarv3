extends GutTest

const CONNECTION_MANAGER_SCRIPT := preload("res://client/connection_manager.gd")

var _original_mouse_mode: int

func before_each() -> void:
	_original_mouse_mode = Input.mouse_mode

func after_each() -> void:
	Input.mouse_mode = _original_mouse_mode

func _make_manager() -> CanvasLayer:
	return autofree(CONNECTION_MANAGER_SCRIPT.new())

func _toggle_action_event() -> InputEventAction:
	var event := InputEventAction.new()
	event.action = &"toggle_menu"
	event.pressed = true
	return event

func _escape_echo_event() -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	event.echo = true
	return event

func test_toggle_menu_toggles_mouse_visible_while_in_game() -> void:
	var manager := _make_manager()
	manager.current_state = manager.State.IN_GAME
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	assert_true(manager._toggle_in_game_mouse_mode(_toggle_action_event()))
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE)

func test_toggle_menu_toggles_mouse_captured_when_already_visible() -> void:
	var manager := _make_manager()
	manager.current_state = manager.State.IN_GAME

	assert_eq(manager._next_in_game_mouse_mode(Input.MOUSE_MODE_VISIBLE), Input.MOUSE_MODE_CAPTURED)

func test_toggle_menu_ignored_outside_in_game() -> void:
	var manager := _make_manager()
	manager.current_state = manager.State.ROOM
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	assert_false(manager._toggle_in_game_mouse_mode(_toggle_action_event()))
	assert_eq(Input.mouse_mode, Input.MOUSE_MODE_VISIBLE)

func test_toggle_menu_echo_is_ignored() -> void:
	var manager := _make_manager()
	manager.current_state = manager.State.IN_GAME
	var before := Input.mouse_mode

	assert_false(manager._toggle_in_game_mouse_mode(_escape_echo_event()))
	assert_eq(Input.mouse_mode, before)
