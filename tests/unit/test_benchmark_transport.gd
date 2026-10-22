extends GutTest
const Profile := preload("res://common/benchmark_profile.gd")

class ConnectedNoray extends "res://addons/netfox.noray/noray.gd":
	func is_connected_to_host() -> bool:
		return true

func test_defaults_preparation_and_trace_are_inert() -> void:
	assert_true(Profile.validate_remote_options("", {}))
	assert_eq(Profile.preparation_seconds("", false), 5.0)
	assert_eq(Profile.preparation_seconds("5", true), 5.0)
	assert_eq(Profile.preparation_seconds("15", true), 15.0)
	for bad in ["5.0", "15.0", "30", "05", "invalid"]:
		assert_eq(Profile.preparation_seconds(bad, true), -1.0)
	assert_eq(Profile.preparation_seconds("15", false), -1.0)
	var last := {}
	assert_true(Profile.trace_transition(last, "snapshot", 2, 3, 3, false))
	assert_true(Profile.trace_transition(last, "snapshot", 2, 3, 3, false))
	assert_false(Profile.trace_transition(last, "snapshot", 2, 3, 3, true))
	assert_true(Profile.trace_transition(last, "event", 2, 3, 3, true))
	assert_true(Profile.trace_transition(last, "snapshot", 3, 3, 5, true))
	assert_true(Profile.trace_transition(last, "snapshot", 2, 5, 3, true))

func test_validated_remote_server_and_client_contract() -> void:
	var server := {"remote": "1", "host": "8.8.8.8", "control": "24691", "registrar": "24693", "bind_port": "24690", "limit": "20", "client": "", "perf": "1", "backend": "http://127.0.0.1:24689", "fixed_population": "1", "mobs": "20"}
	assert_true(Profile.validate_remote_options("compare30", server))
	assert_true(Profile.validate_load20_options("compare30", server))
	for bad in [{"host":"127.0.0.1"},{"host":"192.168.1.1"},{"host":"8.8.8.999"},{"control":"8890"},{"registrar":"8809"},{"bind_port":"0"},{"backend":"http://remote.invalid"},{"limit":"6"},{"remote":"true"}]:
		var options := server.duplicate(); options.merge(bad, true)
		assert_false(Profile.validate_remote_options("compare30", options))
	assert_false(Profile.validate_remote_options("", server))
	var client := server.duplicate()
	client.merge({"client":"1", "bind_port":"0", "backend":"http://127.0.0.1:18090", "players":"20", "expected_mobs":"20", "fixed_route":"1", "index":"19"}, true)
	assert_true(Profile.validate_remote_options("compare60", client))
	assert_true(Profile.validate_load20_options("compare60", client))

func test_udp_occupied_bind_fails_without_faking_official_local_port() -> void:
	var blocker := PacketPeerUDP.new()
	assert_eq(blocker.bind(0, "127.0.0.1"), OK)
	var noray := ConnectedNoray.new()
	add_child_autofree(noray)
	# Only connection status is faked for the real UDP bind test. Do not let
	# the background TCP poll treat the unopened fixture socket as connected.
	noray.set_process(false)
	noray.on_command.emit("set-pid", "test-fixture-only")
	await get_tree().process_frame
	assert_eq(noray.pid, "test-fixture-only")
	var error: Error = await noray.register_remote(24693, 0.01, 0.01, blocker.get_local_port(), "127.0.0.1")
	assert_ne(error, OK)
	assert_eq(noray.local_port, -1)
	blocker.close()
