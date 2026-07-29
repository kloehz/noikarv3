extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")
const SOUL_SCENE = preload("res://scenes/SoulEntity.tscn")
const TOTEM_SCENE = preload("res://scenes/TotemEntity.tscn")
const PET_SCENE = preload("res://scenes/PetEntity.tscn")
const ENEMY_SCENE = preload("res://scenes/EnemyEntity.tscn")
const AI_COMPONENT = preload("res://core/AIComponent.gd")

# --- MOB STAGE CONFIG (PR5 placeholder: single team, no mirror) ---
const STAGE_COUNT: int = 3
const MOBS_PER_STAGE: int = 10
const STAGE_ROW_SPACING: float = 6.0
const STAGE_COL_SPACING: float = 4.0
const STAGE_COLS: int = 5
const STAGE_BOSS_Z: float = -140.0
const BOSS_SCALE: float = 2.0
const BOSS_HP_MULTIPLIER: float = 2.0

const STAGE_DEFINITIONS: Array = [
	{ "type": "HECARIM_TANK", "z": 90.0, "prefix": "MOB_" },
	{ "type": "IVERN_HEAL",   "z": 30.0, "prefix": "MOB_" },
	{ "type": "KOGMAW_DMG",   "z": -40.0, "prefix": "MOB_" },
]
const BOSS_DEFINITION := { "type": "AATROX", "z": STAGE_BOSS_Z, "prefix": "BOSS_" }

# Kept for backwards compatibility with anything that still imports the constant.
const MOB_RESPAWN_DELAY: float = 3.0
const NETWORK_SPAWN_SETTLE_TIME: float = 1.0

@onready var players_container: Node3D = $Players
@onready var mobs_container: Node3D = $Mobs
@onready var souls_container: Node3D = $Souls
## Totems AND pets spawn under this container (keeps Players human-only).
@onready var totems_container: Node3D = $Totems

# --- CONFIGURATION: ELITE MOBS ---
@export var elite_respawn_chance: float = 0.4
@export var elite_hp_multiplier: float = 2.5
@export var elite_damage_multiplier: float = 1.6
# --- CONFIGURATION: SERVER AUTO-CLOSE ---
@export var shutdown_delay: float = 15.0 # Wait 30s before closing empty room
# ---------------------------------

var _shutdown_timer: SceneTreeTimer = null

# --- STABLE SPAWN IDs ---
## Server-assigned, deterministic per match. Format: {PREFIX}_{seed_hex}_{seq}.
## match_seed is 0 until the MatchDirector assigns the ROUND_SETUP seed.
var match_seed: int = 0
var _spawn_counters: Dictionary = {}

# --- MOB STAGE STATE (PR5 single-team placeholder) ---
## Index of the next stage to spawn. -1 means the boss has already spawned and
## the progression is finished. Each call to _spawn_next_stage advances the wave.
var _next_stage_index: int = 0
## Number of mobs alive in the current wave. Drives progression: when it
## reaches 0, the server spawns the next stage (or the boss, or stops).
var _wave_alive: int = 0

## Sets the deterministic match seed that feeds _next_spawn_id and resets the
## per-prefix counters so spawn ids stay deterministic within a match.
func set_match_seed(seed: int) -> void:
	match_seed = seed
	_spawn_counters.clear()

## Finds the MatchDirector through its group. Guarded lookups keep solo/free
## play working when no director exists (design: group + has_method guard).
func _get_match_director() -> Node:
	return get_tree().get_first_node_in_group(&"match_director")

## Registers a spawned entity in the director's spawn-sequence team registry.
## Players register under their roster team; everything else under NONE.
func _register_spawn(entity: Node) -> void:
	if not multiplayer.is_server(): return
	var director := _get_match_director()
	if director == null or not director.has_method("register_to_team"): return
	var team: int = TeamId.NONE
	if entity.name.is_valid_int() and director.has_method("get_team"):
		team = director.get_team(entity.name.to_int())
	director.register_to_team(team, StringName(entity.name))

## Removes a despawned player from the director's team registry.
func _unregister_player(peer_id: int) -> void:
	if not multiplayer.is_server(): return
	var director := _get_match_director()
	if director == null or not director.has_method("unregister_from_team"): return
	var team: int = TeamId.NONE
	if director.has_method("get_team"):
		team = director.get_team(peer_id)
	director.unregister_from_team(team, StringName(str(peer_id)))

