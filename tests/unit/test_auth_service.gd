extends GutTest

const AUTH_SERVICE_SCRIPT := preload("res://common/auth_service.gd")

func _make_auth_service() -> Node:
	var service := AUTH_SERVICE_SCRIPT.new()
	add_child_autofree(service)
	return service

func test_env_override_has_highest_precedence_and_is_normalized() -> void:
	var service := _make_auth_service()

	var resolved: String = service._resolve_api_url("http://configured.example:8090", "  http://127.0.0.1:18090/  ", false)

	assert_eq(resolved, "http://127.0.0.1:18090")

func test_empty_env_override_is_ignored_for_headless_and_client_defaults() -> void:
	var service := _make_auth_service()

	assert_eq(service._resolve_api_url("http://configured.example:8090", "  ", false), "http://configured.example:8090")
	assert_eq(service._resolve_api_url("", "", false), service.DEFAULT_API_URL)
	assert_eq(service._resolve_api_url("http://configured.example:8090", "", true), service.SERVER_API_URL)
