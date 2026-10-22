extends Node
## Opt-in observation only. Stage/lifetime events are immediate; ACK/phase state
## is sampled at <=1 Hz, not a timestamp of RPC receipt. No peer/account/path data.

const MAX_ROWS := 192
const POLL_SECONDS := 1.0
const COUNT_FIELDS := ["phase", "players", "mobs", "expected_mobs", "connected_peers", "generation", "entity_kind", "sync_count", "initialized_sync_count", "replica_ack_count"]
const BOOL_FIELDS := ["in_game", "avatar_present", "owned_state_present", "owned_sync_present", "owned_sync_initialized", "selection_gate_open", "workload_gate_open", "initialized", "history_available"]

var _enabled := false
var _role := "client"
var _index := -1
var _stage := 0
var _rows := 0
var _elapsed := 0.0
var _generation := 0
var _provider: Callable
var _tracked := {}

func _ready() -> void:
	set_process(false)

func start(role: String, index: int, player_count: int, provider: Callable, requested: String) -> bool:
	if requested != "1" or role not in ["client", "server"] or player_count not in [10, 20]:
		return false
	if (role == "client" and (index < 0 or index >= player_count)) or (role == "server" and index != -1):
		return false
	_role = role
	_index = index
	_provider = provider
	_enabled = true
	get_tree().node_added.connect(_node_added)
	get_tree().node_removed.connect(_node_removed)
	_scan(get_tree().root)
	set_process(_enabled)
	observe(0)
	return true

func _exit_tree() -> void:
	_disconnect_observation()

func _disconnect_observation() -> void:
	set_process(false)
	if get_tree() != null:
		if get_tree().node_added.is_connected(_node_added):
			get_tree().node_added.disconnect(_node_added)
		if get_tree().node_removed.is_connected(_node_removed):
			get_tree().node_removed.disconnect(_node_removed)

func _scan(node: Node) -> void:
	_node_added(node)
	for child in node.get_children():
		_scan(child)

func _process(delta: float) -> void:
	if not _enabled:
		return
	_elapsed += delta
	if _elapsed >= POLL_SECONDS:
		_elapsed = 0.0
		observe(0)

func stage(value: int) -> void:
	if not _enabled or value == _stage or value < 0 or value > 12:
		return
	_stage = value
	observe(1)

static func sanitized_fields(values: Dictionary) -> Dictionary:
	var clean := {}
	for key in COUNT_FIELDS:
		if values.has(key) and (values[key] == null or (typeof(values[key]) == TYPE_INT and int(values[key]) >= (-1 if key == "phase" else 0))):
			clean[key] = values[key]
	for key in BOOL_FIELDS:
		if values.has(key) and (values[key] == null or typeof(values[key]) == TYPE_BOOL):
			clean[key] = values[key]
	return clean

static func _property_names(node: Node) -> Dictionary:
	var names := {}
	for property in node.get_property_list():
		names[str(property.name)] = true
	return names

func _node_added(node: Node) -> void:
	if not _enabled or node.name != &"StateSynchronizer" or node.get_parent() == null:
		return
	if node.get_parent().name not in [&"ServerState", &"MatchState"] or _tracked.has(node.get_instance_id()):
		return
	_generation += 1
	var kind := 4
	var parent := node.get_parent()
	if parent.name == &"MatchState":
		kind = 0
	elif parent.get_parent() != null and parent.get_parent().get_parent() != null:
		match str(parent.get_parent().get_parent().name):
			"Players": kind = 1
			"Mobs": kind = 2
			"Totems": kind = 3
	var record := {"ref": weakref(node), "generation": _generation, "entity_kind": kind, "properties": _property_names(node)}
	_tracked[node.get_instance_id()] = record
	observe(2, {"generation": _generation, "entity_kind": kind})

func _node_removed(node: Node) -> void:
	var id := node.get_instance_id()
	if not _enabled or not _tracked.has(id):
		return
	var record: Dictionary = _tracked[id]
	_tracked.erase(id)
	observe(3, {"generation": record.generation, "entity_kind": record.entity_kind})

func synchronizer_counts() -> Dictionary:
	var initialized: Variant = null
	var acknowledgements: Variant = null
	var live := 0
	for id in _tracked.keys():
		var record: Dictionary = _tracked[id]
		var node: Node = record.ref.get_ref()
		if not is_instance_valid(node) or not node.is_inside_tree():
			_tracked.erase(id)
			continue
		live += 1
		if record.properties.has("_is_initialized"):
			if initialized == null:
				initialized = 0
			if node.get("_is_initialized") == true:
				initialized += 1
		if record.properties.has("_replica_ready_peers"):
			var peers: Variant = node.get("_replica_ready_peers")
			if peers is Dictionary:
				if acknowledgements == null:
					acknowledgements = 0
				acknowledgements += peers.size()
	return {"sync_count": live, "initialized_sync_count": initialized, "replica_ack_count": acknowledgements}

func observe(event: int, extra: Dictionary = {}) -> Dictionary:
	if not _enabled or _rows >= MAX_ROWS:
		return {}
	var fields := synchronizer_counts()
	if _provider.is_valid():
		var snapshot: Variant = _provider.call()
		if snapshot is Dictionary:
			fields.merge(snapshot, true)
	fields.merge(extra, true)
	var row := sanitized_fields(fields)
	row.merge({"schema": 1, "role": _role, "index": _index, "row": _rows, "event": event, "stage": _stage,
		"uptime_usec": Time.get_ticks_usec(), "unix_usec": int(Time.get_unix_time_from_system() * 1000000.0), "cap_reached": _rows == MAX_ROWS - 1}, true)
	_rows += 1
	print("[PROFILE_READINESS] " + JSON.stringify(row))
	if _rows >= MAX_ROWS:
		_enabled = false
		_disconnect_observation()
	return row
