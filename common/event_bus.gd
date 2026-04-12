# common/event_bus.gd
extends Node

## Global Event Bus for decoupled communication.
## Follows the pattern of "Server Authority, Client Representation".

# Network signals
signal server_started
signal client_ready  # Client UI is ready to show
signal client_connected(peer_id: int)
signal client_disconnected(peer_id: int)
signal player_name_submitted(name: String)

# Match signals
signal match_started
signal match_ended(winner_id: int)

# Entity signals
signal entity_spawned(entity: Node3D)
signal entity_died(entity: Node3D)
signal entity_damaged(entity: Node3D, amount: int, source: Node)

# Visual/Audio signals
signal visual_effect_requested(entity: Node3D, effect_name: String)
signal audio_effect_requested(entity: Node3D, effect_name: String)
