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
@warning_ignore("unused_signal")
signal player_auth_token_submitted(token: String)
@warning_ignore("unused_signal")
signal game_server_authenticated(username: String)
@warning_ignore("unused_signal")
signal room_creator_ticket_validated(account_id: String)
@warning_ignore("unused_signal")
signal room_admission_rejected(reason: String)
@warning_ignore("unused_signal")
signal lobby_snapshot_received(snapshot: Dictionary)
@warning_ignore("unused_signal")
signal player_character_selected(character_id: String)

# Match signals
@warning_ignore("unused_signal")
signal match_started
@warning_ignore("unused_signal")
signal match_ended(winner_id: int)
@warning_ignore("unused_signal")
signal phase_changed(phase: int)  # MatchState.Phase; every effective phase entry
@warning_ignore("unused_signal")
signal team_assigned  # LOBBY team assignment completed (server)
@warning_ignore("unused_signal")
signal character_selection_cancelled
@warning_ignore("unused_signal")
signal character_selection_launching

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
