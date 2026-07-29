// res://scenes/vfx/heal_burst_model_overlay.gdshader
// Spatial lit shader: green tint that overlays the model's surface.
// Drives a fading emissive pulse so the actor "glows" briefly when healed.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled;

uniform vec3 primary_color : source_color = vec3(0.3, 1.0, 0.5);
uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float intensity : hint_range(0.0, 4.0, 0.01) = 1.5;

void fragment() {
	float pulse = 0.5 + 0.5 * sin(TIME * 6.28318);
	float value = intensity * (0.5 + 0.5 * pulse);
	value = max(value - effect_decay * 2.0, 0.0);

	ALBEDO = primary_color * value;
	ALPHA = clamp(value * 0.5, 0.0, 0.85);
}