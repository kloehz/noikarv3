# res://common/components/AbilityComponent.gd
class_name AbilityComponent
extends Node

## Server-authoritative player ability state.
## Q/E are intentionally no-op seams for future abilities. R opens a short
## attack-tagging window; the first eligible human hit from that activation
## consumes the token and applies stun.

const R_WINDOW_SECONDS: float = 3.0
const R_COOLDOWN_SECONDS: float = 30.0
const R_STUN_SECONDS: float = 1.5

@export var entity: Node
@export var server_state: ServerState
@export var r_window_remaining: float = 0.0
@export var r_cooldown_remaining: float = 0.0
@export var current_r_activation_token: int = 0
@export var consumed_r_activation_token: int = 0

func _ready() -> void:
	set_multiplayer_authority(1)
	if entity == null:
		entity = get_parent()
	if server_state == null and entity:
		server_state = entity.get_node_or_null("ServerState") as ServerState

func server_tick(delta: float) -> void:
	if not multiplayer.is_server():
		return
	if r_window_remaining > 0.0:
		r_window_remaining = maxf(0.0, r_window_remaining - delta)
	if r_cooldown_remaining > 0.0:
		r_cooldown_remaining = maxf(0.0, r_cooldown_remaining - delta)

func server_process_intents(logic: Node) -> void:
	if not multiplayer.is_server() or logic == null:
		return
	# Q/E are named, connectable seams only. Consume them so recorded one-shot
	# input does not replay into a future ability implementation accidentally.
	if logic.has_method("consume_ability_q_intent"):
		logic.consume_ability_q_intent()
	if logic.has_method("consume_ability_e_intent"):
		logic.consume_ability_e_intent()
	if logic.has_method("consume_ability_r_intent") and logic.consume_ability_r_intent():
		server_try_activate_r()

func server_try_activate_r() -> bool:
	if not multiplayer.is_server():
		return false
	if not _is_player_entity(entity):
		return false
	if r_cooldown_remaining > 0.0:
		return false
	current_r_activation_token += 1
	r_window_remaining = R_WINDOW_SECONDS
	r_cooldown_remaining = R_COOLDOWN_SECONDS
	return true

func snapshot_r_attack_token() -> int:
	if not multiplayer.is_server():
		return 0
	if r_window_remaining <= 0.0:
		return 0
	if current_r_activation_token <= 0:
		return 0
	if consumed_r_activation_token == current_r_activation_token:
		return 0
	return current_r_activation_token

func server_consume_r_stun_token(token: int, target: Node) -> bool:
	if not multiplayer.is_server():
		return false
	if token <= 0 or token != current_r_activation_token:
		return false
	if consumed_r_activation_token == token:
		return false
	if not _is_player_entity(entity) or not _is_player_entity(target):
		return false
	if target == entity:
		return false
	var target_state := target.get_node_or_null("ServerState") as ServerState
	if target_state == null:
		return false
	if not _is_opposing_team_target(target_state):
		return false
	consumed_r_activation_token = token
	target_state.apply_stun(R_STUN_SECONDS)
	return true

func _is_player_entity(candidate: Node) -> bool:
	return candidate != null and String(candidate.name).is_valid_int()

func _is_opposing_team_target(target_state: ServerState) -> bool:
	var source_team: int = server_state.team_id if server_state else TeamId.NONE
	var target_team: int = target_state.team_id
	if source_team == TeamId.NONE or target_team == TeamId.NONE:
		return true
	return source_team != target_team