## ROUND_SETUP wiring: pull the assigned match seed into spawn id generation.
func _on_phase_changed(phase: int) -> void:
	if not multiplayer.is_server(): return
	if phase == MatchState.Phase.LOBBY:
		_recompute_lobby()
		_broadcast_lobby_snapshots()
	if phase != MatchState.Phase.ROUND_SETUP: return
	var state := get_node_or_null("MatchState") as MatchState
	if state:
		set_match_seed(state.match_seed)

## LOBBY re-assignment wiring: push recomputed roster teams onto already
## spawned players (design: full recompute updates spawned players).
func _on_team_assigned() -> void:
	if not multiplayer.is_server(): return
	var director := _get_match_director()
	if director == null or not director.has_method("get_team"): return
	for child in players_container.get_children():
		if child.name.is_valid_int():
			var state = child.get_node_or_null("ServerState")
			if state:
				state.team_id = director.get_team(child.name.to_int())

## Generate the next stable spawn ID for a prefix (MOB_/ELITE_/PET_/SOUL_/TOTEM_).
## Example: MOB_00_0007. Prefixes keep group detection in BaseEntity._ready().
func _next_spawn_id(prefix: String) -> String:
	_spawn_counters[prefix] = _spawn_counters.get(prefix, 0) + 1
	return "%s_%02X_%04d" % [prefix.trim_suffix("_"), match_seed, _spawn_counters[prefix]]

## Store peer data like names.
var peer_data: Dictionary = {}
var _authenticating_peers: Dictionary = {}
var _pending_name: String = ""
var _lobby: Dictionary = {}
var _frozen_peer_ids: Array[int] = []

## Set only after GameManager has consumed a backend-attested ticket.
var _room_creator_account_id: String = ""

const ALLOWED_CHARACTER_IDS: Array[String] = ["warrior", "ivern_ranger"]

func _ready() -> void:
	add_to_group(&"match_manager")
	EventBus.server_started.connect(_on_server_started)
	EventBus.client_connected.connect(_on_client_connected)
	NetworkEvents.on_peer_leave.connect(_on_client_disconnected)
	EventBus.player_name_submitted.connect(_on_player_name_submitted)
	EventBus.player_auth_token_submitted.connect(_on_player_auth_token_submitted)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.phase_changed.connect(_on_phase_changed)
	EventBus.team_assigned.connect(_on_team_assigned)
	EventBus.character_selection_cancelled.connect(_on_character_selection_cancelled)
	EventBus.character_selection_launching.connect(_spawn_frozen_players)
	EventBus.match_started.connect(_begin_stage_progression)
	EventBus.room_creator_ticket_validated.connect(_on_room_creator_ticket_validated)
	if not GameManager.validated_room_creator_account_id.is_empty():
		_on_room_creator_ticket_validated(GameManager.validated_room_creator_account_id)
	
	# Listen for successful connection to send pending data
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	
	# Gameplay entities are intentionally deferred until selection launch.

## Reset and start the single-team stage progression. Idempotent so callers
## can invoke it again after a full reset (e.g. between matches).
func _begin_stage_progression() -> void:
	if not multiplayer.is_server(): return
	_next_stage_index = 0
	_wave_alive = 0
	_spawn_next_stage()

## Spawn the next stage or the boss if every prior stage is cleared.
## No-op once the boss has been spawned — mobs and the boss do not respawn.
func _spawn_next_stage() -> void:
	if not multiplayer.is_server(): return
	if _next_stage_index < 0: return
	if _next_stage_index >= STAGE_DEFINITIONS.size():
		_spawn_boss()
		return
	var def: Dictionary = STAGE_DEFINITIONS[_next_stage_index]
	var spawn_prefix: String = def.get("prefix", "MOB_")
	_spawn_stage_row(def["type"], float(def["z"]), spawn_prefix)
	_next_stage_index += 1

## Spawn a single 5x2 row of MOBS_PER_STAGE enemies at the given Z line.
## Lives in Mobs container; counted toward _wave_alive for progression.
func _spawn_stage_row(enemy_type: String, z: float, prefix: String) -> void:
	var half: float = (STAGE_COLS - 1) * 0.5
	for i in MOBS_PER_STAGE:
		var col: int = i % STAGE_COLS
		var row: int = i / STAGE_COLS
		var x: float = (col - half) * STAGE_COL_SPACING
		var pos := Vector3(x, 0, z + row * STAGE_ROW_SPACING)
		var mob := _spawn_named_enemy(enemy_type, pos, prefix)
		if mob:
			_wave_alive += 1

