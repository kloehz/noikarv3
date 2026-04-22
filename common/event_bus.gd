# common/event_bus.gd
extends Node

## Global Event Bus for decoupled communication.
## Follows the pattern of "Server Authority, Client Representation".

# Network signals
@warning_ignore("unused_signal")
signal server_started
@warning_ignore("unused_signal")
signal client_ready  # Client UI is ready to show
@warning_ignore("unused_signal")
signal client_connected(peer_id: int)
@warning_ignore("unused_signal")
signal client_disconnected(peer_id: int)
@warning_ignore("unused_signal")
signal player_name_submitted(name: String)

# Match signals
@warning_ignore("unused_signal")
signal match_started
@warning_ignore("unused_signal")
signal match_ended(winner_id: int)

# Entity signals
@warning_ignore("unused_signal")
signal entity_spawned(entity: Node3D)
@warning_ignore("unused_signal")
signal entity_died(entity: Node3D)
@warning_ignore("unused_signal")
signal entity_damaged(entity: Node3D, amount: int, source: Node)

# Visual/Audio signals
@warning_ignore("unused_signal")
signal visual_effect_requested(entity: Node3D, effect_name: String)
@warning_ignore("unused_signal")
signal audio_effect_requested(entity: Node3D, effect_name: String)
