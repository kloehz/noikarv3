# res://client/ui/DamageFlashOverlay.gd
class_name DamageFlashOverlay
extends Control

## Local-only damage feedback drawn over the HUD without consuming input.
@export var flash_alpha: float = 1.0
@export var flash_in_seconds: float = 0.03
@export var flash_out_seconds: float = 0.22

var _flash_tween: Tween
var _vignette_material: ShaderMaterial

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	modulate.a = 1.0
	_set_mouse_filter_recursive(self)
	_prepare_vignette_material()
	_set_vignette_strength(0.0)

func flash() -> void:
	if is_instance_valid(_flash_tween):
		_flash_tween.kill()
	visible = true
	_set_vignette_strength(0.0)
	_flash_tween = create_tween()
	_flash_tween.tween_method(Callable(self, "_set_vignette_strength"), 0.0, flash_alpha, flash_in_seconds)
	_flash_tween.tween_method(Callable(self, "_set_vignette_strength"), flash_alpha, 0.0, flash_out_seconds)
	_flash_tween.tween_callback(func(): visible = false)

func _prepare_vignette_material() -> void:
	var vignette := get_node_or_null("Vignette") as ColorRect
	if vignette == null:
		return
	_vignette_material = vignette.material as ShaderMaterial
	if _vignette_material:
		_vignette_material = _vignette_material.duplicate() as ShaderMaterial
		vignette.material = _vignette_material

func _set_vignette_strength(strength: float) -> void:
	if _vignette_material:
		_vignette_material.set_shader_parameter(&"flash_strength", clampf(strength, 0.0, 1.0))

func _set_mouse_filter_recursive(node: Node) -> void:
	if node is Control:
		(node as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_set_mouse_filter_recursive(child)
