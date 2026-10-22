extends SceneTree
## Runs only against the disposable API/DB created by the Go integration fixture.
## Credentials arrive through child-only environment variables and are never logged.

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var auth = root.get_node("AuthService")
	if OS.get_environment("NOIKAR_FIXTURE_REDIRECT_PROBE") == "1":
		var redirected: Dictionary = await auth._listen_request("/fixture-redirect", {}, "fixture-only-bearer")
		var blocked: bool = redirected.status == 307
		print("LISTEN_API_RESULT ", JSON.stringify({"ok": blocked, "redirect_blocked": blocked}))
		quit(0 if blocked else 1)
		return
	auth.access_token = OS.get_environment("NOIKAR_FIXTURE_HOST_TOKEN")
	auth.account_id = OS.get_environment("NOIKAR_FIXTURE_HOST_ID")
	auth.username = "host-fixture"
	var created: Dictionary = await auth.create_listen_room("godot-http-fixture")
	if not created.get("accepted", false):
		print("LISTEN_API_RESULT ", JSON.stringify({"ok": false, "stage": "create"}))
		quit(1)
		return
	auth.access_token = OS.get_environment("NOIKAR_FIXTURE_GUEST_TOKEN")
	auth.account_id = OS.get_environment("NOIKAR_FIXTURE_GUEST_ID")
	auth.username = "guest-fixture"
	var issued: Dictionary = await auth.issue_listen_ticket(created.room_id)
	var validated: Dictionary = await auth.redeem_listen_ticket(created.room_id, str(issued.get("ticket", "")), created.room_credential)
	var replay: Dictionary = await auth.redeem_listen_ticket(created.room_id, str(issued.get("ticket", "")), created.room_credential)
	await auth.close_listen_room(created.room_id, created.room_credential)
	var closed: Dictionary = await auth.issue_listen_ticket(created.room_id)
	var ok: bool = issued.get("accepted", false) and validated.get("accepted", false) and validated.get("account_id") == auth.account_id and not replay.get("accepted", false) and not closed.get("accepted", false) and not auth.access_token.is_empty()
	print("LISTEN_API_RESULT ", JSON.stringify({"ok": ok, "real_http": true, "real_postgres_fixture": true, "host_identity_local": created.host_identity.account_id == OS.get_environment("NOIKAR_FIXTURE_HOST_ID"), "guest_identity_validated": validated.get("account_id") == auth.account_id, "replay_denied": not replay.get("accepted", false), "closed_room_denied": not closed.get("accepted", false), "login_preserved": not auth.access_token.is_empty()}))
	auth.clear_session()
	quit(0 if ok else 1)
