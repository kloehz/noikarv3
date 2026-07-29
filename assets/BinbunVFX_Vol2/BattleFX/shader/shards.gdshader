shader_type spatial;
render_mode unshaded;

uniform float effect_decay : hint_range(0.0, 1.0, 0.01) = 0.0;

group_uniforms Color;
uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform vec3 tertiary_color : source_color;
uniform float emission = 1.0;
uniform bool use_tertiary = false;

group_uniforms Noise;
uniform sampler2D noise_texture;
uniform vec2 noise_scale = vec2(1.0);
uniform float noise_twist = 1.0;
uniform float noise_shape = 1.0;

group_uniforms Displacement;
uniform float shard_bumpyness : hint_range(0.0, 1.0, 0.1) = 0.5;
uniform float shard_sharpness : hint_range(0.0, 1.0, 0.1) = 1.0;

void vertex() {
	float wave1 = sin(UV.y * TAU * 5.0);
	float wave2 = sin(UV.x * TAU * 5.0);
	
	float wave = wave1 + wave2;
	
	float mask = pow(UV.y, 0.5);
	
	VERTEX += NORMAL * wave * 0.05 * mask * shard_bumpyness;
	VERTEX.xz = VERTEX.xz * mix(1.0, mask, shard_sharpness);
	
}

void fragment() {
	float rand_coord = COLOR.r;
	float rand_value = COLOR.g;
	
	vec2 noise_uv = UV * noise_scale;
	noise_uv.x = noise_uv.x + noise_uv.y * noise_twist;
	float noise = texture(noise_texture, noise_uv + rand_coord).r;
	
	noise = pow(noise, noise_shape);
	
	float mask = sin(UV.y * PI);
	
	float value = 1.0 - (1.0 - noise) * smoothstep(0.4, 1.0, mask);
	value = pow(value, 2.0);
	
	vec3 sec_color = rand_value < 0.5 ? secondary_color : tertiary_color;
	vec3 color = mix(secondary_color, primary_color, value);
	
	float alpha = clamp((noise - effect_decay * 2.0 + 1.0) - ((1.0 - COLOR.a)) * 2.0, 0.0, 1.0);
	
	ALBEDO = color * emission;
	
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
