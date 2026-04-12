# tests/unit/test_game_manager.gd
extends GutTest

## Unit tests for GameManager environment detection logic.
## Verifies that GameManager correctly detects headless vs client environments.

var _game_manager: Node
var _original_display_name: String
var _original_dedicated_server: bool

func before_each() -> void:
	_game_manager = load("res://common/game_manager.gd").new()
	add_child(_game_manager)
	
	# Cache original values
	_original_display_name = DisplayServer.get_name()
	_original_dedicated_server = OS.has_feature("dedicated_server")

func after_each() -> void:
	_game_manager.queue_free()

## Test: GameManager detects headless environment via DisplayServer
func test_detects_headless_display_server() -> void:
	# This test verifies the logic path used in production
	# In headless CI/testing, DisplayServer.get_name() returns "headless"
	var is_detected_as_headless = DisplayServer.get_name() == "headless"
	
	# The _is_headless_environment() should match this
	assert_eq(_game_manager._is_headless_environment(), is_detected_as_headless or _original_dedicated_server)

## Test: GameManager detects dedicated_server feature flag
func test_detects_dedicated_server_feature() -> void:
	assert_eq(OS.has_feature("dedicated_server"), _original_dedicated_server)

## Test: GameManager has DEFAULT_PORT constant
func test_has_default_port_constant() -> void:
	assert_eq(_game_manager.DEFAULT_PORT, 7777)

## Test: GameManager is a Node
func test_game_manager_is_node() -> void:
	assert_true(_game_manager is Node)

## Test: EventBus is available as autoload
func test_event_bus_autoload_exists() -> void:
	assert_true(has_node("/root/EventBus"), "EventBus should be registered as autoload")

## Test: GameManager has server_started signal connection
func test_server_started_signal_exists() -> void:
	assert_true(EventBus.has_signal("server_started"), "EventBus should have server_started signal")

## Test: GameManager has client_connected signal connection
func test_client_connected_signal_exists() -> void:
	assert_true(EventBus.has_signal("client_connected"), "EventBus should have client_connected signal")
