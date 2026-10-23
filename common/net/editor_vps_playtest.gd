extends Node
## Local editor-only SSH tunnel. Its profile lives in .godot, never in exports.
signal status_changed(message: String)
const PROFILE_PATH := "res://.godot/noikar_vps_playtest.cfg"
var active := false
var last_error := ""
var game_host := ""
var api_url := "http://127.0.0.1:19091"
var _profile: Dictionary = {}
var _pid := -1
var _stop_path := ""
var _ready_for_login := false

static func profile_allowed(debug_build: bool, editor_binary: bool, test_bootstrap: bool) -> bool:
	return debug_build and editor_binary and not test_bootstrap

static func valid_profile(profile: Dictionary) -> bool:
	var target := RegEx.new()
	target.compile("^[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+$")
	return profile.get("ssh_target") is String and target.search(profile.ssh_target) != null and profile.get("game_host") is String and profile.game_host.is_valid_ip_address() and profile.get("local_port") == 19091 and profile.get("remote_port") == 18491 and profile.get("api_build") is String and profile.api_build.begins_with("noikar-f5-") and profile.api_build.length() <= 128

func load_profile() -> bool:
	if not profile_allowed(OS.is_debug_build(), OS.has_feature("editor"), OS.get_environment("NOIKAR_TEST_MODE") == "1" or OS.get_cmdline_user_args().has("--noikar-test-mode")): return false
	# An explicitly selected backend (including owned integration fixtures) wins
	# over this machine's default F5 profile. Never redirect its account requests.
	if not OS.get_environment("NOIKAR_BACKEND_URL").strip_edges().is_empty(): return false
	var config := ConfigFile.new()
	if config.load(PROFILE_PATH) != OK or config.get_value("playtest", "enabled", false) != true: return false
	active = true
	for key in ["ssh_target", "game_host", "local_port", "remote_port", "api_build"]:
		_profile[key] = config.get_value("playtest", key)
	if not valid_profile(_profile):
		_error("Invalid isolated VPS editor profile. No remote login was attempted.")
		return true
	game_host = str(_profile.game_host)
	_start_tunnel.call_deferred()
	return true

func ready_for_login() -> bool:
	return active and _ready_for_login and _pid > 0 and OS.is_process_running(_pid)

func allows_account_api(url: String) -> bool:
	return OS.is_debug_build() and OS.has_feature("editor") and ready_for_login() and url == api_url

func _start_tunnel() -> void:
	# Never attach to an existing listener: it may be an unrelated local service.
	var check := TCPServer.new()
	if check.listen(19091, "127.0.0.1") != OK:
		_error("Local VPS tunnel port 19091 is occupied. Close the previous test before pressing F5 again.")
		return
	check.stop()
	status_changed.emit("Connecting to the isolated VPS through SSH...")
	_stop_path = ProjectSettings.globalize_path("res://.godot/noikar-vps-tunnel-%d-%d.stop" % [OS.get_process_id(), Time.get_ticks_msec()])
	_pid = OS.create_process("/usr/bin/python3", PackedStringArray([ProjectSettings.globalize_path("res://tools/editor_vps_tunnel.py"), "--parent", str(OS.get_process_id()), "--target", str(_profile.ssh_target), "--stop-file", _stop_path]))
	if _pid <= 0:
		_error("Could not start the isolated VPS SSH tunnel.")
		return
	var until := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < until and OS.is_process_running(_pid):
		var request := HTTPRequest.new()
		request.timeout = 1.0
		request.max_redirects = 0
		add_child(request)
		var code := request.request(api_url + "/api/v1/health")
		if code == OK:
			var response: Array = await request.request_completed
			if response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200:
				var body: PackedByteArray = response[3]
				var data = JSON.parse_string(body.get_string_from_utf8()) if not body.is_empty() else null
				if data is Dictionary and data.get("version") == _profile.api_build and OS.is_process_running(_pid):
					request.queue_free()
					AuthService.clear_session()
					ProjectSettings.set_setting("noikar/auth/api_url", api_url)
					_ready_for_login = true
					status_changed.emit("Isolated VPS connected securely. Sign in or create a test account.")
					return
		request.queue_free()
		await get_tree().create_timer(0.25).timeout
	_stop_tunnel()
	_error("The isolated VPS could not be verified. Check SSH access and the test services; login is disabled.")

func _process(_delta: float) -> void:
	if _ready_for_login and not OS.is_process_running(_pid):
		_ready_for_login = false
		if GameManager.session.phase not in ["menu", "closing"]: GameManager.session.close("VPS SSH connection ended")
		_error("The secure VPS connection ended. Stop and restart F5 to reconnect.")

func _error(message: String) -> void:
	last_error = message
	status_changed.emit(message)

func _stop_tunnel() -> void:
	_ready_for_login = false
	if _pid > 0 and OS.is_process_running(_pid) and not _stop_path.is_empty():
		# Request graceful guardian cleanup; killing the guardian itself could
		# strand SSH. It also detects abrupt game termination independently.
		var stop := FileAccess.open(_stop_path, FileAccess.WRITE)
		if stop != null:
			stop.store_string("stop")
			stop.close()
	_pid = -1

func _exit_tree() -> void:
	_stop_tunnel()
