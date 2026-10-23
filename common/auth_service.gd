extends Node

## Owns the client access token and validates tokens for the dedicated server.
## Closed beta: clients reach the API straight off the VPS IP (no HTTPS proxy
## yet). The dedicated server overrides this with the loopback address.
const DEFAULT_API_URL := "http://72.60.58.24:8090"
const SERVER_API_URL := "http://127.0.0.1:8090"
const API_URL_SETTING := "noikar/auth/api_url"
const BACKEND_URL_ENV := "NOIKAR_BACKEND_URL"

var access_token := ""
var account_id := ""
var username := ""

func _ready() -> void:
	var configured_url := str(ProjectSettings.get_setting(API_URL_SETTING, "")) if ProjectSettings.has_setting(API_URL_SETTING) else ""
	ProjectSettings.set_setting(API_URL_SETTING, _resolve_api_url(configured_url, OS.get_environment(BACKEND_URL_ENV), _is_headless_runtime()))

func _is_headless_runtime() -> bool:
	return GameManager.is_dedicated_runtime()

func _resolve_api_url(configured_url: String, env_override: String, is_headless: bool) -> String:
	var normalized_override := env_override.strip_edges().trim_suffix("/")
	if not normalized_override.is_empty():
		return normalized_override
	if is_headless:
		return SERVER_API_URL
	var normalized_configured := configured_url.strip_edges()
	return normalized_configured if not normalized_configured.is_empty() else DEFAULT_API_URL

func login(account_name: String, password: String) -> Dictionary:
	return await _authenticate("/api/v1/auth/login", account_name, password)

func register(account_name: String, password: String) -> Dictionary:
	return await _authenticate("/api/v1/auth/register", account_name, password)

func validate_access_token(token: String) -> Dictionary:
	var response := await _request("/api/v1/auth/me", {}, token)
	if response.status != 200:
		return {"accepted": false}
	var data: Dictionary = response.data
	var validated_account_id := str(data.get("account_id", ""))
	var validated_username := str(data.get("username", ""))
	return {
		"accepted": not validated_account_id.is_empty() and not validated_username.is_empty(),
		"account_id": validated_account_id,
		"username": validated_username,
	}

func issue_room_creator_ticket() -> Dictionary:
	var response := await _request("/api/v1/rooms/creator-ticket", {"issue": true}, access_token)
	var ticket := str(response.data.get("ticket", ""))
	return {"accepted": response.status == 201 and not ticket.is_empty(), "ticket": ticket}

func validate_room_creator_ticket(ticket: String, provision_instance_id: String, world_server_credential: String) -> Dictionary:
	var response := await _request("/api/v1/rooms/creator-ticket/validate", {"ticket": ticket, "provision_instance_id": provision_instance_id}, "", {"X-World-Server-Credential": world_server_credential})
	var validated_account_id := str(response.data.get("account_id", ""))
	return {"accepted": response.status == 200 and not validated_account_id.is_empty(), "account_id": validated_account_id}

func _authenticate(path: String, account_name: String, password: String) -> Dictionary:
	if not OS.get_cmdline_user_args().has("--legacy-dedicated") and not _listen_api_allowed():
		return {"accepted": false, "reason": "Account API requires HTTPS; isolated debug tests may explicitly opt into numeric loopback HTTP."}
	var response := await _request(path, {
		"username": account_name.strip_edges(),
		"password": password,
	})
	if response.status not in [200, 201]:
		return {"accepted": false, "reason": str(response.data.get("error", "Authentication failed"))}
	var data: Dictionary = response.data
	access_token = str(data.get("token", ""))
	account_id = str(data.get("account_id", ""))
	username = str(data.get("username", ""))
	if access_token.is_empty() or account_id.is_empty() or username.is_empty():
		clear_session()
		return {"accepted": false, "reason": "Invalid authentication response"}
	return {"accepted": true}

static func listen_api_url_allowed(url: String, debug_build: bool, isolated: bool) -> bool:
	var secure := RegEx.new()
	secure.compile("^https://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:]+\\])(:[0-9]{1,5})?/?$")
	if secure.search(url) != null: return true
	if not debug_build or not isolated: return false
	var loopback := RegEx.new()
	loopback.compile("^http://(127\\.0\\.0\\.1|\\[::1\\])(:[0-9]{1,5})?/?$")
	return loopback.search(url) != null

