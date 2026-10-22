extends RefCounted

## Room-local server index. Only bounded XZ avoidance uses this broad phase;
## global nearest/hostile/threat queries intentionally keep their full scans.
const CELL_SIZE := 2.4
var _records: Dictionary = {}
var _cells: Dictionary = {}
var _parents: Dictionary = {}

func _cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL_SIZE), floori(position.z / CELL_SIZE))

func register_actor(actor: Node3D, group: StringName) -> void:
	unregister_actor(actor)
	var id := actor.get_instance_id()
	_records[id] = {"actor": weakref(actor), "group": group, "cell": _cell(actor.global_position)}
	var parent := actor.get_parent_node_3d()
	if parent != null:
		_parents[parent.get_instance_id()] = {"node": weakref(parent), "transform": parent.global_transform}
	_add_cell(id)

func _add_cell(id: int) -> void:
	var record: Dictionary = _records[id]
	var key := Vector3i(record.cell.x, record.cell.y, 0 if record.group == &"mobs" else 1)
	if not _cells.has(key):
		_cells[key] = {}
	_cells[key][id] = true

func unregister_actor(actor: Node3D) -> void:
	_remove_id(actor.get_instance_id())

func _remove_id(id: int) -> void:
	if not _records.has(id):
		return
	var record: Dictionary = _records[id]
	var key := Vector3i(record.cell.x, record.cell.y, 0 if record.group == &"mobs" else 1)
	if _cells.has(key):
		_cells[key].erase(id)
		if _cells[key].is_empty(): _cells.erase(key)
	_records.erase(id)

func update_actor(actor: Node3D) -> void:
	var id := actor.get_instance_id()
	if not _records.has(id):
		return
	var record: Dictionary = _records[id]
	var cell := _cell(actor.global_position)
	if cell != record.cell:
		var group: StringName = record.group
		_remove_id(id)
		_records[id] = {"actor": weakref(actor), "group": group, "cell": cell}
		_add_cell(id)

func _refresh_parent_transforms() -> void:
	var changed := false
	for id in _parents.keys():
		var record: Dictionary = _parents[id]
		var parent = record.node.get_ref()
		if not is_instance_valid(parent):
			_parents.erase(id)
		elif parent.global_transform != record.transform:
			record.transform = parent.global_transform
			changed = true
	if changed:
		# Container teleports can precede deferred global-transform notices.
		for id in _records.keys():
			var actor = _records[id].actor.get_ref()
			if is_instance_valid(actor): update_actor(actor)
			else: _remove_id(id)

func query(position: Vector3, radius: float, group: StringName) -> Array[Node3D]:
	_refresh_parent_transforms()
	var result: Array[Node3D] = []
	var lower := _cell(position - Vector3(radius, 0, radius))
	var upper := _cell(position + Vector3(radius, 0, radius))
	for x in range(lower.x, upper.x + 1):
		for z in range(lower.y, upper.y + 1):
			var key := Vector3i(x, z, 0 if group == &"mobs" else 1)
			for id in _cells.get(key, {}).keys():
				var actor = _records[id].actor.get_ref()
				if not is_instance_valid(actor) or not actor.is_inside_tree():
					_remove_id(id)
					continue
				var offset: Vector3 = actor.global_position - position
				offset.y = 0
				if actor.is_in_group(group) and offset.length_squared() < radius * radius:
					result.append(actor)
	# get_nodes_in_group uses scene-tree order; do not alter floating additions
	# or tie-breaking when cells/register order differs or children reorder.
	result.sort_custom(func(a: Node3D, b: Node3D) -> bool: return b.is_greater_than(a))
	return result
