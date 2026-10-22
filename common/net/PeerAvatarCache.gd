extends RefCounted

## One weak cache per Players container. Normal name lookup is still the source
## of truth; no cached avatar survives removal/replacement/rejoin.
var _players: WeakRef
var _avatars: Dictionary = {}

func bind_players(players: Node) -> void:
	_players = weakref(players)
	players.child_entered_tree.connect(_invalidate_child)
	players.child_exiting_tree.connect(_invalidate_child)

func _invalidate_child(child: Node) -> void:
	if child.name.is_valid_int():
		_avatars.erase(child.name.to_int())

func avatar(peer_id: int) -> Node3D:
	var players = _players.get_ref() if _players != null else null
	if not is_instance_valid(players):
		return null
	var cached = _avatars[peer_id].get_ref() if _avatars.has(peer_id) else null
	if is_instance_valid(cached) and cached.get_parent() == players and cached.name == str(peer_id) and cached.is_inside_tree():
		return cached as Node3D
	_avatars.erase(peer_id)
	var current := players.get_node_or_null(str(peer_id)) as Node3D
	if current != null:
		_avatars[peer_id] = weakref(current)
	return current
