# res://client/ui/AbilityHud.gd
extends Control

@export var observed_state: ServerState

@onready var q_label: Label = %QLabel
@onready var e_label: Label = %ELabel
@onready var r_label: Label = %RLabel

func _process(_delta: float) -> void:
	if observed_state == null:
		observed_state = _find_local_player_state()
	_update_labels()

func _update_labels() -> void:
	q_label.text = "Q: Ready (unwired)"
	e_label.text = "E: Ready (unwired)"
	if observed_state == null:
		r_label.text = "R: Ready"
		return
	if observed_state.sync_ability_r_window_remaining > 0.0:
		r_label.text = "R: Stun window %.1fs" % observed_state.sync_ability_r_window_remaining
	elif observed_state.sync_ability_r_cooldown_remaining > 0.0:
		r_label.text = "R: Cooldown %.1fs" % observed_state.sync_ability_r_cooldown_remaining
	else:
		r_label.text = "R: Ready"

func _find_local_player_state() -> ServerState:
	var players := get_tree().root.find_child("Players", true, false)
	if players == null:
		return null
	var local_id := str(multiplayer.get_unique_id())
	var player := players.get_node_or_null(local_id)
	if player == null:
		return null
	return player.get_node_or_null("ServerState") as ServerState
