extends Node

## Owns the client access token and validates tokens for the dedicated server.
const DEFAULT_API_URL := "http://127.0.0.1:8080"
const API_URL_SETTING := "noikar/auth/api_url"

var access_token := ""
var account_id := ""
var username := ""

func _ready() -> void:
	if not ProjectSettings.has_setting(API_URL_SETTING):
		ProjectSettings.set_setting(API_URL_SETTING, DEFAULT_API_URL)

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

func clear_session() -> void:
	access_token = ""
	account_id = ""
	username = ""

func _request(path: String, body: Dictionary, bearer_token := "", extra_headers: Dictionary = {}) -> Dictionary:
	var request := HTTPRequest.new()
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
	var data: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return {"status": status, "data": data if data is Dictionary else {}}