## Spawn the boss (AATROX at the far edge) with HP + visual scaling.
func _spawn_boss() -> void:
	if not multiplayer.is_server(): return
	var boss := _spawn_named_enemy(BOSS_DEFINITION["type"], Vector3(0, 0, STAGE_BOSS_Z), BOSS_DEFINITION["prefix"])
	if boss == null:
		return
	_apply_boss_scaling(boss)
	_wave_alive = 1
	_next_stage_index = -1

## Instantiates an EnemyEntity under Mobs with a stable id derived from prefix.
## Returns null when the scene cannot be instantiated.
func _spawn_named_enemy(enemy_type: String, pos: Vector3, prefix: String) -> Node:
	var enemy = ENEMY_SCENE.instantiate()
	enemy.name = _next_spawn_id(prefix)

	_prepare_spawn_position(enemy, pos, mobs_container)
	mobs_container.add_child(enemy, true)
	_finalize_spawn_position(enemy, pos)

	if enemy.has_method("setup_enemy"):
		enemy.setup_enemy(enemy_type, pos)
	_register_spawn(enemy)
	print("[MatchManager] %s (%s) spawned at %s" % [enemy.name, enemy_type, pos])
	return enemy

## Scale the boss model and HP for the placeholder progression. The visual
## scale propagates through the actor, while HP is written into ServerState so
## clients see the right max health via the existing state synchronizer.
func _apply_boss_scaling(boss: Node) -> void:
	if not is_instance_valid(boss): return
	var actor: Node = boss.get("character_actor")
	if is_instance_valid(actor):
		actor.scale = Vector3.ONE * BOSS_SCALE
	var boss_max_hp: int = int(boss.max_health * BOSS_HP_MULTIPLIER)
	boss.apply_stats(boss_max_hp)
	print("[MatchManager] Boss %s scaled x%.1f (%d HP)" % [boss.name, BOSS_SCALE, boss_max_hp])

## Spawn a single enemy of the given type at the given position.
## This is the public API for spawning enemies dynamically.
func spawn_enemy(enemy_type: String, pos: Vector3, spawn_grace_duration: float = 0.0) -> Node:
	var enemy = ENEMY_SCENE.instantiate()
	enemy.name = _next_spawn_id("MOB_")
	enemy.spawn_grace_duration = spawn_grace_duration

	_prepare_spawn_position(enemy, pos, mobs_container)

	mobs_container.add_child(enemy, true)
	_finalize_spawn_position(enemy, pos)

	if enemy.has_method("setup_enemy"):
		enemy.setup_enemy(enemy_type, pos)
	_register_spawn(enemy)
	print("[MatchManager] Enemy %s (%s) spawned at %s" % [enemy.name, enemy_type, pos])
	return enemy

func _prepare_spawn_position(entity: Node3D, global_pos: Vector3, container: Node3D) -> void:
	entity.position = container.to_local(global_pos)

func _finalize_spawn_position(entity: Node3D, global_pos: Vector3) -> void:
	entity.global_position = global_pos
	entity.force_update_transform()
	var interpolator = entity.get_node_or_null("TickInterpolator")
	if interpolator and interpolator.has_method("teleport"):
		interpolator.teleport()

func _strip_visual_nodes_recursive(node: Node) -> void:
	if not node: return
	
	var to_remove = []
	for child in node.get_children():
		if child is MeshInstance3D or child is Sprite3D or child is Label3D or child is WorldEnvironment or child is DirectionalLight3D or child is GPUParticles3D or child is CPUParticles3D or child is CSGPrimitive3D:
			to_remove.append(child)
		else:
			_strip_visual_nodes_recursive(child)
	
	for child in to_remove:
		print("[DEBUG] MatchManager removing visual: %s" % child.name)
		child.free()

func _on_server_started() -> void:
	print("[MatchManager] Match started as server")

func _on_client_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client connected: ", peer_id)
	# ENet proves transport connectivity, not account identity. Spawn only after
	# the backend validated the JWT submitted by this peer.
	_shutdown_timer = null # Reset timer on join

