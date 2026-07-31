extends GutTest
## Regression tests for the host-flow hang on noray error replies.
##
## Background: noray's host.commands.mjs sends `error Failed to provision
## server` (and similar) when bind/spawn fail. Before the fix the client
## ignored the `error` command entirely and the host flow hung forever on
## `await Noray.on_host_ready`. After the fix the Noray client surfaces
## `on_error` and ConnectionManager races the two signals.

const NorayScript = preload("res://addons/netfox.noray/noray.gd")

func _make_noray() -> Noray:
	# Stand up an OfflineMultiplayerPeer so the netfox logger doesn't spam
	# "No multiplayer peer is assigned" while our handler runs. The peer is
	# only used for log tagging — none of the asserts depend on it.
	if not multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	var noray: Noray = NorayScript.new()
	noray.name = "NorayUnderTest"
	add_child_autofree(noray)
	return noray

func _ingest(noray: Noray, raw: String) -> void:
	noray._protocol.ingest(raw)
	await wait_process_frames(2)

func test_error_command_emits_on_error_signal() -> void:
	var noray: Noray = _make_noray()
	var captured: Array = []
	noray.on_error.connect(func(reason: String) -> void: captured.append(reason))
	await _ingest(noray, "error Failed to provision server\n")
	assert_eq(captured.size(), 1, "Noray must surface error commands so the host flow can fail fast")
	assert_eq(captured[0], "Failed to provision server", "the full error text must be preserved (protocol split must keep everything after the command)")

func test_on_error_signal_does_not_leak_into_on_host_ready() -> void:
	var noray: Noray = _make_noray()
	# Lambdas in GDScript 4 capture primitives by value, so we route the
	# counters through Arrays (reference types) to assert on them later.
	var ready_count: Array = [0]
	var error_count: Array = [0]
	noray.on_host_ready.connect(func(_oid: String) -> void: ready_count[0] += 1)
	noray.on_error.connect(func(_reason: String) -> void: error_count[0] += 1)
	await _ingest(noray, "error Failed to provision server\n")
	await _ingest(noray, "error Invalid creator ticket\n")
	assert_eq(ready_count[0], 0, "error replies must NOT be confused with host-ready")
	assert_eq(error_count[0], 2, "every error reply must surface exactly once")

func test_host_ready_still_emits_when_no_error_intervenes() -> void:
	var noray: Noray = _make_noray()
	var ready: Array = []
	var errors: Array = []
	noray.on_host_ready.connect(func(oid: String) -> void: ready.append(oid))
	noray.on_error.connect(func(reason: String) -> void: errors.append(reason))
	await _ingest(noray, "host-ready my-oid\n")
	assert_eq(ready, ["my-oid"])
	assert_eq(errors, [])

func test_multiword_data_is_preserved() -> void:
	## Pins the protocol-handler fix: the data payload is everything after the
	## first space, not just the first token. Without this the error text would
	## be silently truncated and the user would only see "Failed" on the UI.
	var noray: Noray = _make_noray()
	var captured: Array = []
	noray.on_error.connect(func(reason: String) -> void: captured.append(reason))
	await _ingest(noray, "error Creator ticket is required\n")
	assert_eq(captured, ["Creator ticket is required"])

func test_disconnect_clears_stale_registration_identity() -> void:
	var noray: Noray = _make_noray()
	noray._oid = "old-oid"
	noray._pid = "old-pid"
	noray._local_port = 54321

	noray.disconnect_from_host()

	assert_eq(noray.oid, "")
	assert_eq(noray.pid, "")
	assert_eq(noray.local_port, -1)

func test_register_host_clears_identity_before_waiting_for_new_pid() -> void:
	var noray: Noray = _make_noray()
	noray._oid = "old-oid"
	noray._pid = "removed-host-pid"
	noray._local_port = 54321

	# The disconnected test peer makes the command fail, but registration
	# state must still be cleared before any caller checks oid/pid.
	assert_eq(noray.register_host(), ERR_CONNECTION_ERROR)
	assert_eq(noray.oid, "")
	assert_eq(noray.pid, "")
	assert_eq(noray.local_port, -1)
