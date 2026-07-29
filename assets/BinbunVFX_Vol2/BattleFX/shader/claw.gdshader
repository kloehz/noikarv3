shader_type spatial;
render_mode unshaded;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 2.0;

uniform float claw_factor : hint_range(0.0, 1.0, 0.01) = 0.5;

float sample_mask(vec2 uv) {
	float mask = -sin(uv.x * TAU);
	
	float factor = 1.0 - max((uv.x - 0.5) / 0.5 + (claw_factor * 2.0 - 1.0), 0.0);
	factor = 1.0 - abs(factor * 2.0 - 1.0);
	
	mask *= factor;
	
	return clamp(mask, 0.0, 1.0);
}

void vertex() {
	float mask = sample_mask(UV);
	
	VERTEX -= NORMAL * (1.0 - mask) * 0.1;
}

void fragment() {
	float mask = sample_mask(UV);
	
	vec3 color = mix(primary_color, secondary_color, (UV.x - 0.5) * 2.0);
	
	ALBEDO = color * emission;
	
	ALPHA = step(0.01, mask);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}