extends "res://tests/isolated_gut_test.gd"

func _script():
	assert_true(ResourceLoader.exists("res://common/net/editor_vps_playtest.gd"), "F5 needs an isolated editor profile, not legacy HTTP fallback")
	return load("res://common/net/editor_vps_playtest.gd") if ResourceLoader.exists("res://common/net/editor_vps_playtest.gd") else null

func test_export_release_and_test_bootstrap_cannot_activate_editor_profile() -> void:
	var script = _script()
	if script == null: return
	assert_false(script.profile_allowed(false, true, false))
	assert_false(script.profile_allowed(true, false, false))
	assert_false(script.profile_allowed(true, true, true))
	assert_true(script.profile_allowed(true, true, false))

func test_profile_rejects_shell_targets_wrong_ports_and_non_numeric_game_hosts() -> void:
	var script = _script()
	if script == null: return
	var profile := {"ssh_target": "root@72.60.58.24", "game_host": "72.60.58.24", "local_port": 19091, "remote_port": 18491, "api_build": "noikar-f5-test-build"}
	assert_true(script.valid_profile(profile))
	for changes in [{"ssh_target": "root@host;touch /tmp/unsafe"}, {"game_host": "other-host.example"}, {"local_port": 8090}, {"remote_port": 8090}, {"api_build": ""}]:
		var invalid := profile.duplicate()
		invalid.merge(changes, true)
		assert_false(script.valid_profile(invalid))

func test_inactive_profile_does_not_authorize_loopback_password_or_room_calls() -> void:
	var script = _script()
	if script == null: return
	var service = script.new()
	add_child_autofree(service)
	assert_false(service.ready_for_login())
	assert_false(service.allows_account_api("http://127.0.0.1:19091"))

func test_vps_test_does_not_initialize_unrelated_steam_overlay() -> void:
	assert_true(GameManager.has_method("should_auto_initialize_steam"))
	if not GameManager.has_method("should_auto_initialize_steam"): return
	assert_false(GameManager.should_auto_initialize_steam(false, false, true, true))
	assert_true(GameManager.should_auto_initialize_steam(false, false, false, true))
	assert_false(GameManager.should_auto_initialize_steam(true, false, false, true))
