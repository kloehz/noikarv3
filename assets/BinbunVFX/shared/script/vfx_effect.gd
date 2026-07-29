@tool
extends Node3D
class_name VFXEffect

var materials : Array[ShaderMaterial]
var particle_materials : Array[ParticleProcessMaterial]
var lights : Array[Light3D]
var particles : Array[GPUParticles3D]

func _ready() -> void:
	materials = _get_materials()
	lights = _get_lights()

func _get_materials() -> Array[ShaderMaterial]:
	var is_editor : bool = Engine.is_editor_hint()
	
	if !is_editor and !materials.is_empty():
		return materials
	
	var result : Array[ShaderMaterial] = []
	
	for c in get_children():
		if c is MeshInstance3D || c is GPUParticles3D:
			if c.material_override:
				result.append(c.material_override)
	
	return result

func _get_particle_materials() -> Array[ParticleProcessMaterial]:
	var is_editor : bool = Engine.is_editor_hint()
	
	if !is_editor and !particle_materials.is_empty():
		return particle_materials
	
	var result : Array[ParticleProcessMaterial] = []
	
	for c in get_children():
		if c is GPUParticles3D:
			if c.process_material:
				result.append(c.process_material)
	
	return result

func _get_lights() -> Array[Light3D]:
	var is_editor : bool = Engine.is_editor_hint()
	
	if !is_editor and !lights.is_empty():
		return lights
	
	var result : Array[Light3D] = []
	
	for c in get_children():
		if c is Light3D:
			result.append(c)
	
	return result

func _get_particles() -> Array[GPUParticles3D]:
	var is_editor : bool = Engine.is_editor_hint()
	
	if !is_editor and !particles.is_empty():
		return particles
	
	var result : Array[GPUParticles3D] = []
	
	for c in get_children():
		if c is GPUParticles3D:
			result.append(c)
	
	return result

func _set_shader_param(key : String, value : Variant) -> void:
	for m in _get_materials():
		m.set_shader_parameter(key, value)

func _set_particle_shader_param(key : String, value : Variant) -> void:
	for p in _get_particle_materials():
		p.set(key, value)

func _set_light(key : String, value : Variant) -> void:
	for l in _get_lights():
		l.set(key, value)

func _set_particles(key : String, value : Variant) -> void:
	for p in _get_particles():
		p.set(key, value)
