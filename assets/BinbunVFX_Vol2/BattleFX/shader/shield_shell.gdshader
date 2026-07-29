shader_type spatial;
render_mode unshaded;

uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 2.0;

group_uniforms Transparency;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.01) = 2.0;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	float fresnel = 1.0 - dot(VIEW, NORMAL);
	
	float value = smoothstep(0.0, 1.0, fresnel);
	
	// Proximity Fade: Enabled
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
	proximity_view_pos.xyz /= proximity_view_pos.w;
	value *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	
	vec3 color = mix(secondary_color, primary_color, value);
	
	ALBEDO = color * emission;
	
	ALPHA = max(value - effect_decay, 0.0);
}