func _on_client_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client disconnected: ", peer_id)
	_despawn_player(peer_id)
	peer_data.erase(peer_id)
	if _lobby.erase(peer_id):
		if _frozen_peer_ids.has(peer_id):
			var director := _get_match_director()
			if director: director.cancel_character_selection()
		else:
			_recompute_lobby()
			_broadcast_lobby_snapshots()
	
	# Wait a frame to ensure queue_free() is processed or use robust check
	_check_for_empty_server.call_deferred()

func _check_for_empty_server() -> void:
	if not multiplayer.is_server(): return
	
	# Count human players (nodes with numeric names in Players container)
	var human_count = 0
	for child in players_container.get_children():
		# IMPORTANT: ignore nodes about to be destroyed
		if child.name.is_valid_int() and not child.is_queued_for_deletion():
			human_count += 1
	
	print("[MatchManager] Human player count: ", human_count)
	
	if human_count == 0:
		if _shutdown_timer == null:
			print("[MatchManager] Server is empty. Starting shutdown timer (%ds)..." % shutdown_delay)
			_shutdown_timer = get_tree().create_timer(shutdown_delay)
			_shutdown_timer.timeout.connect(_auto_shutdown)
	elif _shutdown_timer:
		print("[MatchManager] Player joined. Aborting shutdown.")
		_shutdown_timer = null

func _auto_shutdown() -> void:
	# Double check count before actually quitting
	var human_count = 0
	if is_instance_valid(players_container):
		for child in players_container.get_children():
			if child.name.is_valid_int():
				human_count += 1
			
	if human_count == 0:
		print("[MatchManager] ROOM EMPTY. SHUTTING DOWN SERVER TO SAVE RESOURCES.")
		get_tree().quit()

func _on_connected_to_server() -> void:
	if not _pending_name.is_empty():
		_submit_name_to_server.rpc_id(1, _pending_name)

func _on_player_name_submitted(player_name: String) -> void:
	_pending_name = player_name
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
		_submit_name_to_server.rpc_id(1, player_name)

func _on_player_auth_token_submitted(token: String) -> void:
	if multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
		_submit_auth_token_to_server.rpc_id(1, token)

@rpc("any_peer", "reliable")
func _submit_auth_token_to_server(token: String) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id <= 0 or _authenticating_peers.has(peer_id) or peer_data.has(peer_id):
		return
	_authenticating_peers[peer_id] = true
	_authenticate_peer(peer_id, token)

func _authenticate_peer(peer_id: int, token: String) -> void:
	var identity: Dictionary = await AuthService.validate_access_token(token)
	_authenticating_peers.erase(peer_id)
	if not identity.get("accepted", false) or not multiplayer.get_peers().has(peer_id):
		await _reject_admission_and_disconnect(peer_id, "Account validation failed")
		return
	if not _admit_authenticated_identity(peer_id, identity):
		await _reject_admission_and_disconnect(peer_id, _admission_failure_reason(str(identity.get("account_id", ""))))
		return
	_auth_accepted.rpc_id(peer_id, str(identity.username))
	_broadcast_lobby_snapshots()

@rpc("authority", "reliable")
func _auth_accepted(authenticated_username: String) -> void:
	EventBus.game_server_authenticated.emit(authenticated_username)

@rpc("authority", "reliable")
func receive_admission_rejection(reason: String) -> void:
	EventBus.room_admission_rejected.emit(reason)

func _reject_admission_and_disconnect(peer_id: int, reason: String) -> void:
	if multiplayer.get_peers().has(peer_id):
		receive_admission_rejection.rpc_id(peer_id, reason)
		await get_tree().create_timer(0.1).timeout
	if multiplayer.get_peers().has(peer_id): multiplayer.multiplayer_peer.disconnect_peer(peer_id)

func _admission_failure_reason(account_id: String) -> String:
	var director := _get_match_director()
	if director == null or director.match_state.phase != MatchState.Phase.LOBBY: return "Room is not accepting players"
	if _has_authenticated_account(account_id): return "This account is already in the room"
	if _lobby.size() >= director.rules.max_players_per_team * 2: return "Room is full"
	return "Room admission was denied"

@rpc("any_peer", "reliable")
func _submit_name_to_server(player_name: String) -> void:
	var peer_id = multiplayer.get_remote_sender_id()
	if not multiplayer.is_server() or not _lobby.has(peer_id): return
	# Authenticated identity is immutable; this legacy RPC may not rename it.
	_reject_lobby_request(peer_id, "Account identity is server-managed")

