extends GutTest
## Only the HTTP boundary is substituted; client payload/security policy is real.
class ApiBoundary extends "res://common/auth_service.gd":
	var calls: Array[Dictionary] = []
	var response := {"status": 201, "data": {}}
	func _request(path: String, body: Dictionary, bearer_token := "", extra_headers: Dictionary = {}) -> Dictionary:
		calls.append({"path": path, "body": body, "bearer": bearer_token, "headers": extra_headers})
		return response

var _api: Node
var _old_url: String

func before_each() -> void:
	_old_url = str(ProjectSettings.get_setting("noikar/auth/api_url", ""))
	_api = ApiBoundary.new()
	add_child_autofree(_api)
	ProjectSettings.set_setting("noikar/auth/api_url", "https://auth.example.invalid")
	_api.access_token = "local-account-bearer"
	_api.account_id = "host-account"
	_api.username = "Host"

func after_each() -> void:
	ProjectSettings.set_setting("noikar/auth/api_url", _old_url)

func _requires_contract() -> bool:
	assert_true(_api.has_method("create_listen_room"), "Scoped account admission client must exist")
	return _api.has_method("create_listen_room")

func test_host_identity_is_local_validated_account() -> void:
	if not _requires_contract(): return
	_api.response = {"status": 201, "data": {"room_id": "room", "room_credential": "room-only-secret", "host_identity": {"account_id": "host-account", "username": "Host"}}}
	var result: Dictionary = await _api.create_listen_room("session-binding")
	assert_true(result.accepted)
	assert_eq(result.host_identity, {"account_id": "host-account", "username": "Host"})
	assert_eq(_api.calls[0].bearer, "local-account-bearer")
	assert_eq(_api.calls[0].body, {"session_id": "session-binding"})
	_api.response.data.host_identity.account_id = "different-account"
	result = await _api.create_listen_room("session-binding")
	assert_false(result.accepted, "A response cannot replace the login owner's identity")

func test_listen_path_never_submits_account_bearer_to_peer() -> void:
	if not _requires_contract(): return
	_api.response = {"status": 201, "data": {"ticket": "opaque-room-proof"}}
	var result: Dictionary = await _api.issue_listen_ticket("room")
	assert_eq(result, {"accepted": true, "ticket": "opaque-room-proof"})
	assert_eq(_api.calls[0].bearer, "local-account-bearer", "Only the owner's account API request uses the bearer")
	assert_false(result.has("token"))
	assert_false(result.has("access_token"))
	_api.response = {"status": 200, "data": {"account_id": "guest", "username": "Guest"}}
	result = await _api.redeem_listen_ticket("room", "opaque-room-proof", "room-only-secret")
	assert_true(result.accepted)
	assert_eq(_api.calls[1].bearer, "", "A player host does not need the guest's bearer")
	assert_eq(_api.calls[1].headers, {"X-Room-Credential": "room-only-secret"})
	assert_eq(_api.calls[1].body, {"ticket": "opaque-room-proof"})

func test_closing_room_does_not_clear_account_login() -> void:
	if not _requires_contract(): return
	_api.response = {"status": 204, "data": {}}
	await _api.close_listen_room("room", "room-only-secret")
	assert_eq(_api.access_token, "local-account-bearer")
	assert_eq(_api.calls[0].bearer, "")
	assert_eq(_api.calls[0].headers, {"X-Room-Credential": "room-only-secret"})

func test_remote_http_is_rejected_before_sending_credentials() -> void:
	if not _requires_contract(): return
	ProjectSettings.set_setting("noikar/auth/api_url", "http://72.60.58.24:8090")
	var result: Dictionary = await _api.create_listen_room("session-binding")
	assert_false(result.accepted)
	assert_eq(_api.calls.size(), 0)
	result = await _api.login("fixture", "fixture-password")
	assert_false(result.accepted)
	assert_eq(_api.calls.size(), 0, "Default login cannot leak passwords before room selection")

func test_loopback_http_requires_debug_and_explicit_isolation() -> void:
	if not _requires_contract(): return
	for row in [
		["https://auth.example.invalid", false, false, true],
		["http://127.0.0.1:18090", true, true, true],
		["http://[::1]:18090", true, true, true],
		["http://127.0.0.1:18090", false, true, false],
		["http://127.0.0.1:18090", true, false, false],
		["http://localhost:18090", true, true, false],
		["http://127.0.0.1.attacker.example:80", true, true, false],
		["https://auth.example.invalid@attacker.example", true, true, false],
		["http://127.0.0.1:18090/path", true, true, false],
	]:
		assert_eq(_api.listen_api_url_allowed(row[0], row[1], row[2]), row[3], row[0])
