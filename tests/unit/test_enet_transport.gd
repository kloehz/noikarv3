extends GutTest
## Real loopback ENet endpoints exercise capacity and failure cleanup.
var _peers: Array[ENetMultiplayerPeer] = []

func after_each() -> void:
	for peer in _peers:
		peer.close()

func test_enet_accepts_five_guests() -> void:
	assert_true(ResourceLoader.exists("res://common/net/enet_transport.gd"), "LAN transport factory must exist")
	if not ResourceLoader.exists("res://common/net/enet_transport.gd"): return
	var factory = load("res://common/net/enet_transport.gd")
	assert_not_null(factory, "LAN transport factory must exist")
	if factory == null: return
	var hosted: Dictionary = factory.host(0)
	assert_eq(hosted.error, OK)
	var server: ENetMultiplayerPeer = hosted.peer
	_peers.append(server)
	var port := server.host.get_local_port()
	for index in 5:
		var joined: Dictionary = factory.join("127.0.0.1", port)
		assert_eq(joined.error, OK)
		_peers.append(joined.peer)
	for frame in 120:
		for peer in _peers: peer.poll()
		if server.host.get_peers().size() == 5: break
		await get_tree().process_frame
	assert_eq(server.host.get_peers().size(), 5, "Host plus five guests is the six-human room")
	var extra: Dictionary = factory.join("127.0.0.1", port)
	_peers.append(extra.peer)
	for frame in 20:
		for peer in _peers: peer.poll()
		await get_tree().process_frame
	assert_eq(server.host.get_peers().size(), 5, "A seventh human cannot consume a transport slot")

func test_invalid_ports_do_not_create_live_peers() -> void:
	assert_true(ResourceLoader.exists("res://common/net/enet_transport.gd"))
	if not ResourceLoader.exists("res://common/net/enet_transport.gd"): return
	var factory = load("res://common/net/enet_transport.gd")
	assert_not_null(factory)
	if factory == null: return
	for port in [-1, 65536]:
		var result: Dictionary = factory.host(port)
		assert_eq(result.error, ERR_INVALID_PARAMETER)
		assert_null(result.peer)
	for port in [-1, 0, 65536]:
		var result: Dictionary = factory.join("127.0.0.1", port)
		assert_eq(result.error, ERR_INVALID_PARAMETER)
		assert_null(result.peer)