@rpc("any_peer", "reliable")
func request_lobby_ready(ready: bool) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	_set_lobby_ready_from_peer(peer_id, ready)

func _set_lobby_ready_from_peer(peer_id: int, ready: bool) -> bool:
	if not _can_mutate_lobby(peer_id, MatchState.Phase.LOBBY): return false
	var record: Dictionary = _lobby[peer_id]
	record["lobby_ready"] = ready
	_lobby[peer_id] = record
	_broadcast_lobby_snapshots()
	return true

@rpc("any_peer", "reliable")
func request_character_select_start() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	submit_character_select_start(peer_id)

func submit_character_select_start(peer_id: int) -> bool:
	if not _can_mutate_lobby(peer_id, MatchState.Phase.LOBBY): return false
	if not bool(_lobby[peer_id]["is_host"]):
		_reject_lobby_request(peer_id, "Only the host can start selection")
		return false
	if not _all_lobby_ready():
		_reject_lobby_request(peer_id, "Every member must be ready")
		return false
	_frozen_peer_ids = _sorted_lobby_peer_ids()
	if _get_match_director().begin_character_selection(_frozen_peer_ids):
		for frozen_id in _frozen_peer_ids:
			var record: Dictionary = _lobby[frozen_id]
			record["character_id"] = ""
			record["selection_ready"] = false
			_lobby[frozen_id] = record
		_broadcast_lobby_snapshots()
		return true
	return false

@rpc("any_peer", "reliable")
func request_character_selection(character_id: String, ready: bool) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	submit_character_selection(peer_id, character_id, ready)

func submit_character_selection(peer_id: int, character_id: String, ready: bool) -> bool:
	if not _can_mutate_lobby(peer_id, MatchState.Phase.CHARACTER_SELECT): return false
	if not _frozen_peer_ids.has(peer_id):
		_reject_lobby_request(peer_id, "Player is not in the frozen roster")
		return false
	if ready and not ALLOWED_CHARACTER_IDS.has(character_id):
		_reject_lobby_request(peer_id, "Invalid character selection")
		return false
	if not character_id.is_empty() and not ALLOWED_CHARACTER_IDS.has(character_id):
		_reject_lobby_request(peer_id, "Invalid character selection")
		return false
	var record: Dictionary = _lobby[peer_id]
	if not character_id.is_empty(): record["character_id"] = character_id
	record["selection_ready"] = ready and not str(record["character_id"]).is_empty()
	_lobby[peer_id] = record
	_broadcast_lobby_snapshots()
	if _all_frozen_selection_ready():
		_get_match_director().complete_character_selection()
	return true

@rpc("authority", "reliable")
func receive_lobby_snapshot(snapshot: Dictionary) -> void:
	EventBus.lobby_snapshot_received.emit(snapshot)

func _can_mutate_lobby(peer_id: int, expected_phase: int) -> bool:
	if not multiplayer.is_server() or peer_id <= 0 or not _lobby.has(peer_id):
		return false
	if _get_match_director().match_state.phase != expected_phase:
		_reject_lobby_request(peer_id, "Action is not valid in this phase")
		return false
	return true

func _sorted_lobby_peer_ids() -> Array[int]:
	var ids: Array[int] = []
	for peer_id in _lobby: ids.append(peer_id)
	ids.sort()
	return ids

func _recompute_lobby() -> void:
	var ids := _sorted_lobby_peer_ids()
	for index in ids.size():
		var record: Dictionary = _lobby[ids[index]]
		record["team"] = TeamId.RED if index % 2 == 0 else TeamId.BLUE
		record["is_host"] = not _room_creator_account_id.is_empty() and str(record["account_id"]) == _room_creator_account_id
		record["lobby_ready"] = false
		_lobby[ids[index]] = record

func _all_lobby_ready() -> bool:
	return not _lobby.is_empty() and _lobby.values().all(func(record: Dictionary) -> bool: return bool(record["lobby_ready"]))

func _all_frozen_selection_ready() -> bool:
	return not _frozen_peer_ids.is_empty() and _frozen_peer_ids.all(func(peer_id: int) -> bool:
		return _lobby.has(peer_id) and bool(_lobby[peer_id]["selection_ready"]))

