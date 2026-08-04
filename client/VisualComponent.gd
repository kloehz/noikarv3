@tool
# res://client/VisualComponent.gd
class_name VisualComponent
extends Node

## Client-side visual component for mesh representation and VFX.
## Now works with CharacterActor for flexible character models.

## Entity this component provides visuals for.
@export var entity: CharacterBody3D

## Current active character actor (model + animations)
var _actor: CharacterActor
var _anim_lock_time: float = 0.0
var _preview_mesh: MeshInstance3D
var _aim_reticle: Control
var _base_camera_fov: float = 75.0
## Tracks the last soul amount rendered in the HUD so the pulse animation
## only fires on increment (not on every replication tick).
var _last_hud_souls: int = 0

## Preloaded impact VFX scene used by the replicated hit-event flow.
const VFX_HIT_02_SCENE := preload("res://assets/BinbunVFX_Vol2/StylizedHitFX/effects/hit/vfx_hit_02.tscn")

## Maps the replicated ServerState.character_id to the HUD label name shown
## above the local player's HP bar. Falls back to the raw id if a new
## champion is added before the map is updated.
const CHAMPION_DISPLAY_NAMES: Dictionary = {
	"warrior": "Aatrox",
	"ivern_ranger": "Ivern",
}

func _ready() -> void:
	if Engine.is_editor_hint():
		_setup_from_parent()
		return
	
	print("[DEBUG] VisualComponent ready on %s" % (entity.name if entity else &"Unknown"))
	_connect_signals()

## Set up from parent node (for tool mode and runtime).
func _setup_from_parent() -> void:
	if not entity:
		entity = get_parent() as CharacterBody3D
		if entity:
			print("[DEBUG] VisualComponent auto-assigned entity: %s" % entity.name)

## Connect to EventBus signals for game event-driven visuals.
func _connect_signals() -> void:
	if not entity:
		print("[ERROR] VisualComponent: Cannot connect signals, entity is null!")
		return

	print("[DEBUG] VisualComponent %s connecting signals" % entity.name)
	EventBus.entity_spawned.connect(_on_entity_spawned)
	EventBus.entity_died.connect(_on_entity_died)

	var health = entity.get_node_or_null("HealthComponent")
	if health:
		print("[DEBUG] VisualComponent %s connected to HealthComponent" % entity.name)
		health.health_changed.connect(_on_health_changed)
		_on_health_changed(health.current_health, health.max_health)
	
	var combat = entity.get_node_or_null("CombatComponent")
	if combat:
		print("[DEBUG] VisualComponent %s connected to CombatComponent" % entity.name)
		# NOTE: We do NOT connect attack_started here.
		# Attack animations are driven by _handle_networked_attack_vfx()
		# which is rollback-safe (uses sync_attack_count vs _local_attack_count).
		# Connecting the signal directly would fire animations during rollback
		# re-simulations, causing visual glitches.

	var server_state = entity.get_node_or_null("ServerState")
	if server_state:
		server_state.souls_changed.connect(_on_souls_changed)
		server_state.heal_received.connect(_on_heal_received)
		server_state.damage_received.connect(_on_damage_received)
		server_state.character_changed.connect(_on_character_changed)
		_on_souls_changed(server_state.sync_souls)
		_on_character_changed(server_state.character_id)

func _on_souls_changed(amount: int) -> void:
	# Only update HUD for the local controlled player
	if not entity.is_multiplayer_authority():
		return

	# SoulCounter is a PanelContainer after the UI rework; the actual text
	# Label sits two levels deeper at SoulCounter/HBox/Label. Casting the
	# container itself to Label returned null and silently dropped every
	# update — players saw "Almas: 0" even though sync_souls was climbing.
	var panel := get_tree().root.find_child("SoulCounter", true, false)
	if panel == null:
		return
	var hud_counter := panel.get_node_or_null("HBox/Label") as Label
	if hud_counter:
		hud_counter.text = "Almas: %d" % amount
	# Only fire the pulse on net increment — replicated ticks may deliver the
	# same value, and the initial sync call shouldn't burst the animation.
	if amount > _last_hud_souls:
		_play_soul_pulse(panel)
	_last_hud_souls = amount

