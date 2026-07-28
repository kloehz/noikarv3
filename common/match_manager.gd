extends Node3D

## Manages match lifecycle and player spawning.

const PLAYER_SCENE = preload("res://scenes/BaseEntity.tscn")
const SOUL_SCENE = preload("res://scenes/SoulEntity.tscn")
const TOTEM_SCENE = preload("res://scenes/TotemEntity.tscn")
const PET_SCENE = preload("res://scenes/PetEntity.tscn")
const ENEMY_SCENE = preload("res://scenes/EnemyEntity.tscn")
const AI_COMPONENT = preload("res://core/AIComponent.gd")
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
var _pending_name: String = ""

func _ready() -> void:
	add_to_group(&"match_manager")
	EventBus.server_started.connect(_on_server_started)
	EventBus.client_connected.connect(_on_client_connected)
	EventBus.client_disconnected.connect(_on_client_disconnected)
	EventBus.player_name_submitted.connect(_on_player_name_submitted)
	EventBus.entity_died.connect(_on_entity_died)
	EventBus.phase_changed.connect(_on_phase_changed)
	EventBus.team_assigned.connect(_on_team_assigned)
	
	# Listen for successful connection to send pending data
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	
	# Spawn initial enemies if server
	if multiplayer.is_server() and GameManager._is_headless_environment():
		_spawn_initial_enemies.call_deferred()

## Spawn initial test enemies in the world.
func _spawn_initial_enemies() -> void:
	var spawn_points := [
		{ "type": "AATROX", "pos": Vector3(0, 0, -5) },
		{ "type": "AATROX", "pos": Vector3(-3, 0, -4) },
		{ "type": "AATROX", "pos": Vector3(3, 0, -4) },
	]
	print("[MatchManager] se ejecuta dos veces")
	for data in spawn_points:
		spawn_enemy(data["type"], data["pos"])

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
	# Spawn local player if not headless
	if not GameManager._is_headless_environment():
		_spawn_player(1)

func _on_client_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client connected: ", peer_id)
	_spawn_player(peer_id)
	_shutdown_timer = null # Reset timer on join

func _on_client_disconnected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	
	print("[MatchManager] Client disconnected: ", peer_id)
	_despawn_player(peer_id)
	peer_data.erase(peer_id)
	
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

@rpc("any_peer", "call_local", "reliable")
func _submit_name_to_server(player_name: String) -> void:
	var peer_id = multiplayer.get_remote_sender_id()
	print("[MatchManager] Received name from peer ", peer_id, ": ", player_name)
	peer_data[peer_id] = {"name": player_name}
	
	if multiplayer.is_server():
		# Update player if already exists
		var player = players_container.get_node_or_null(str(peer_id))
		if player and player.has_node("ServerState"):
			player.get_node("ServerState").player_name = player_name

func _on_entity_died(entity: Node3D) -> void:
	if not multiplayer.is_server(): return
	
	var is_player = entity.name.is_valid_int()
	var is_pet = entity.name.begins_with("PET")
	var is_mob = entity.name.begins_with("MOB_") or entity.name.begins_with("Dummy") or entity.name.begins_with("ELITE")
	
	# Mobs drop souls on death
	if is_mob:
		_spawn_soul(entity.global_position)
	
	# --- PETS: Die permanently (no respawn) ---
	if is_pet:
		print("[MatchManager] Pet %s died. Removing." % entity.name)
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(entity):
			entity.queue_free()
		return
	
	# --- MOBS: Respawn as new enemy after delay ---
	if is_mob:
		var old_pos = entity.global_position
		var settle_time = min(NETWORK_SPAWN_SETTLE_TIME, MOB_RESPAWN_DELAY)
		var hidden_spawn_delay = max(MOB_RESPAWN_DELAY - settle_time, 0.0)
		print("[MatchManager] Mob %s died. Hidden respawn in %.1fs, visible in %.1fs." % [entity.name, hidden_spawn_delay, MOB_RESPAWN_DELAY])
		await get_tree().create_timer(hidden_spawn_delay).timeout
		if is_instance_valid(entity):
			entity.queue_free()
		# Spawn hidden and inactive first so networking has time to settle position.
		spawn_enemy("AATROX", old_pos, settle_time)
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
	var type_str = "ATTACK"
	match type_int:
		1: type_str = "TANK"
		2: type_str = "HEAL"

	var pet = PET_SCENE.instantiate()
	pet.name = _next_spawn_id("PET_") # Stable spawn ID, replicated by the spawner
	pet.owner_id = owner_id
	pet.pet_type = type_str
	pet.power_level = souls
	_prepare_spawn_position(pet, pos, totems_container)

	var server_state = pet.get_node_or_null("ServerState")
	if server_state:
		server_state.pet_type_sync = type_str
		server_state.power_level_sync = souls

	totems_container.add_child(pet, true)
	_finalize_spawn_position(pet, pos)
	_register_spawn(pet)
	
	# Initial pet setup on server
	if pet.has_method("setup_pet"):
		pet.setup_pet(owner_id, type_str, souls)
	
	_setup_pet_logic.call_deferred(pet, owner_id, type_int, souls)

func _setup_pet_logic(pet: Node3D, owner_id: int, type_int: int, _souls: int) -> void:
	if not is_instance_valid(pet): return

	# Ensure authority is correct for AI to run on server FIRST
	pet.set_multiplayer_authority(1)
	# Project rule: any authority change after _ready() MUST be followed by
	# process_settings() so netfox rebuilds property configs per authority.
	var pet_rb = pet.get_node_or_null("RollbackSynchronizer")
	if pet_rb and pet_rb.has_method("process_settings"):
		pet_rb.process_settings()

	# FIND EXISTING AI Brain (Now in .tscn)
	var ai = pet.get_node_or_null("AIComponent")
	if not ai:
		ai = AI_COMPONENT.new()
		ai.name = "AIComponent"
		pet.add_child(ai)

	# Force refresh faction cache — groups were assigned in BaseEntity._ready()
	# but AIComponent._ready() ran before that.
	if ai.has_method("refresh_faction"):
		ai.refresh_faction()

	if type_int == 2: # HEAL
		ai.state = 3 # State.FOLLOW_OWNER
	else:
		ai.state = 1 # State.CHASE

	# Find owner node to follow
	var owner_node = players_container.get_node_or_null(str(owner_id))
	if owner_node:
		ai.owner_node = owner_node

	print("[MatchManager] Pet %s AI configured for owner %d" % [pet.name, owner_id])

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
	
	# Spawn at a safe position (away from dummies)
	var spawn_pos = Vector3(randf_range(-5, 5), 0.5, randf_range(5, 10))
	_prepare_spawn_position(player, spawn_pos, players_container)
	
	players_container.add_child(player, true)
	_finalize_spawn_position(player, spawn_pos)
	_register_spawn(player)

	# Initial server-side state setup
	if multiplayer.is_server():
		# Apply roster team from the director (NONE pre-assignment / no director)
		var director := _get_match_director()
		if director and director.has_method("get_team") and player.has_node("ServerState"):
			player.get_node("ServerState").team_id = director.get_team(peer_id)

		# Setup name from peer data if available
		if peer_data.has(peer_id):
			player.player_name = peer_data[peer_id].name
		
	print("[MatchManager] Spawned player for peer: ", peer_id, " at ", player.position)

func _despawn_player(peer_id: int) -> void:
	var player = players_container.get_node_or_null(str(peer_id))
	if player:
		_unregister_player(peer_id)
		player.queue_free()
		print("[MatchManager] Despawned player for peer: ", peer_id)
