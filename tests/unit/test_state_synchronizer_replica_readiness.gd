extends GutTest

var _previous_peer: MultiplayerPeer

func before_each() -> void:
	_previous_peer = multiplayer.multiplayer_peer

func after_each() -> void:
	multiplayer.multiplayer_peer = _previous_peer

func _free_visibility_filter(sync: StateSynchronizer) -> void:
	var filter: Node = sync.visibility_filter
	if is_instance_valid(filter) and filter.get_parent() == null:
		filter.free()

func _make_sync() -> StateSynchronizer:
	var root := Node.new()
	root.name = "Root"
	root.set_multiplayer_authority(1)
	add_child_autofree(root)

	var sync := StateSynchronizer.new()
	sync.name = "StateSynchronizer"
	sync.root = root
	sync.set_multiplayer_authority(1)
	root.add_child(sync)
	return sync

func test_authority_readiness_filter_fails_closed_until_exact_peer_ack() -> void:
	var sync := _make_sync()
	sync._install_replica_ready_visibility_filter()

	assert_false(sync.visibility_filter.get_visibility_for(2),
		"Authority must reject peers before that peer acknowledges this synchronizer")
	assert_true(sync._mark_replica_ready_if_connected(2, PackedInt32Array([2, 3])))
	assert_true(sync.visibility_filter.get_visibility_for(2),
		"Acknowledged connected peer becomes visible for this synchronizer")
	assert_false(sync.visibility_filter.get_visibility_for(3),
		"A different late/unacknowledged peer remains rejected")

func test_readiness_ack_rejects_unconnected_sender() -> void:
	var sync := _make_sync()
	sync._install_replica_ready_visibility_filter()

	assert_false(sync._mark_replica_ready_if_connected(4, PackedInt32Array([2, 3])),
		"Authority must not mark stale or spoofed peer IDs ready")
	assert_false(sync.visibility_filter.get_visibility_for(4))

func test_readiness_filter_composes_with_existing_visibility_filters() -> void:
	var sync := _make_sync()
	sync.visibility_filter.add_visibility_filter(func(peer_id: int) -> bool:
		return peer_id == 2
	)
	sync._install_replica_ready_visibility_filter()
	sync._mark_replica_ready_if_connected(2, PackedInt32Array([2, 3]))
	sync._mark_replica_ready_if_connected(3, PackedInt32Array([2, 3]))

	assert_true(sync.visibility_filter.get_visibility_for(2),
		"Peer allowed by existing filters and readiness remains visible")
	assert_false(sync.visibility_filter.get_visibility_for(3),
		"Readiness must not replace or clear existing visibility filters")

func test_peer_disconnect_removes_readiness_and_ack_state() -> void:
	var sync := _make_sync()
	sync._install_replica_ready_visibility_filter()
	sync._mark_replica_ready_if_connected(2, PackedInt32Array([2]))
	sync._ackd_state[2] = 10

	sync._handle_peer_disconnected(2)

	assert_false(sync.visibility_filter.get_visibility_for(2),
		"Disconnected peer must fail closed until a fresh per-node acknowledgement")
	assert_false(sync._ackd_state.has(2),
		"Disconnect must not leave stale per-peer state acknowledgements")

func test_replica_side_readiness_filter_does_not_gate_client_visibility() -> void:
	var sync := _make_sync()
	sync.set_multiplayer_authority(2)
	sync._install_replica_ready_visibility_filter()

	assert_true(sync.visibility_filter.get_visibility_for(2),
		"Non-authority replicas should only send readiness, not gate their local visibility")

func test_static_replica_without_multiplayer_peer_skips_ack_but_waits_for_connection() -> void:
	multiplayer.multiplayer_peer = null
	var sync := _make_sync()
	sync.set_multiplayer_authority(2)

	assert_false(sync._can_send_replica_ready_ack(),
		"Static replicas that enter before a client peer exists must not run authority checks or send once-and-done")
	assert_true(multiplayer.connected_to_server.is_connected(sync._handle_connected_to_server),
		"Static replicas must stay subscribed so connected_to_server retries the per-node readiness ACK")
	_free_visibility_filter(sync)

func test_connected_to_server_signal_connect_and_disconnect_are_symmetric_and_safe() -> void:
	var sync := _make_sync()
	sync._disconnect_connected_to_server_signal()
	sync._connect_connected_to_server_signal()
	sync._connect_connected_to_server_signal()
	assert_true(multiplayer.connected_to_server.is_connected(sync._handle_connected_to_server),
		"Readiness retry signal should be present after repeated safe connects")

	sync._disconnect_connected_to_server_signal()
	sync._disconnect_connected_to_server_signal()
	assert_false(multiplayer.connected_to_server.is_connected(sync._handle_connected_to_server),
		"Readiness retry signal should be absent after repeated safe disconnects")