func _listen_api_allowed() -> bool:
	var url := str(ProjectSettings.get_setting(API_URL_SETTING, DEFAULT_API_URL))
	if GameManager.editor_playtest != null and GameManager.editor_playtest.allows_account_api(url): return true
	return listen_api_url_allowed(url, OS.is_debug_build(), OS.get_environment("NOIKAR_ISOLATED_AUTH_API") == "1")

func _listen_request(path: String, body: Dictionary, bearer := "", room_credential := "") -> Dictionary:
	if not _listen_api_allowed(): return {"status": 0, "data": {"error": "HTTPS account API required"}}
	var headers := {}
	if not room_credential.is_empty(): headers["X-Room-Credential"] = room_credential
	return await _request(path, body, bearer, headers)

func create_listen_room(session_id: String) -> Dictionary:
	if access_token.is_empty() or session_id.is_empty(): return {"accepted": false}
	var response := await _listen_request("/api/v1/listen-rooms", {"session_id": session_id}, access_token)
	var data: Dictionary = response.data
	var identity = data.get("host_identity", {})
	if response.status != 201 or not identity is Dictionary or identity.get("account_id") != account_id or str(identity.get("username", "")).is_empty() or str(data.get("room_id", "")).is_empty() or str(data.get("room_credential", "")).is_empty():
		return {"accepted": false, "reason": str(data.get("error", "Room creation failed"))}
	var result := {"accepted": true, "room_id": str(data.room_id), "room_credential": str(data.room_credential), "host_identity": {"account_id": str(identity.account_id), "username": str(identity.username)}}
	if (data.get("game_port") is int or data.get("game_port") is float) and data.game_port == 24580: result.game_port = 24580
	return result

func issue_listen_ticket(room_id: String) -> Dictionary:
	if access_token.is_empty() or room_id.is_empty(): return {"accepted": false, "ticket": ""}
	var response := await _listen_request("/api/v1/listen-rooms/" + room_id.uri_encode() + "/tickets", {"issue": true}, access_token)
	var ticket := str(response.data.get("ticket", ""))
	return {"accepted": response.status == 201 and not ticket.is_empty(), "ticket": ticket}

func redeem_listen_ticket(room_id: String, ticket: String, room_credential: String) -> Dictionary:
	if room_id.is_empty() or ticket.is_empty() or room_credential.is_empty(): return {"accepted": false}
	var response := await _listen_request("/api/v1/listen-rooms/" + room_id.uri_encode() + "/admissions", {"ticket": ticket}, "", room_credential)
	var data: Dictionary = response.data
	if response.status != 200 or str(data.get("account_id", "")).is_empty() or str(data.get("username", "")).is_empty(): return {"accepted": false}
	return {"accepted": true, "account_id": str(data.account_id), "username": str(data.username)}

func close_listen_room(room_id: String, room_credential: String) -> void:
	if room_id.is_empty() or room_credential.is_empty(): return
	await _listen_request("/api/v1/listen-rooms/" + room_id.uri_encode() + "/close", {"close": true}, "", room_credential)

func clear_session() -> void:
	access_token = ""
	account_id = ""
	username = ""

func _request(path: String, body: Dictionary, bearer_token := "", extra_headers: Dictionary = {}) -> Dictionary:
	var request := HTTPRequest.new()
	request.timeout = 10.0
	# Never forward bearer/room credentials to a redirect target, including a
	# downgrade from the configured HTTPS API. Treat redirects as API failures.
	request.max_redirects = 0
	add_child(request)
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not bearer_token.is_empty():
		headers.append("Authorization: Bearer " + bearer_token)
	for header_name in extra_headers:
		headers.append(str(header_name) + ": " + str(extra_headers[header_name]))
	var url := str(ProjectSettings.get_setting(API_URL_SETTING, DEFAULT_API_URL)).trim_suffix("/") + path
	var err := request.request(url, headers, HTTPClient.METHOD_POST if not body.is_empty() else HTTPClient.METHOD_GET, JSON.stringify(body))
	if err != OK:
		request.queue_free()
		return {"status": 0, "data": {"error": "Backend unavailable"}}
	var completed: Array = await request.request_completed
	request.queue_free()
	var status := int(completed[1]) if completed.size() > 1 else 0
	var raw: PackedByteArray = completed[3] if completed.size() > 3 else PackedByteArray()
	var data: Variant = JSON.parse_string(raw.get_string_from_utf8()) if not raw.is_empty() else {}
	return {"status": status, "data": data if data is Dictionary else {}}
