extends SceneTree
## Opt-in ABI/SDK/host-socket check only. Never reads friends or sends invites.
## This is deliberately NOT an end-to-end P2P or Netfox certification.
func _init() -> void:
	call_deferred("run")

func run() -> void:
	if OS.get_environment("NOIKAR_STEAM_PROBE") != "1" or OS.get_environment("NOIKAR_TEST_MODE") != "1":
		printerr("This manual probe requires explicit NOIKAR_STEAM_PROBE=1 and NOIKAR_TEST_MODE=1.")
		quit(64)
		return
	var report := {"engine": Engine.get_version_info().string, "engine_hash": Engine.get_version_info().hash, "architecture": Engine.get_architecture_name(), "singleton": Engine.has_singleton("Steam"), "peer_class": ClassDB.class_exists("SteamMultiplayerPeer"), "sdk_initialized": false, "host_socket": false, "p2p_verified": false, "netfox_over_steam_verified": false, "invitations_sent": 0}
	var manager := root.get_node("GameManager")
	var adapter: Node = manager.ensure_steam()
	report.sdk_initialized = adapter.initialize()
	if report.sdk_initialized:
		var peer := ClassDB.instantiate("SteamMultiplayerPeer") as MultiplayerPeer
		var methods: Array[String] = []
		for method in ["create_host", "create_client", "get_steam_id_for_peer_id"]:
			if peer.has_method(method): methods.append(method)
		report.peer_methods = methods
		peer.set("server_relay", true)
		report.host_socket = int(peer.call("create_host", 0)) == OK
		report.mode_channel_setters = []
		for mode in [MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED, MultiplayerPeer.TRANSFER_MODE_RELIABLE]:
			peer.transfer_mode = mode
			peer.transfer_channel = 0
			report.mode_channel_setters.append(peer.transfer_mode == mode and peer.transfer_channel == 0)
		peer.close()
	else:
		report.reason = adapter.last_error
	var output := "res://docs/evidence/steam-platform.json"
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t") + "\n")
	file.close()
	print(JSON.stringify(report))
	quit(0 if report.sdk_initialized and report.host_socket else 1)
