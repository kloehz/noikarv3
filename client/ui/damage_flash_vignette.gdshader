shader_type canvas_item;

uniform vec4 flash_color : source_color = vec4(0.95, 0.0, 0.0, 1.0);
uniform float flash_strength : hint_range(0.0, 1.0) = 0.0;
uniform float edge_width : hint_range(0.01, 0.5) = 0.28;
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.42;

void fragment() {
	float nearest_edge = min(min(UV.x, 1.0 - UV.x), min(UV.y, 1.0 - UV.y));
	float vignette = 1.0 - smoothstep(0.0, edge_width, nearest_edge);
	COLOR = vec4(flash_color.rgb, flash_color.a * edge_alpha * flash_strength * vignette);
}
