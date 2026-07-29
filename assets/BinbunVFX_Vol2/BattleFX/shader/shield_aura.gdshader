shader_type spatial;
render_mode unshaded;

uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 1.0;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform vec2 noise_scroll = vec2(-0.2, -0.4);
uniform float noise_twist = 1.0;

uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.01) = 1.0;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			MAIN_CAM_INV_VIEW_MATRIX[0],
			MAIN_CAM_INV_VIEW_MATRIX[1],
			MAIN_CAM_INV_VIEW_MATRIX[2],
			MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 centered_uv = UV * 2.0 - 1.0;
	float radius = length(centered_uv);
	float angle = atan(centered_uv.x, centered_uv.y);
	
	float mask = max(1.0 - abs(radius * 2.0 - 1.0), 0.0);
	mask = pow(mask, 12.0);
	
	vec2 noise_uv = vec2(angle / PI, radius) + noise_scroll * TIME;
	float noise = texture(noise_texture, noise_uv).r;
	
	float value = overlay(mask, noise);
	value = max(value - effect_decay, 0.0);
	
	// Proximity Fade: Enabled
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
	proximity_view_pos.xyz /= proximity_view_pos.w;
	value *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	
	value = smoothstep(0.2, 0.4, value);
	
	vec3 color = mix(secondary_color, primary_color, value);
	
	ALBEDO = color * emission;
	
	ALPHA = value;
	
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
