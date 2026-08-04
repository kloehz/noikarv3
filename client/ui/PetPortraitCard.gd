class_name PetPortraitCard
extends Control

const PORTRAIT_MASK := preload("res://client/ui/pet_portrait_mask.gdshader")
const ROLE_ICON := preload("res://client/ui/PetRoleIcon.gd")

var _portrait: TextureRect
var _fallback_icon: Control
var _level_badge: Label
var _background: Panel
var _viewport: SubViewport
var _world: Node3D
var _actor: CharacterActor
var _actor_path := ""

func _ready() -> void:
	custom_minimum_size = Vector2(38, 38)
	size = custom_minimum_size
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_ui()

func set_pet(pet: Node, type: String, souls: int) -> void:
	if not is_instance_valid(pet) or _background == null:
		return
	var normalized_type := type if not type.is_empty() else "ATTACK"
	_background.add_theme_stylebox_override("panel", _circle_style(ROLE_ICON.color_for(normalized_type).darkened(0.68), ROLE_ICON.color_for(normalized_type).lightened(0.15), 2))
	_fallback_icon.set("pet_type", normalized_type)
	_level_badge.text = str(maxi(0, souls))
	var actor_path := str(pet.get("character_actor_path"))
	if actor_path != _actor_path:
		_load_actor(actor_path)

func _build_ui() -> void:
	_background = Panel.new()
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background.add_theme_stylebox_override("panel", _circle_style(ROLE_ICON.color_for("ATTACK").darkened(0.68), Color("d8e5f2"), 2))
	add_child(_background)

	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	_viewport.size = Vector2i(64, 64)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	add_child(_viewport)

	_world = Node3D.new()
	_viewport.add_child(_world)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color(0.02, 0.03, 0.06, 0.0)
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color(0.9, 0.95, 1.0, 1.0)
	settings.ambient_light_energy = 1.4
	environment.environment = settings
	_world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42.0, -30.0, 0.0)
	light.light_energy = 1.25
	_world.add_child(light)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# Portraits deliberately frame the head/upper body. This keeps the useful
	# identity inside the circular mask instead of reading as a wide body pill.
	camera.size = 1.2
	camera.position = Vector3(0.0, 0.9, 3.0)
	camera.look_at_from_position(camera.position, Vector3(0.0, 0.9, 0.0), Vector3.UP)
	camera.current = true
	_world.add_child(camera)

	_portrait = TextureRect.new()
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_portrait.texture = _viewport.get_texture()
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var mask_material := ShaderMaterial.new()
	mask_material.shader = PORTRAIT_MASK
	_portrait.material = mask_material
	add_child(_portrait)

	_fallback_icon = ROLE_ICON.new()
	_fallback_icon.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_fallback_icon.position = Vector2(8, 8)
	_fallback_icon.size = Vector2(22, 22)
	add_child(_fallback_icon)

	_level_badge = Label.new()
	_level_badge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_level_badge.offset_left = -17.0
	_level_badge.offset_top = -17.0
	_level_badge.offset_right = 2.0
	_level_badge.offset_bottom = 2.0
	_level_badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_level_badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_level_badge.add_theme_font_size_override("font_size", 9)
	_level_badge.add_theme_color_override("font_color", Color.WHITE)
	_level_badge.add_theme_color_override("font_outline_color", Color("101522"))
	_level_badge.add_theme_constant_override("outline_size", 3)
	_level_badge.add_theme_stylebox_override("normal", _circle_style(Color("18243a"), Color("edf5ff"), 1))
	add_child(_level_badge)

func _load_actor(path: String) -> void:
	_actor_path = path
	_fallback_icon.visible = true
	if is_instance_valid(_actor):
		_actor.queue_free()
		_actor = null
	if path.is_empty():
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	_actor = scene.instantiate() as CharacterActor
	if _actor == null:
		return
	_actor.position = Vector3(0.0, -0.92, 0.0)
	_actor.rotation.y = _actor.visual_forward_yaw
	_world.add_child(_actor)
	_fallback_icon.visible = false

func _circle_style(background: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = 99
	style.corner_radius_top_right = 99
	style.corner_radius_bottom_left = 99
	style.corner_radius_bottom_right = 99
	return style
