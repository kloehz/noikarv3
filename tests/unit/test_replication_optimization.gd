extends GutTest

class FullFallbackSync extends StateSynchronizer:
	var full_calls: Array = []
	func _send_full_state(tick: int, peer: int = 0) -> void:
		full_calls.append([tick, peer])

class OnePeerFilter extends PeerVisibilityFilter:
	func update_visibility(_peers: PackedInt32Array = PackedInt32Array()) -> void:
		pass
	func get_visible_peers() -> Array[int]:
		return [2]

func _helper(path: String):
	assert_true(ResourceLoader.exists(path), path)
	return load(path).new() if ResourceLoader.exists(path) else null

func test_peer_cache_late_join_replacement_and_stale_reference_preserve_lookup() -> void:
	var cache = _helper("res://common/net/PeerAvatarCache.gd")
	if cache == null: return
	var players := Node3D.new()
	add_child_autofree(players)
	cache.bind_players(players)
	assert_null(cache.avatar(2), "Joining peer retains visible fallback")
	var first := Node3D.new()
	first.name = "2"
	players.add_child(first)
	assert_eq(cache.avatar(2), first)
	players.remove_child(first)
	var replacement := Node3D.new()
	replacement.name = "2"
	players.add_child(replacement)
	assert_eq(cache.avatar(2), replacement, "Detached but still alive old avatar is never reused")
	first.free()
	replacement.free()
	assert_null(cache.avatar(2))

func test_explicit_ack_profile_preserves_baseline_and_public_full_state_settings() -> void:
	var tuning = _helper("res://common/net/ReplicationTuning.gd")
	if tuning == null: return
	var sync := StateSynchronizer.new()
	sync.diff_ack_interval = 7
	sync.full_state_interval = 8
	assert_true(tuning.apply_profile(sync, "baseline", 30, true))
	assert_eq(sync.diff_ack_interval, 7)
	assert_true(tuning.apply_profile(sync, "diff_ack_100ms", 30, true))
	assert_eq(sync.diff_ack_interval, 2, "Vendored ACK condition uses tick > next, giving nominal 3 ticks")
	assert_true(tuning.apply_profile(sync, "diff_ack_100ms", 60, true))
	assert_eq(sync.diff_ack_interval, 5)
	assert_eq(sync.full_state_interval, 8)
	assert_false(tuning.apply_profile(sync, "unknown", 30, true))
	assert_false(tuning.apply_profile(sync, "diff_ack_100ms", 50, true))
	assert_false(tuning.apply_profile(sync, "diff_ack_100ms", 30, false))
	sync.visibility_filter.free()
	sync.free()

func test_native_full_fallback_survives_lost_stale_and_future_ack_references() -> void:
	var previous := NetworkRollback.enable_diff_states
	NetworkRollback.enable_diff_states = true
	var sync := FullFallbackSync.new()
	sync.visibility_filter.free()
	sync.visibility_filter = OnePeerFilter.new()
	sync.full_state_interval = 0
	for reference in [-1, 10, 1000]:
		sync.full_calls.clear()
		sync._ackd_state.clear()
		if reference >= 0: sync._ackd_state[2] = reference
		sync._broadcast_state(30, _PropertySnapshot.new())
		assert_eq(sync.full_calls, [[30, 2]], "Late join/lost ACK or missing old/future reference sends full state")
	sync._handle_peer_disconnected(2)
	assert_false(sync._ackd_state.has(2))
	sync.visibility_filter.free()
	sync.free()
	NetworkRollback.enable_diff_states = previous

class VisibilityActor extends BaseEntity:
	func _init() -> void:
		var state_node := Node.new()
		state_node.name = "ServerState"
		add_child(state_node)
	func _enter_tree() -> void:
		pass
	func _ready() -> void:
		pass

func test_interest_cache_preserves_radius_and_missing_avatar_fallback() -> void:
	var cache = _helper("res://common/net/PeerAvatarCache.gd")
	if cache == null: return
	var players := Node3D.new()
	add_child_autofree(players)
	cache.bind_players(players)
	players.set_meta(&"interest_avatar_cache", cache)
	var entity := VisibilityActor.new()
	add_child_autofree(entity)
	assert_true(InterestManager._is_visible_to_peer(2, entity, players))
	var avatar := Node3D.new()
	avatar.name = "2"
	players.add_child(avatar)
	avatar.position = Vector3(90, 0, 0)
	assert_true(InterestManager._is_visible_to_peer(2, entity, players))
	avatar.position.x = 90.001
	assert_false(InterestManager._is_visible_to_peer(2, entity, players))
	avatar.free()
	assert_true(InterestManager._is_visible_to_peer(2, entity, players))
