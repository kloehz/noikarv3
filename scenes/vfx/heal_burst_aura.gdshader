// res://scenes/vfx/heal_burst_aura.gdshader
// Spatial aura: emissive cylindrical column with vertical pulse and soft alpha.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

uniform vec3 primary_color : source_color = vec3(0.35, 1.0, 0.55);
uniform vec3 secondary_color : source_color = vec3(0.0, 0.6, 0.25);
uniform float emission : hint_range(0.0, 6.0, 0.01) = 1.5;
uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float vertical_pulse : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float edge_softness : hint_range(0.01, 1.0, 0.01) = 0.6;

void fragment() {
	// Soft radial mask to keep the column volumetric without hard edges.
	vec2 centered = UV * 2.0 - 1.0;
	float radial = length(centered);
	float mask = 1.0 - smoothstep(0.6, 1.0, radial);

	// Vertical falloff: brightest at the middle, fades top and bottom.
	float vert = sin(UV.y * 3.14159);
	vert = pow(vert, mix(1.0, 4.0, edge_softness));

	float pulse = 0.6 + 0.4 * sin(TIME * vertical_pulse * 3.14159);

	float value = mask * vert * pulse;
	value = max(value - effect_decay, 0.0);

	vec3 color = mix(secondary_color, primary_color, value);

	ALBEDO = color * emission;
	ALPHA = clamp(value * 2.0, 0.0, 1.0);
}