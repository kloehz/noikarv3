# res://common/interest_manager.gd
## Distance-based interest management for state broadcasts.
##
## Netfox synchronizers ship with a PeerVisibilityFilter; registering a
## per-entity filter there stops state broadcasts to peers whose player is
## too far away to ever see the entity. The map keeps opposing teams
## hundreds of meters apart, so filtering mobs by proximity removes most
## cross-team sync traffic during laning.
##
## Notes:
## - Only the server broadcasts, so filters only matter there.
## - A filtered-out entity freezes on that client at its last known state.
##   SYNC_RADIUS is well beyond the camera's view, so the frozen copy is
##   never on screen; updates resume when the player comes back in range.
class_name InterestManager
extends RefCounted

## Entities farther than this from a player's own character are not synced
## to that player. Comfortably beyond the visible play area (~40m).
const SYNC_RADIUS := 90.0
const SYNC_RADIUS_SQ := SYNC_RADIUS * SYNC_RADIUS

## Registers the distance filter on every synchronizer of a mob entity.
## Server-only: filters are meaningless anywhere else.
static func apply_to_mob(entity: BaseEntity) -> void:
	if not entity.multiplayer.is_server():
		return
	var rb := entity.get_node_or_null("RollbackSynchronizer")
	if rb and rb.visibility_filter:
		_register(rb.visibility_filter, entity)
	var ss := entity.get_node_or_null("ServerState/StateSynchronizer")
	if ss and ss.visibility_filter:
		_register(ss.visibility_filter, entity)

static func _register(filter: PeerVisibilityFilter, entity: BaseEntity) -> void:
	filter.add_visibility_filter(InterestManager._is_visible_to_peer.bind(entity))
	filter.update_mode = PeerVisibilityFilter.UpdateMode.PER_TICK_LOOP

static func _is_visible_to_peer(peer_id: int, entity: BaseEntity) -> bool:
	if not is_instance_valid(entity):
		return true
	var players := entity.get_tree().root.find_child("Players", true, false)
	var player := players.get_node_or_null(str(peer_id)) if players else null
	if player == null or not (player is Node3D):
		# Peer has no avatar to measure from (joining, server, spectator):
		# keep the entity visible rather than dropping state blindly.
		return true
	return entity.global_position.distance_squared_to(player.global_position) <= SYNC_RADIUS_SQ