## Triggered by ServerState.character_changed on every client (the value is
## replicated, not authority-only). Drives the HUD label above the local
## player's HP bar so it reflects whichever champion they picked.
func _on_character_changed(character_id: String) -> void:
	if not entity.is_multiplayer_authority():
		return
	var label := get_tree().root.find_child("PlayerHealthLabel", true, false) as Label
	if label == null:
		return
	label.text = CHAMPION_DISPLAY_NAMES.get(character_id, character_id.capitalize())

## Short celebratory pulse on the soul icon + number when the local player
## gains a soul. Icon scales up and tints brighter, then eases back; the
## label does a quick brightness flash. Existing tweens on the same nodes
## are killed so rapid pickups don't stack and accumulate transform drift.
func _play_soul_pulse(panel: Node) -> void:
	var icon := panel.get_node_or_null("HBox/Icon") as Control
	var hud_counter := panel.get_node_or_null("HBox/Label") as Label
	if icon:
		if icon.has_meta("soul_pulse_tween"):
			var prev: Tween = icon.get_meta("soul_pulse_tween")
			if is_instance_valid(prev): prev.kill()
		icon.pivot_offset = icon.size * 0.5
		var tween := icon.create_tween().set_parallel(true)
		tween.tween_property(icon, "scale", Vector2.ONE * 1.35, 0.08) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_property(icon, "modulate", Color(1.6, 1.6, 2.2, 1.0), 0.08)
		tween.chain().tween_property(icon, "scale", Vector2.ONE, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tween.tween_property(icon, "modulate", Color(1, 1, 1, 1), 0.22)
		icon.set_meta("soul_pulse_tween", tween)
	if hud_counter:
		if hud_counter.has_meta("soul_label_tween"):
			var prev: Tween = hud_counter.get_meta("soul_label_tween")
			if is_instance_valid(prev): prev.kill()
		var tween := hud_counter.create_tween()
		tween.tween_property(hud_counter, "modulate", Color(1.5, 1.7, 2.2, 1.0), 0.06)
		tween.tween_property(hud_counter, "modulate", Color(1, 1, 1, 1), 0.18)
		hud_counter.set_meta("soul_label_tween", tween)

func _on_health_changed(current: int, maximum: int) -> void:
	# World-space bars remain for mobs and pets. The local player's health is
	# presented in the screen HUD so it stays visible while moving the camera.
	var health_bar_2d = entity.get_node_or_null("HealthViewport/HealthBar2D")
	if health_bar_2d and health_bar_2d.has_method("update_health"):
		health_bar_2d.update_health(current, maximum)
	if entity.is_multiplayer_authority():
		var player_health_hud := get_tree().root.find_child("PlayerHealthBar", true, false)
		if player_health_hud and player_health_hud.has_method("update_health"):
			player_health_hud.update_health(current, maximum)
	
	# Legacy Label support (now hidden in TSCN)
	var health_label = get_parent().get_node_or_null("HealthLabel") as Label3D
	if health_label:
		health_label.text = "%d/%d" % [current, maximum]

## Initialize with a specific character actor
func setup_with_actor(actor: CharacterActor) -> void:
	_actor = actor
	if _actor:
		print("[DEBUG] VisualComponent %s setup with actor: %s" % [entity.name if entity else &"Entity", _actor.name])
		if entity:
			var mesh = entity.get_node_or_null("MeshInstance3D")
			if mesh: mesh.visible = false
	else:
		print("[WARNING] VisualComponent setup_with_actor called with null actor")

## Called when entity spawns - play spawn VFX/effects.
func _on_entity_spawned(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		play_spawn_effect()

## Update visual name (e.g., label above player).
func update_name(new_name: String) -> void:
	var name_label = get_parent().get_node_or_null("NameLabel")
	if name_label:
		name_label.text = new_name

## Play attack visual effect (melee hit).
func play_shoot_effect() -> void:
	if not _actor: 
		_play_fallback_punch()
		return
		
	# Force restart if already playing to show rapid attacks
	if _actor.animation_player:
		_actor.animation_player.stop()
	
	_actor.play_animation("Attack") 
	_anim_lock_time = 0.5 # Wait 0.5s before allowing Idle/Run to override

func _update_debug_pos(debug_mesh: MeshInstance3D) -> void:
	var combat = entity.get_node_or_null("CombatComponent")
	if not combat or not combat._melee_shapecast: return
	
	# Match exactly what the server is checking
	debug_mesh.global_position = combat._melee_shapecast.global_position

func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	
	# Handle Attack Debug visuals deterministically based on synchronized state
	_handle_attack_debug_visuals()
	_handle_summon_preview()
	_handle_networked_attack_vfx()
	_handle_local_aim_presentation(delta)
	
	if _anim_lock_time > 0:
		_anim_lock_time -= delta
		return
		
	_update_movement_animations()

func _handle_networked_attack_vfx() -> void:
	var combat = entity.get_node_or_null("CombatComponent")
	if not combat: return
	
	# Detect if the attack counter increased on the network
	var sync_count = combat.get("sync_attack_count")
	var local_count = combat.get("_local_attack_count")
	
	# Robust null check to prevent Red Screen of Death
	if sync_count != null and local_count != null and sync_count > local_count:
		combat.set("_local_attack_count", sync_count)
		play_shoot_effect()

func _handle_summon_preview() -> void:
	if not entity or not entity.is_multiplayer_authority(): return
	
	var logic = entity.get_node_or_null("LogicComponent")
	if not logic or not logic.is_previewing:
		if _preview_mesh: _preview_mesh.visible = false
		return
		
	if not _preview_mesh:
		_preview_mesh = MeshInstance3D.new()
		var box = BoxMesh.new()
		box.size = Vector3(0.8, 1.5, 0.8)
		_preview_mesh.mesh = box
		
		var mat = StandardMaterial3D.new()
		mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.0, 1.0, 1.0, 0.4) # Cyan ghost
		mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
		_preview_mesh.material_override = mat
		
		# Add as child of entity but we'll use global pos
		entity.add_child(_preview_mesh)
		
	_preview_mesh.visible = true
	
	# Position 2 meters in front of player
	var forward = -entity.global_transform.basis.z
	_preview_mesh.global_position = entity.global_position + (forward * 2.0)
	_preview_mesh.global_rotation = entity.global_rotation

func _handle_local_aim_presentation(delta: float) -> void:
	if not entity or not entity.is_multiplayer_authority():
		return
	var combat = entity.get_node_or_null("CombatComponent")
	var logic = entity.get_node_or_null("LogicComponent")
	var camera = entity.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	var attack = combat.get("_primary") as AttackDefinition if combat else null
	if not combat or not logic or not camera or not attack or not combat.call("_uses_charged_projectile", attack):
		return
	var aiming: bool = logic.get("is_shooting")
	if _aim_reticle == null:
		var hud = get_tree().root.find_child("HUD", true, false)
		if hud:
			_aim_reticle = preload("res://scenes/ui/AimReticle.tscn").instantiate() as Control
			hud.add_child(_aim_reticle)
			_base_camera_fov = camera.fov
	if _aim_reticle:
		_aim_reticle.visible = aiming
		var charge_time: float = combat.get("current_charge_time")
		_aim_reticle.set("charge_progress", charge_time / attack.charge_duration if aiming else 0.0)
	var target_fov: float = attack.aim_fov if aiming else _base_camera_fov
	camera.fov = move_toward(camera.fov, target_fov, delta * 70.0)

func _handle_attack_debug_visuals() -> void:
	var debug_mesh = get_parent().get_node_or_null("AttackDebugMesh") as MeshInstance3D
	if not debug_mesh: return
	
	var combat = entity.get_node_or_null("CombatComponent")
	if not combat:
		debug_mesh.visible = false
		return
	
	# AttackState.ACTIVE is 2
	if combat.get("current_attack_state") == 2:
		debug_mesh.visible = true
		_update_debug_pos(debug_mesh)
	else:
		debug_mesh.visible = false

func _update_movement_animations() -> void:
	if not _actor: return
	if not entity: return

	# CRITICAL: If dead, don't play movement/idle animations
	if entity.get("sync_is_dead"):
		return

	# Some headless tests strip the actor's GLB meshes, leaving the
	# AnimationPlayer present but with zero animations. Skip silently.
	if not _actor.animation_player:
		return

	# Priority: If we are playing an attack, don't override it with move/idle
	if _actor.is_playing("Attack"):
		return

	var logic = entity.get_node_or_null("LogicComponent")
	if logic:
		var is_dashing = logic.get("is_dashing") as bool
		if is_dashing:
			_actor.animation_player.speed_scale = 2.0
			_actor.play_animation("Run")
			_ensure_loop("Run")
			return
		else:
			_actor.animation_player.speed_scale = 1.0

		var velocity = logic.get("current_velocity") as Vector3
		if velocity and velocity.length() > 0.1:
			_actor.play_animation("Run")
			_ensure_loop("Run")
		else:
			_actor.play_animation("Idle")
			_ensure_loop("Idle")

## Force the current animation to loop. Some GLB exports import a single
## clip that AnimationPlayer treats as one-shot; without this the mob
## freezes on its first frame instead of looping the idle pose.
func _ensure_loop(_anim_alias: String) -> void:
	if not _actor or not _actor.animation_player: return
	var ap: AnimationPlayer = _actor.animation_player
	# current_animation is empty before the first play_animation call;
	# reading it directly emits a noisy engine error so guard with the
	# cheaper string check first.
	var current: String = ap.current_animation
	if current == "":
		return
	if not ap.has_animation(current):
		return
	# Some Godot 4 import configurations land clips in the default "" library
	# or in a named library. Resolve the underlying Animation resource and
	# flip its loop_mode to LINEAR_LOOP if it isn't already.
	var resolved: Animation = null
	var slash_idx: int = current.find("/")
	if slash_idx != -1:
		var lib_name: String = current.substr(0, slash_idx)
		var anim_name: String = current.substr(slash_idx + 1)
		var lib: AnimationLibrary = ap.get_animation_library(lib_name)
		if lib:
			resolved = lib.get_animation(anim_name)
	else:
		resolved = ap.get_animation(current)
	if resolved and resolved.loop_mode != Animation.LOOP_LINEAR:
		resolved.loop_mode = Animation.LOOP_LINEAR

func _play_fallback_punch() -> void:
	var mesh = entity.get_node_or_null("MeshInstance3D")
	if mesh:
		var base_pos = Vector3(0, 1, 0)
		var tween = get_tree().create_tween()
		tween.tween_property(mesh, "position", base_pos + Vector3(0, 0, -0.6), 0.05)
		tween.tween_property(mesh, "position", base_pos, 0.1)

## Called when entity dies - play death VFX/effects.
func _on_entity_died(p_entity: Node3D) -> void:
	if p_entity == self.entity:
		play_death_effect()

## Called when entity takes damage - play hit flash/effects.
## Triggered by the replicated ServerState.damage_received signal so every
## peer (server + clients) renders the hit VFX on the damaged entity.
func _on_damage_received(_amount: int, _source: Node) -> void:
	_play_hit_effect()

## ServerState emits this only for a real, replicated HealthComponent.healed
## event; HP changes from spawning, respawning, or sync do not enter here.
func _on_heal_received(amount: int) -> void:
	_spawn_heal_burst.call_deferred(amount)

func _spawn_heal_burst(amount: int) -> void:
	if not entity or amount <= 0: return
	if entity.get("sync_is_dead"): return
	if not entity.is_inside_tree(): return

	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var burst: Node3D = preload("res://scenes/vfx/heal_burst.tscn").instantiate()
	if burst == null: return

	if burst.has_method("configure"):
		burst.configure(entity, amount)

	scene_root.add_child(burst)
	# global_position is only valid after the burst has entered the tree.
	burst.global_position = entity.global_position
	EventBus.visual_effect_requested.emit(entity, "heal")
## Play death visual effect.
func play_death_effect() -> void:
	if _actor:
		_actor.play_animation("Death")

		# Optional: Hide the model after the animation ends (approx 1.5 seconds)
		var timer = get_tree().create_timer(1.5)
		timer.timeout.connect(func(): 
			if entity.get("sync_is_dead"):
				_actor.visible = false
		)

	# Hide UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_bar_3d = get_parent().get_node_or_null("HealthBar3D")

	if name_label: name_label.visible = false
	if health_bar_3d: health_bar_3d.visible = false

	EventBus.visual_effect_requested.emit(entity, "death")

## Play spawn/respawn visual effect.
func play_spawn_effect() -> void:
	if _actor:
		_actor.visible = true
		# Force the actor into the Idle animation so mobs don't sit in
		# T-pose when the GLB importer dropped the import clip or the
		# AnimationLibrary hides the track under a library prefix.
		_actor.play_animation("Idle")
		_ensure_loop("Idle")

	# Show UI
	var name_label = get_parent().get_node_or_null("NameLabel")
	var health_bar_3d = get_parent().get_node_or_null("HealthBar3D")

	if name_label: name_label.visible = true
	# We keep legacy label hidden
	if health_bar_3d: health_bar_3d.visible = true

	EventBus.visual_effect_requested.emit(entity, "spawn")


## Play hit/damage visual effect.
func _play_hit_effect() -> void:
	if _actor:
		_actor.play_animation("Hit")
		# Short lock to ensure hit animation is visible
		_anim_lock_time = 0.3 
		
	_apply_hitstop(0.08) # Freeze for 80ms for weight
	_spawn_hit_vfx()
	EventBus.visual_effect_requested.emit(entity, "hit")

## Spawn the VFXHit_02 impact scene at the entity's current position.
## Spawned under the current scene root (not as a child of the entity) so
## the effect keeps playing if the entity dies or despawns mid-animation.
## Replicated implicitly: every peer calls this locally when its
## ServerState.damage_received signal fires.
func _spawn_hit_vfx() -> void:
	if not entity or not entity.is_inside_tree():
		return

	var scene_root := get_tree().current_scene
	if scene_root == null:
		return

	var vfx: Node3D = VFX_HIT_02_SCENE.instantiate()
	if vfx == null:
		return

	scene_root.add_child(vfx)
	vfx.global_position = entity.global_position
	# Raise the impact a touch above the feet so the burst sits on the
	# entity's torso, matching the source asset's visual reference.
	vfx.global_position.y += 1.0

	if vfx.has_method("play"):
		# Stop the VFX after a single playback and free it once the
		# animation reports finished. The asset's default `one_shot` is
		# false; setting it here keeps this helper self-contained.
		vfx.set("one_shot", true)
		# 2x playback speed → impact resolves in ~0.8s instead of 1.6s.
		# VFXControllerBB.speed_scale drives both the AnimationPlayer and
		# the GPU particle systems, so the whole burst stays in sync.
		vfx.set("speed_scale", 2.0)
		vfx.play()
		if vfx.has_signal("finished"):
			vfx.finished.connect(vfx.queue_free, CONNECT_ONE_SHOT)
		else:
			# Fallback: the impact animation is 1.6s; clean up after 2s
			# even if the script API drifts.
			var t := get_tree().create_timer(2.0)
			t.timeout.connect(vfx.queue_free)

func _apply_hitstop(duration: float) -> void:
	if _actor and _actor.animation_player:
		var original_speed = _actor.animation_player.speed_scale
		_actor.animation_player.speed_scale = 0.0
		await get_tree().create_timer(duration).timeout
		_actor.animation_player.speed_scale = original_speed

## Play an animation by name.
func play_animation(animation_name: String, blend: float = 0.2) -> void:
	if _actor:
		_actor.play_animation(animation_name, blend)

## Stop current animation.
func stop_animation() -> void:
	if _actor and _actor.animation_player:
		_actor.animation_player.stop()
