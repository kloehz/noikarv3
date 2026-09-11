shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform vec3 flash_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float flash_strength : hint_range(0.0, 1.0) = 0.0;
uniform float max_alpha : hint_range(0.0, 1.0) = 0.85;

void fragment() {
	ALBEDO = flash_color;
	ALPHA = flash_strength * max_alpha;
}
