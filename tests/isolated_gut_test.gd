extends GutTest
## Presentation/unit fixtures need a local authority ID, not a running server.
var _fixture_previous_peer: MultiplayerPeer
var _fixture_previous_headless_client: bool

func before_each() -> void:
	_fixture_previous_peer = multiplayer.multiplayer_peer
	_fixture_previous_headless_client = BenchmarkProfile.headless_client
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func after_each() -> void:
	multiplayer.multiplayer_peer = _fixture_previous_peer
	BenchmarkProfile.headless_client = _fixture_previous_headless_client

func enable_client_presentation() -> void:
	# Reuse the existing headless-client role, not a production visual bypass.
	BenchmarkProfile.headless_client = true
