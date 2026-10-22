extends RefCounted
## Channel 0 keeps Godot's separate reliable/unreliable/ordered streams. Leave
## the channel count at the engine default, matching the existing Netfox path.
const GUEST_SLOTS := 5

static func host(port: int) -> Dictionary:
	if port < 0 or port > 65535:
		return {"error": ERR_INVALID_PARAMETER, "peer": null}
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, GUEST_SLOTS)
	if error != OK:
		peer.close()
	return {"error": error, "peer": peer if error == OK else null}

static func join(address: String, port: int) -> Dictionary:
	if address.strip_edges().is_empty() or port <= 0 or port > 65535:
		return {"error": ERR_INVALID_PARAMETER, "peer": null}
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		peer.close()
	return {"error": error, "peer": peer if error == OK else null}