func _snapshot_for(peer_id: int, rejection: String = "") -> Dictionary:
	var recipient: Dictionary = _lobby[peer_id]
	var team_members: Array[Dictionary] = []
	for member_id in _sorted_lobby_peer_ids():
		var record: Dictionary = _lobby[member_id]
		if record["team"] == recipient["team"]:
			team_members.append({ "name": record["name"], "lobby_ready": record["lobby_ready"], "character_id": record["character_id"], "selection_ready": record["selection_ready"] })
	return { "phase": _get_match_director().match_state.phase, "deadline_tick": _get_match_director().match_state.selection_deadline_tick, "team": recipient["team"], "is_host": recipient["is_host"], "self_lobby_ready": recipient["lobby_ready"], "self_selection_ready": recipient["selection_ready"], "members": team_members, "rejection": rejection }

func _broadcast_lobby_snapshots() -> void:
	if not multiplayer.is_server(): return
	for peer_id in _sorted_lobby_peer_ids():
		if multiplayer.get_peers().has(peer_id):
			receive_lobby_snapshot.rpc_id(peer_id, _snapshot_for(peer_id))

func _reject_lobby_request(peer_id: int, reason: String) -> void:
	if _lobby.has(peer_id) and multiplayer.get_peers().has(peer_id):
		receive_lobby_snapshot.rpc_id(peer_id, _snapshot_for(peer_id, reason))

func _on_character_selection_cancelled() -> void:
	_frozen_peer_ids.clear()
	for peer_id in _lobby:
		var record: Dictionary = _lobby[peer_id]
		record["lobby_ready"] = false
		record["character_id"] = ""
		record["selection_ready"] = false
		_lobby[peer_id] = record
	_broadcast_lobby_snapshots()

func _spawn_frozen_players() -> void:
	for peer_id in _frozen_peer_ids:
		_spawn_player(peer_id)
	_frozen_peer_ids.clear()

func _has_authenticated_account(account_id: String) -> bool:
	for record in _lobby.values():
		if str(record["account_id"]) == account_id:
			return true
	return false

func _admit_authenticated_identity(peer_id: int, identity: Dictionary) -> bool:
	var director := _get_match_director()
	var account_id := str(identity.get("account_id", ""))
	if director == null or director.match_state.phase != MatchState.Phase.LOBBY:
		return false
	if account_id.is_empty() or _lobby.size() >= director.rules.max_players_per_team * 2:
		return false
	if _has_authenticated_account(account_id):
		return false
	peer_data[peer_id] = {"account_id": account_id, "name": str(identity.get("username", ""))}
	_lobby[peer_id] = {"account_id": account_id, "name": str(identity.get("username", "")), "team": TeamId.NONE, "lobby_ready": false, "character_id": "", "selection_ready": false, "is_host": false}
	_recompute_lobby()
	return true

func _on_room_creator_ticket_validated(account_id: String) -> void:
	if not multiplayer.is_server() or account_id.is_empty(): return
	_room_creator_account_id = account_id
	_recompute_lobby()
	_broadcast_lobby_snapshots()

## Defers the queue_free so visuals/VFX have time to play their death effect.
## Pulled out so the wave counter can progress synchronously before the cleanup.
func _schedule_entity_cleanup(entity: Node) -> void:
	if not is_instance_valid(entity): return
	await get_tree().create_timer(2.0).timeout
	if is_instance_valid(entity):
		entity.queue_free()

func _on_entity_died(entity: Node3D) -> void:
	if not multiplayer.is_server(): return

	var is_player = entity.name.is_valid_int()
	var is_pet = entity.name.begins_with("PET")
	var is_mob = entity.name.begins_with("MOB_") or entity.name.begins_with("Dummy") or entity.name.begins_with("ELITE")
	var is_boss = entity.name.begins_with("BOSS_")

	# Mobs and bosses drop souls on death
	if is_mob or is_boss:
		_spawn_soul(entity.global_position)

	# --- PETS: Die permanently (no respawn) ---
	if is_pet:
		print("[MatchManager] Pet %s died. Removing." % entity.name)
		_schedule_entity_cleanup(entity)
		return

	# --- BOSS: One-shot, progression ends here ---
	if is_boss:
		print("[MatchManager] Boss %s died. Progression complete." % entity.name)
		_wave_alive = max(_wave_alive - 1, 0)
		_schedule_entity_cleanup(entity)
		return

	# --- MOBS: no individual respawn; advance stage when the wave is cleared ---
	if is_mob:
		print("[MatchManager] Mob %s died. Wave remaining: %d" % [entity.name, _wave_alive - 1])
		_wave_alive = max(_wave_alive - 1, 0)
		_schedule_entity_cleanup(entity)
		if _wave_alive == 0:
			_spawn_next_stage()
		return

	# --- PLAYERS: Respawn in place ---
	if is_player:
		print("[MatchManager] Player %s died. Respawning in 3s." % entity.name)
		await get_tree().create_timer(3.0).timeout
		if is_instance_valid(entity) and entity.has_method("respawn"):
			var random_pos = Vector3(randf_range(-10, 10), 0.1, randf_range(-10, 10))
			entity.respawn(random_pos)

