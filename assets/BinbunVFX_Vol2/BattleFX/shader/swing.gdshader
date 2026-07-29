shader_type spatial;
render_mode unshaded, cull_disabled;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform vec3 tertiary_color : source_color;
uniform float emission = 2.0;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform vec2 noise_scroll = vec2(0.5, 0.0);
uniform float noise_shape = 1.0;

group_uniforms Shape;
uniform float swing_center : hint_range(0.0, 1.0, 0.01) = 0.9;

group_uniforms Transparency;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.8;

uniform float swing_factor : hint_range(0.0, 1.0, 0.01) = 0.5;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	
	float radius = length(centered_uv);
	float angle = atan(centered_uv.x, centered_uv.y);
	
	float factor = swing_factor * TAU - PI;
	float shape_mask = max(sin(angle + factor), 0.0);
	float base_mask = max(sin(angle), 0.0);
	float color_mask = (1.0 - sin(angle / 2.0 + factor / 2.0)) * 3.0;
	
	float shape = clamp((radius - 0.2) / (0.8 - (1.0 - swing_center)), 0.0, 1.0) - clamp((radius - swing_center) / (1.0 - swing_center), 0.0, 1.0);
	float wave = (sin((radius * TAU - TIME) * 6.0) * 0.5 + 0.5);
	shape = max(shape - wave * 0.1, 0.0);
	shape = pow(shape, 3.0);
	
	vec2 noise_uv = vec2(angle / TAU, radius * 0.5) * noise_scale;
	noise_uv += noise_scroll * TIME;
	float noise = texture(noise_texture, noise_uv).r;
	noise = pow(noise, noise_shape);
	
	float value = overlay(shape, noise);
	value = (value - (1.0 - shape_mask) * 0.5) * shape_mask;
	value *= base_mask;
	value = clamp(value - edge_position, 0.0, 1.0);
	
	
	vec3 color = mix(secondary_color, primary_color, value);
	color = mix(tertiary_color, color, color_mask);
	
	ALBEDO = color * emission;
	
	float alpha = clamp(value / (1.0 - edge_hardness), 0.0, 1.0);
	ALPHA = alpha;
}