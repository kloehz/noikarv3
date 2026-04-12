extends Node

## Centralized environment detection and networking initialization.
## Uses Netfox for server authority and client prediction.

const DEFAULT_PORT = 7777

func _ready() -> void:
	if _is_headless_environment():
		_start_as_server()
	else:
		_start_as_client()

## Detect if running as a dedicated server or headless.
func _is_headless_environment() -> bool:
	return OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"

func _start_as_server() -> void:
	# Start as host - server will be created by ConnectionManager or command line
	EventBus.server_started.emit()
	print("[GameManager] Server environment ready")

func _start_as_client() -> void:
	# Client shows connection UI
	# The actual connection is handled by ConnectionManager
	EventBus.client_ready.emit()
	print("[GameManager] Client environment ready")