func _spawn_soul(pos: Vector3) -> void:
	var soul = SOUL_SCENE.instantiate()
	soul.name = _next_spawn_id("SOUL_")
	_prepare_spawn_position(soul, pos, souls_container)
	souls_container.add_child(soul, true)
	_finalize_spawn_position(soul, pos)
	_register_spawn(soul)
	
	soul.expired.connect(func(): _on_soul_expired(pos))

func _on_soul_expired(pos: Vector3) -> void:
	if randf() < elite_respawn_chance:
		print("[MatchManager] SOUL EXPIRED - Spawning ELITE MOB at ", pos)
		_spawn_elite_mob(pos)

func _spawn_elite_mob(pos: Vector3) -> void:
	var elite = ENEMY_SCENE.instantiate()
	elite.name = _next_spawn_id("ELITE_")

	_prepare_spawn_position(elite, pos, mobs_container)

	mobs_container.add_child(elite, true)
	_finalize_spawn_position(elite, pos)
	_register_spawn(elite)

	if elite.has_method("setup_enemy"):
		elite.setup_enemy("AATROX", pos)

	# Apply elite stat scaling (deferred to ensure setup is complete)
	_setup_elite_logic.call_deferred(elite)

func _setup_elite_logic(elite: Node3D) -> void:
	if not is_instance_valid(elite): return
	
	# Scale HP
	var elite_hp = int(100 * elite_hp_multiplier)
	var health = elite.get_node_or_null("HealthComponent")
	if health:
		elite.max_health = elite_hp
		var server_state = elite.get_node_or_null("ServerState")
		if server_state:
			server_state.max_health = elite_hp
			server_state.sync_health = elite_hp
	
	print("[MatchManager] Elite Mob %s configured with %d HP" % [elite.name, elite_hp])

func request_spawn_totem(player: BaseEntity, type: int) -> void:
	if not multiplayer.is_server(): return
	
	if not player.server_state:
		print("[SUMMON ERROR] Player %s has no ServerState!" % player.name)
		return
		
	if player.server_state.sync_souls <= 0:
		print("[SUMMON ERROR] Player %s has no souls! (Souls: %d)" % [player.name, player.server_state.sync_souls])
		return
	
	var souls = player.server_state.sync_souls
	print("[SUMMON REQUEST] Player %s requesting type %d with %d souls" % [player.name, type, souls])
	
	player.server_state.sync_souls = 0
	
	var totem = TOTEM_SCENE.instantiate()
	totem.name = _next_spawn_id("TOTEM_")
	
	# Calculate position in front of player
	var forward = -player.global_transform.basis.z
	var totem_pos = player.global_position + (forward * 2.0)
	totem.totem_type = type
	totem.stored_souls = souls
	_prepare_spawn_position(totem, totem_pos, totems_container)

	totems_container.add_child(totem, true)
	_finalize_spawn_position(totem, totem_pos)
	_register_spawn(totem)
	print("[SERVER] !!! SUMMONING TOTEM !!! at %s for player %s" % [totem.global_position, player.name])
	
	totem.summoned.connect(func(p_type: int, p_souls: int): 
		_on_totem_complete(player.name.to_int(), p_type, p_souls, totem.global_position)
	)
	print("[MatchManager] Totem requested by ", player.name, " in front at ", totem.global_position)

