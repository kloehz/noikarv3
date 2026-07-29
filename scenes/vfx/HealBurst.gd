# res://scenes/vfx/HealBurst.gd
class_name HealBurst
extends Node3D

## A green heal VFX: pulsing aura, rising ring, ascending particles, soft light,
## floating "+HP" label, and a brief overlay on the healed actor's mesh.
## Autoplay via timer — no need to call play() externally; it self-frees.

const DURATION_SEC := 1.0
const OVERLAY_SEC := 0.6

const AURA_PRIMARY := Color(0.35, 1.0, 0.55, 1)
const AURA_SECONDARY := Color(0.0, 0.6, 0.25, 1)
const RING_PRIMARY := Color(0.5, 1.0, 0.7, 1)
const RING_SECONDARY := Color(0.0, 0.55, 0.3, 1)
const LIGHT_COLOR := Color(0.4, 1.0, 0.6, 1)

@onready var _aura: MeshInstance3D = $Aura
@onready var _ring: MeshInstance3D = $Ring
@onready var _light: OmniLight3D = $HealLight
@onready var _label: Label3D = $HealLabel
@onready var _particles: GPUParticles3D = $Particles

var _target: Node3D
var _amount: int = 0
var _elapsed: float = 0.0
var _original_materials: Dictionary = {}

func _ready() -> void:
	_apply_palette()
	_label.text = "+%d" % _amount if _amount > 0 else "+HP"
	_particles.emitting = true
	_apply_model_overlay()

func configure(target: Node3D, amount: int) -> void:
	_target = target
	_amount = amount

func _process(delta: float) -> void:
	_elapsed += delta
	var t: float = clamp(_elapsed / DURATION_SEC, 0.0, 1.0)

	var aura_mat: ShaderMaterial = _aura.material_override as ShaderMaterial
	if aura_mat:
		aura_mat.set_shader_parameter("effect_decay", t)
	var ring_mat: ShaderMaterial = _ring.material_override as ShaderMaterial
	if ring_mat:
		ring_mat.set_shader_parameter("effect_decay", t)

	# Animate the ring rising from the feet to the chest.
	_ring.position.y = lerpf(0.4, 1.6, t)

	# Light decays smoothly.
	var light_energy: float = lerpf(2.5, 0.0, t)
	_light.light_energy = light_energy

	# Label fades in fast then out.
	var label_alpha := 1.0
	if t < 0.1:
		label_alpha = t / 0.1
	elif t > 0.6:
		label_alpha = max(1.0 - (t - 0.6) / 0.4, 0.0)
	_label.modulate.a = label_alpha
	_label.position.y = lerp(1.6, 2.3, t)

	if _elapsed >= DURATION_SEC:
		_restore_model_materials()
		queue_free()

func _apply_palette() -> void:
	var aura_mat: ShaderMaterial = _aura.material_override as ShaderMaterial
	if aura_mat:
		aura_mat.set_shader_parameter("primary_color", AURA_PRIMARY)
		aura_mat.set_shader_parameter("secondary_color", AURA_SECONDARY)
	var ring_mat: ShaderMaterial = _ring.material_override as ShaderMaterial
	if ring_mat:
		ring_mat.set_shader_parameter("primary_color", RING_PRIMARY)
		ring_mat.set_shader_parameter("secondary_color", RING_SECONDARY)
	_light.light_color = LIGHT_COLOR

## Walk the healed actor's meshes and stash their material_override, replacing
## it with the green overlay. Materials are restored when the burst ends.
func _apply_model_overlay() -> void:
	if not _target: return
	var overlay_shader := preload("res://scenes/vfx/heal_burst_model_overlay.gdshader")
	var overlay := ShaderMaterial.new()
	overlay.shader = overlay_shader
	overlay.set_shader_parameter("primary_color", AURA_PRIMARY)

	for mesh_node in _find_mesh_instances(_target):
		var original: Material = mesh_node.material_override
		_original_materials[mesh_node.get_path()] = original
		var instance_mat: ShaderMaterial = overlay.duplicate()
		mesh_node.material_override = instance_mat

	# Schedule restore before queue_free so the overlay does not leak visually.
	get_tree().create_timer(OVERLAY_SEC).timeout.connect(_start_overlay_decay)

func _start_overlay_decay() -> void:
	if _original_materials.is_empty():
		return
	for mesh_node in _find_mesh_instances(_target):
		var mat: ShaderMaterial = mesh_node.material_override as ShaderMaterial
		if mat:
			mat.set_shader_parameter("effect_decay", 0.0)

func _restore_model_materials() -> void:
	for mesh_node in _find_mesh_instances(_target):
		if not is_instance_valid(mesh_node): continue
		var key: NodePath = mesh_node.get_path()
		if _original_materials.has(key):
			mesh_node.material_override = _original_materials[key]
	_original_materials.clear()

func _find_mesh_instances(root: Node) -> Array:
	var found: Array = []
	_recursive_collect(root, found)
	return found

func _recursive_collect(node: Node, out: Array) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		_recursive_collect(child, out)