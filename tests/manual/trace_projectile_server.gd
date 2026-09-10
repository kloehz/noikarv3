extends SceneTree
## Server-side projectile lifecycle diagnostic loaded by the Python trace harness.
## Test-only: observes the real main scene/server startup without changing gameplay.

const TRACE_PREFIX := "[PROJECTILE-TRACE] "
const RECORD_CAP := 256
const PROJECTILE_SCRIPT := "res://common/ProjectileEntity.gd"

var _records_emitted := 0
var _records_seen := 0
var _server_spawns := 0
var _last_keys := {}
var _capped_reported := false
var _rollback_connected := false

func _initialize() -> void:
	node_added.connect(_on_node_added)
	call_deferred("_boot")

func _boot() -> void:
	await process_frame
	await _connect_rollback_when_available()
	var main_scene := String(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty():
		_trace({"stage": "summary", "records": 0, "server_spawns": 0, "capped": false, "note": "missing main_scene"})
		quit(2)
		return
	var err := change_scene_to_file(main_scene)
	if err != OK:
		_trace({"stage": "summary", "records": 0, "server_spawns": 0, "capped": false, "note": "change_scene_failed"})
		quit(2)

func _connect_rollback_when_available() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		var rollback := root.get_node_or_null("NetworkRollback")
		if rollback != null:
			var prepare := Callable(self, "_on_after_prepare_tick")
			var process := Callable(self, "_on_after_process_tick")
			if rollback.has_signal("after_prepare_tick") and not rollback.after_prepare_tick.is_connected(prepare):
				rollback.after_prepare_tick.connect(prepare)
			if rollback.has_signal("after_process_tick") and not rollback.after_process_tick.is_connected(process):
				rollback.after_process_tick.connect(process)
			_rollback_connected = true
			return
		await process_frame
	_trace({"stage": "observation", "note": "rollback_autoload_unavailable", "capped": false})

func _on_after_prepare_tick(tick: int) -> void:
	_observe_players("after_prepare_tick", tick)

func _on_after_process_tick(tick: int) -> void:
	_observe_players("after_process_tick", tick)

func _observe_players(stage: String, tick: int) -> void:
	var scene := current_scene
	if scene == null:
		return
	var players := scene.get_node_or_null("Players")
	if players == null:
		return
	var projectile_count := _projectile_count(scene)
	for player in players.get_children():
		var combat := player.get_node_or_null("CombatComponent")
		if combat == null:
			continue
		var record := {
			"stage": stage,
			"tick": tick,
			"player": str(player.name),
			"attack_count": int(combat.get("sync_attack_count")),
			"state": int(combat.get("current_attack_state")),
			"timer": float(combat.get("_state_timer")),
			"charging": bool(combat.get("is_charging")),
			"slot": int(combat.get("_active_attack_slot")),
			"primary_configured": combat.get("_primary") != null,
			"projectile_count": projectile_count,
		}
		var key := "%s|%s|%s|%s|%s|%s|%s|%s" % [
			record.stage,
			record.player,
			record.attack_count,
			record.state,
			record.charging,
			record.slot,
			record.primary_configured,
			record.projectile_count,
		]
		var cache_key := "%s|%s" % [record.player, record.stage]
		if _last_keys.get(cache_key, "") == key:
			continue
		_last_keys[cache_key] = key
		_trace(record)

func _projectile_count(scene: Node) -> int:
	var projectiles := scene.get_node_or_null("Projectiles")
	if projectiles == null:
		return 0
	return projectiles.get_child_count()

func _on_node_added(node: Node) -> void:
	if not _is_projectile_entity(node):
		return
	_server_spawns += 1
	var scene := current_scene
	_trace({
		"stage": "server_spawn",
		"node": str(node.name),
		"projectile_count": _projectile_count(scene) if scene != null else 0,
		"server_spawns": _server_spawns,
	})

func _is_projectile_entity(node: Node) -> bool:
	var node_script: Script = node.get_script()
	while node_script != null:
		if node_script.resource_path == PROJECTILE_SCRIPT:
			return true
		node_script = node_script.get_base_script()
	return false

func _trace(record: Dictionary) -> void:
	_records_seen += 1
	if _records_emitted >= RECORD_CAP:
		if not _capped_reported:
			_capped_reported = true
			print(TRACE_PREFIX + JSON.stringify({
				"stage": "summary",
				"records": _records_seen,
				"server_spawns": _server_spawns,
				"capped": true,
				"note": "record cap reached; absence after this line means capped, not absent",
			}))
		return
	_records_emitted += 1
	print(TRACE_PREFIX + JSON.stringify(record))
