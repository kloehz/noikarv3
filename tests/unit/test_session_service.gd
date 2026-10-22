extends GutTest
## Exercise the real peer owner; compatibility is not account admission.
var _service: Node
var _previous_peer: MultiplayerPeer

func before_each() -> void:
	_previous_peer = multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = null
	if ResourceLoader.exists("res://common/net/session_service.gd"):
		_service = load("res://common/net/session_service.gd").new()
		add_child(_service)

func after_each() -> void:
	if is_instance_valid(_service):
		_service.close()
		for frame in 4: await get_tree().process_frame
		_service.free()
	multiplayer.multiplayer_peer = _previous_peer

func _require_service() -> bool:
	assert_not_null(_service, "Session owner must exist")
	return _service != null

func _host() -> int:
	_service.configure_room("fixture-room", "room-scoped-credential")
	return _service.host_lan(0, {"account_id": "fixture-account", "username": "Fixture"})

func test_six_player_capacity_contract() -> void:
	if not _require_service(): return
	assert_eq(_service.MAX_PLAYERS, 6)
	assert_eq(_service.MAX_PLAYERS_PER_TEAM, 3)
	assert_eq(_service.PROTOCOL_VERSION, 1)

func test_menu_has_no_active_simulation() -> void:
	if not _require_service(): return
	assert_eq(_service.role, "MENU")
	assert_eq(_service.phase, "menu")
	assert_null(multiplayer.multiplayer_peer)
	assert_false(NetworkEvents.is_server())

func test_second_peer_attachment_is_rejected() -> void:
	if not _require_service(): return
	assert_eq(_host(), OK)
	var first: MultiplayerPeer = multiplayer.multiplayer_peer
	var extra := ENetMultiplayerPeer.new()
	assert_eq(extra.create_server(0), OK)
	assert_eq(_service.attach_host(extra, "enet", {}), ERR_ALREADY_IN_USE)
	assert_same(multiplayer.multiplayer_peer, first)
	extra.close()

func test_close_is_idempotent() -> void:
	if not _require_service(): return
	assert_eq(_host(), OK)
	await get_tree().process_frame
	watch_signals(_service)
	var old_generation: int = _service.generation
	_service.close("Fixture finished")
	_service.close("Again")
	for frame in 4: await get_tree().process_frame
	assert_eq(_service.generation, old_generation + 1)
	assert_eq(_service.phase, "menu")
	assert_eq(_service.room_id, "")
	assert_eq(_service._room_credential, "")
	assert_null(multiplayer.multiplayer_peer)
	assert_signal_emit_count(_service, "session_ended", 1)
	assert_false(NetworkEvents.is_server())
	assert_eq(NetworkTime._state, NetworkTime._STATE_INACTIVE)

func test_late_callback_after_close_is_ignored() -> void:
	if not _require_service(): return
	assert_eq(_host(), OK)
	var old_generation: int = _service.generation
	_service.close()
	_service._on_transport_connected(old_generation)
	for frame in 4: await get_tree().process_frame
	assert_eq(_service.phase, "menu")
	assert_null(multiplayer.multiplayer_peer)
	assert_eq(NetworkTime._state, NetworkTime._STATE_INACTIVE)

func test_reconnect_waits_for_old_netfox_stop() -> void:
	if not _require_service(): return
	assert_eq(_host(), OK)
	for frame in 2: await get_tree().process_frame
	_service.close()
	assert_eq(_service.host_lan(0, {}), ERR_ALREADY_IN_USE)
	for frame in 4: await get_tree().process_frame
	assert_eq(_host(), OK)

func test_compatibility_checks_full_build_and_dependency_content() -> void:
	if not _require_service(): return
	var metadata: Dictionary = _service.compatibility_metadata()
	assert_eq(metadata.engine, "4.8.beta1.official.4d10419ca")
	assert_eq(str(metadata.addons).length(), 64)
	assert_true(_service.is_compatible(metadata))
	assert_true(_service.is_compatible(JSON.parse_string(JSON.stringify(metadata))), "Wire JSON must retain protocol compatibility")
	for key in ["protocol", "engine", "addons"]:
		var other := metadata.duplicate()
		other[key] = "different"
		assert_false(_service.is_compatible(other), key)

func test_identity_cannot_smuggle_account_credentials() -> void:
	if not _require_service(): return
	_service.configure_room("fixture-room", "scoped-room-secret")
	assert_eq(_service.host_lan(0, {"account_id": "id", "username": "name", "access_token": "must-not-forward"}), ERR_INVALID_PARAMETER)
	assert_null(multiplayer.multiplayer_peer)

func test_late_initial_clock_sync_cannot_restart_a_closed_session() -> void:
	if not _require_service(): return
	var server := ENetMultiplayerPeer.new()
	var guest := ENetMultiplayerPeer.new()
	assert_eq(server.create_server(0), OK)
	assert_eq(guest.create_client("127.0.0.1", server.host.get_local_port()), OK)
	assert_eq(_service.attach_client(guest, "enet"), OK)
	# This fixture isolates clock cancellation from the separate compatibility
	# handshake. The raw ENet endpoint does not implement account/metadata auth.
	(multiplayer as SceneMultiplayer).auth_callback = Callable()
	var deadline := Time.get_ticks_msec() + 2000
	while Time.get_ticks_msec() < deadline:
		server.poll()
		multiplayer.poll()
		if NetworkTime._state == NetworkTime._STATE_SYNCING: break
		await get_tree().create_timer(0.005).timeout
	# The real Netfox start is awaiting initial sync. Its completion can arrive
	# after a user cancels, or on the next session's first synchronization.
	assert_eq(NetworkTime._state, NetworkTime._STATE_SYNCING, JSON.stringify({"peer_status": guest.get_connection_status(), "known_peers": multiplayer.get_peers(), "events_enabled": NetworkEvents.enabled, "phase": _service.phase}))
	_service.close()
	NetworkTimeSynchronizer.on_initial_sync.emit()
	assert_eq(NetworkTime._state, NetworkTime._STATE_INACTIVE)
	server.close()

func _cleanup_fixture(completed: Array) -> void:
	await get_tree().process_frame
	completed.append(true)

func test_close_finishes_world_cleanup_before_allowing_another_attachment() -> void:
	if not _require_service(): return
	assert_true(_service.get("_world_cleanup") is Callable, "Session close must await the persistent owner's world cleanup")
	if not _service.get("_world_cleanup") is Callable: return
	var completed: Array = []
	_service._world_cleanup = _cleanup_fixture.bind(completed)
	assert_eq(_host(), OK)
	_service.close()
	assert_eq(_service.host_lan(0, {}), ERR_ALREADY_IN_USE)
	for frame in 8: await get_tree().process_frame
	assert_eq(completed.size(), 1)
	assert_eq(_service.phase, "menu")
