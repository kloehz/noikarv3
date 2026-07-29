@tool
extends VFXEffect
class_name VFXLoot

@export_group("Color")

@export var primary_color : Color:
	set(v):
		primary_color = v
		_set_shader_param("primary_color", primary_color)

@export var secondary_color : Color:
	set(v):
		secondary_color = v
		_set_shader_param("secondary_color", secondary_color)

@export var emission : float = 2.0:
	set(v):
		emission = v
		_set_shader_param("emission", emission)

@export_range(0.0, 1.0, 0.01) var hue_variation : float = 0.05:
	set(v):
		hue_variation = v
		_set_shader_param("hue_variation", hue_variation)

@export_group("Light")

@export var light_color : Color:
	set(v):
		light_color = v
		_set_light("light_color", light_color)

@export_range(0.0, 16.0, 0.01) var light_energy : float = 3.0:
	set(v):
		light_energy = v
		_set_light("light_energy", light_energy)

@export_range(0.0, 16.0, 0.01) var light_indirect_energy : float = 1.0:
	set(v):
		light_indirect_energy = v
		_set_light("light_indirect_energy", light_indirect_energy)

@export_range(0.0, 16.0, 0.01) var light_volumetric_fog_energy : float = 1.0:
	set(v):
		light_volumetric_fog_energy = v
		_set_light("light_volumetric_fog_energy", light_volumetric_fog_energy)

@export_group("Shape")

@export_range(0.0, 1.0, 0.01) var density : float = 0.6:
	set(v):
		density = v
		_set_shader_param("density", density)

@export_range(0.0, 1.0, 0.01) var glow_amount : float = 1.0:
	set(v):
		glow_amount = v
		_set_shader_param("glow_amount", glow_amount)

@export_range(0.0, 1.0, 0.01) var edge_hardness : float = 0.0:
	set(v):
		edge_hardness = v
		_set_shader_param("edge_hardness", edge_hardness)

@export var shine_direction : Vector2 = Vector2(0.0, 1.0):
	set(v):
		shine_direction = v
		_set_shader_param("detail_direction", shine_direction)

@export_group("Flare")

@export_range(0.0, 1.0, 0.01) var flare_amount : float = 1.0:
	set(v):
		flare_amount = v
		_set_shader_param("flare_amount", flare_amount)

@export var flare_streaks : float = 20.0:
	set(v):
		flare_streaks = v
		_set_shader_param("flare_streaks", flare_streaks)

@export_range(0.0, 1.0, 0.01) var flare_ring : float = 0.6:
	set(v):
		flare_ring = v
		_set_shader_param("flare_ring", flare_ring)

@export_group("Particles")

@export var emitting : bool = true:
	set(v):
		emitting = v
		_set_particles("emitting", emitting)

@export var amount : int = 24:
	set(v):
		amount = v
		_set_particles("amount", amount)

@export var lifetime : float = 1.0:
	set(v):
		lifetime = v
		_set_particles("lifetime", lifetime)

@export var explosiveness : float = 0.0:
	set(v):
		explosiveness = v
		_set_particles("explosiveness", explosiveness)

@export_range(0.0,10.0,0.01) var emission_radius : float = 0.7:
	set(v):
		emission_radius = v
		_set_particle_shader_param("emission_sphere_radius", emission_radius)

@export_range(-2.0,2.0,0.01) var radial_accel : float = -.3:
	set(v):
		radial_accel = v
		_set_particle_shader_param("radial_accel", Vector2(radial_accel, radial_accel * 0.6))

@export var particle_texture : Texture2D:
	set(v):
		particle_texture = v
		_set_shader_param("particle_texture", particle_texture)
		if particle_texture:
			_set_shader_param("use_texture", true)
		else:
			_set_shader_param("use_texture", false)
