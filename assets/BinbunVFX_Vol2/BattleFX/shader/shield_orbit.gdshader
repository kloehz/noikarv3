shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform vec3 tertiary_color : source_color;
uniform float emission = 1.0;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform vec2 noise_scroll = vec2(-0.2, 0.4);
uniform float noise_twist = 1.0;
uniform float noise_shape = 1.0;

group_uniforms Transparency;
uniform float edge_position : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float proximity_fade_distance : hint_range(0.0, 8.0, 0.01) = 2.0;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

group_uniforms Rotation;
uniform float rotation_frequency : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float rotation_amount : hint_range(0.0, 1.0, 0.01) = 0.0;

vec2 rotate(vec2 pos, float angle)
{
	mat2 rotation = mat2(vec2(sin(angle), -cos(angle)),
						vec2(cos(angle), sin(angle)));
	
	pos = pos * rotation;
	return pos;
}

void vertex() {
	float angle_z = sin(TIME * rotation_frequency);
	float angle_x = cos(TIME * rotation_frequency * 1.5);
	
	VERTEX.xy = rotate(VERTEX.xy, angle_z * rotation_amount + (PI/2.0));
	VERTEX.zy = rotate(VERTEX.zy, angle_x * rotation_amount + (PI/2.0));
}

void fragment() {
	float mask = smoothstep(0.0, 0.6, abs(UV.y * 2.0 - 1.0));
	
	vec2 noise_uv = UV * noise_scale;
	noise_uv += noise_scroll * TIME;
	noise_uv.x = noise_uv.x + noise_uv.y * noise_twist;
	float noise = texture(noise_texture, noise_uv * 2.0).r;
	
	float value = noise - mask;
	
	
	value = smoothstep(0.0, 0.8, value);
	value = max(value - edge_position, 0.0);
	
	vec3 color = mix(secondary_color, primary_color, value);
	color = FRONT_FACING ? color : mix(tertiary_color, secondary_color, value);
	
	ALBEDO = color * emission;
	
	float alpha = clamp(value / (1.0 - edge_hardness), 0.0, 1.0);
	alpha = max(alpha - effect_decay, 0.0);
	
	// Proximity Fade: Enabled
	float proximity_depth_tex = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	vec4 ndc = OUTPUT_IS_SRGB ? vec4(vec3(SCREEN_UV, proximity_depth_tex) * 2.0 - 1.0, 1.0) : vec4(SCREEN_UV * 2.0 - 1.0, proximity_depth_tex, 1.0);
	vec4 proximity_view_pos = INV_PROJECTION_MATRIX * ndc;
	proximity_view_pos.xyz /= proximity_view_pos.w;
	alpha *= clamp(1.0 - smoothstep(proximity_view_pos.z + proximity_fade_distance, proximity_view_pos.z, VERTEX.z), 0.0, 1.0);
	
	ALPHA = alpha;
}