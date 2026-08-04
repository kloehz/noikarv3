class_name PetHud
extends Control

const ROLE_ICON := preload("res://client/ui/PetRoleIcon.gd")
const PET_CARD := preload("res://client/ui/PetPortraitCard.gd")

const ROLES := ["ATTACK", "TANK", "HEAL"]

var _local_player: Node
var _skill_slots: Array[Panel] = []
var _cards: Dictionary = {}
var _roster: HBoxContainer
var _rescan_time := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_skill_bar()
	_build_roster()

func set_local_player(player: Node) -> void:
	_local_player = player
	_refresh_roster()

func _process(delta: float) -> void:
	_update_preview_state()
	_rescan_time -= delta
	if _rescan_time <= 0.0:
		_rescan_time = 0.25
		_refresh_roster()

func _build_skill_bar() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -126.0
	bar.offset_top = -100.0
	bar.offset_right = 126.0
	bar.offset_bottom = -28.0
	bar.add_theme_constant_override("separation", 14)
	add_child(bar)
	for role in ROLES:
		var slot := Panel.new()
		slot.custom_minimum_size = Vector2(72, 72)
		slot.add_theme_stylebox_override("panel", _slot_style(role, false))
		bar.add_child(slot)
		_skill_slots.append(slot)
		var icon: Control = ROLE_ICON.new()
		icon.set("pet_type", role)
		icon.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		icon.position = Vector2(12, 12)
		icon.size = Vector2(48, 48)
		slot.add_child(icon)

func _build_roster() -> void:
	_roster = HBoxContainer.new()
	_roster.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_roster.offset_left = 20.0
	_roster.offset_top = 98.0
	_roster.offset_right = 580.0
	_roster.offset_bottom = 176.0
	_roster.add_theme_constant_override("separation", 10)
	add_child(_roster)

func _update_preview_state() -> void:
	var selected := -1
	if is_instance_valid(_local_player):
		var logic := _local_player.get_node_or_null("LogicComponent")
		if logic and bool(logic.get("is_previewing")):
			selected = int(logic.get("preview_type"))
	for index in _skill_slots.size():
		_skill_slots[index].add_theme_stylebox_override("panel", _slot_style(ROLES[index], index == selected))

func _refresh_roster() -> void:
	if _roster == null:
		return
	if not is_instance_valid(_local_player):
		_local_player = _find_local_player()
	if not is_instance_valid(_local_player):
		return
	var totems := get_tree().root.find_child("Totems", true, false)
	if totems == null:
		return
	var owner_id := int(_local_player.name)
	var current_ids: Dictionary[int, bool] = {}
	for pet in totems.get_children():
		if not _belongs_to_local_player(pet, owner_id):
			continue
		var pet_id := pet.get_instance_id()
		current_ids[pet_id] = true
		var card := _cards.get(pet_id) as Control
		if card == null:
			card = PET_CARD.new()
			_roster.add_child(card)
			_cards[pet_id] = card
		card.set_pet(pet, _pet_type(pet), _pet_souls(pet))
	for pet_id in _cards.keys():
		if current_ids.has(pet_id):
			continue
		var stale := _cards[pet_id] as Control
		if is_instance_valid(stale):
			stale.queue_free()
		_cards.erase(pet_id)

func _belongs_to_local_player(pet: Node, owner_id: int) -> bool:
	if not pet.has_method("setup_pet") or int(pet.get("owner_id")) != owner_id:
		return false
	var server_state := pet.get_node_or_null("ServerState")
	return server_state == null or not bool(server_state.get("sync_is_dead"))

func _pet_type(pet: Node) -> String:
	var server_state := pet.get_node_or_null("ServerState")
	if server_state and not str(server_state.get("pet_type_sync")).is_empty():
		return str(server_state.get("pet_type_sync"))
	return str(pet.get("pet_type"))

func _pet_souls(pet: Node) -> int:
	var server_state := pet.get_node_or_null("ServerState")
	if server_state:
		return int(server_state.get("power_level_sync"))
	return int(pet.get("power_level"))

func _find_local_player() -> Node:
	var players := get_tree().root.find_child("Players", true, false)
	if players == null:
		return null
	for player in players.get_children():
		if player.is_multiplayer_authority():
			return player
	return null

func _slot_style(role: String, selected: bool) -> StyleBoxFlat:
	var color := ROLE_ICON.color_for(role)
	var style := StyleBoxFlat.new()
	style.bg_color = color.darkened(0.8) if not selected else color.darkened(0.55)
	style.border_color = color.lightened(0.2) if selected else Color("25334a")
	var border_width := 3 if selected else 2
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.shadow_color = color.darkened(0.4) if selected else Color("00000080")
	style.shadow_size = 8 if selected else 4
	style.shadow_offset = Vector2(0, 2)
	return style
