extends Control
## Noikar's editable modal; row metadata keeps Steam IDs as signed 64-bit ints.
var service: Node
var _previous_focus: Control
@onready var rows: VBoxContainer = $Center/Card/VBox/Scroll/Rows
@onready var row_template: Button = $Center/Card/VBox/Scroll/Rows/RowTemplate
@onready var status: Label = $Center/Card/VBox/Status

func configure(adapter: Node) -> void:
	service = adapter

func open() -> void:
	if service == null or not service.can_invite_friends(): return
	_previous_focus = get_viewport().gui_get_focus_owner()
	show()
	refresh()
	$Center/Card/VBox/Actions/Close.grab_focus()

func refresh() -> void:
	for child in rows.get_children():
		if child == row_template: continue
		rows.remove_child(child)
		child.queue_free()
	if service == null or not service.can_invite_friends():
		close()
		return
	var friends: Array = service.get_invite_friends()
	status.text = service.last_error if not service.last_error.is_empty() else "Select a friend to request an invitation."
	if friends.is_empty() and service.last_error.is_empty(): status.text = "No Steam friends are available."
	for friend in friends:
		var row := row_template.duplicate() as Button
		row.set_meta("steam_id", int(friend.id))
		row.text = "%s · %s%s" % [friend.name, "Online" if friend.online else "Offline", " · Already joined" if friend.in_lobby else " · Invite"]
		row.disabled = friend.in_lobby
		row.pressed.connect(_invite.bind(int(friend.id)))
		rows.add_child(row)
		row.show()

func _invite(id: int) -> void:
	if not service.can_invite_friends():
		close()
		return
	if service.invite_friend(id):
		status.text = "Invitation requested. Delivery and acceptance are not confirmed."
	else:
		status.text = service.last_error

func close() -> void:
	hide()
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree(): _previous_focus.grab_focus()

func _process(_delta: float) -> void:
	if visible and (service == null or not service.can_invite_friends()): close()

func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
