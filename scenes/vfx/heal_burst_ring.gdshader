// res://scenes/vfx/heal_burst_ring.gdshader
// Spatial torus ring with radial Fresnel + upward emission pulse.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

uniform vec3 primary_color : source_color = vec3(0.5, 1.0, 0.7);
uniform vec3 secondary_color : source_color = vec3(0.0, 0.55, 0.3);
uniform float emission : hint_range(0.0, 6.0, 0.01) = 2.0;
uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float fresnel_power : hint_range(0.5, 8.0, 0.01) = 2.0;
uniform float spin_speed : hint_range(0.0, 4.0, 0.01) = 1.0;

void vertex() {
	float angle = TIME * spin_speed;
	float c = cos(angle);
	float s = sin(angle);
	VERTEX.xy = mat2(vec2(c, -s), vec2(s, c)) * VERTEX.xy;
}

void fragment() {
	// Fresnel-style rim that brightens at glancing angles.
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);

	float value = fresnel;
	value = max(value - effect_decay, 0.0);

	vec3 color = mix(secondary_color, primary_color, value);
	ALBEDO = color * emission;
	ALPHA = clamp(value, 0.0, 1.0);
}