func _on_totem_complete(owner_id: int, type_int: int, souls: int, pos: Vector3) -> void:
	var pet_type := "ATTACK"
	match type_int:
		1: pet_type = "TANK"
		2: pet_type = "HEAL"

	var pet = PET_SCENE.instantiate()
	pet.name = _next_spawn_id("PET_")
	pet.owner_id = owner_id
	pet.pet_type = pet_type
	pet.power_level = souls
	# The charge VFX already provides the spawn delay; do not hide the pet again.
	pet.spawn_grace_duration = 0.0
	_prepare_spawn_position(pet, pos, totems_container)

	var server_state = pet.get_node_or_null("ServerState")
	if server_state:
		server_state.pet_type_sync = pet_type
		server_state.power_level_sync = souls

	totems_container.add_child(pet, true)
	_finalize_spawn_position(pet, pos)
	_register_spawn(pet)

	if pet.has_method("setup_pet"):
		pet.setup_pet(owner_id, pet_type, souls)

	_setup_pet_logic.call_deferred(pet, owner_id, type_int)

func _setup_pet_logic(pet: Node3D, owner_id: int, type_int: int) -> void:
	if not is_instance_valid(pet): return

	pet.set_multiplayer_authority(1)
	var pet_rb = pet.get_node_or_null("RollbackSynchronizer")
	if pet_rb and pet_rb.has_method("process_settings"):
		pet_rb.process_settings()

	var ai = pet.get_node_or_null("AIComponent")
	if not ai:
		ai = AI_COMPONENT.new()
		ai.name = "AIComponent"
		pet.add_child(ai)

	if ai.has_method("refresh_faction"):
		ai.refresh_faction()

	ai.state = AI_COMPONENT.State.FOLLOW_OWNER if type_int == 2 else AI_COMPONENT.State.CHASE
	ai.owner_node = players_container.get_node_or_null(str(owner_id))

@rpc("any_peer", "call_local", "reliable")
func spawn_totem_rpc(type: int) -> void:
	if not multiplayer.is_server(): return
	
	var sender_id = multiplayer.get_remote_sender_id()
	# Handle Host/Singleplayer edge cases
	if sender_id == 0 or sender_id == 1:
		sender_id = 1
	
	print("[SERVER] Petición de invocación (Tipo %d) de Peer %d" % [type, sender_id])
	
	# Find player node (Try string first, then authority)
	var player = players_container.get_node_or_null(str(sender_id)) as BaseEntity
	if not player:
		for child in players_container.get_children():
			if child.get_multiplayer_authority() == sender_id:
				player = child as BaseEntity
				break
	
	if player:
		var current_souls = player.server_state.sync_souls if player.server_state else 0
		print("[SERVER] Validando player %s. Almas disponibles: %d" % [player.name, current_souls])
		request_spawn_totem(player, type)
	else:
		print("[SERVER ERROR] ¡No se pudo encontrar al jugador %d para procesar el RPC!" % sender_id)

func _spawn_player(peer_id: int) -> void:
	# Check if already spawned
	if players_container.has_node(str(peer_id)):
		return

	var player = PLAYER_SCENE.instantiate()
	player.name = str(peer_id)

	# Spawn at the fixed player spawn (world (0, 0.5, 140) — Lorencia PlayerSpawn marker).
	var spawn_pos = Vector3(0, 0.5, 140)
	_prepare_spawn_position(player, spawn_pos, players_container)
	
	players_container.add_child(player, true)
	_finalize_spawn_position(player, spawn_pos)
	_register_spawn(player)

	# Initial server-side state setup
	if multiplayer.is_server():
		# Frozen lobby assignment is applied only at launch; pre-lobby entities
		# retain NONE and roster records are never replicated through ServerState.
		if player.has_node("ServerState"):
			if _lobby.has(peer_id):
				player.get_node("ServerState").team_id = int(_lobby[peer_id]["team"])
			else:
				var director := _get_match_director()
				if director and director.has_method("get_team"):
					player.get_node("ServerState").team_id = director.get_team(peer_id)

		# Setup name from peer data if available
		if peer_data.has(peer_id):
			player.player_name = peer_data[peer_id].name
		if _lobby.has(peer_id):
			player.select_character(str(_lobby[peer_id]["character_id"]))
		
	print("[MatchManager] Spawned player for peer: ", peer_id, " at ", player.position)

func _despawn_player(peer_id: int) -> void:
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		_unregister_player(peer_id)
		player.queue_free()
		print("[MatchManager] Despawned player for peer: ", peer_id)
