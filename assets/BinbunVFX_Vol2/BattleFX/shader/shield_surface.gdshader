shader_type spatial;
render_mode unshaded;

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
uniform bool double_noise = true;

float overlay(float base, float blend){
	float limit = step(0.5, base);
	return mix(2.0 * base * blend, 1.0 - 2.0 * (1.0 - base) * (1.0 - blend), limit);
}

vec2 sample_uv(vec2 uv){
	uv = uv * noise_scale + noise_scroll * TIME;
	uv.x = uv.x + uv.y * noise_twist;
	return uv;
}

float sample_noise(vec2 uv) {
	vec2 noise_uv = uv;
	float noise = texture(noise_texture, noise_uv).r;
	
	return noise;
}

void vertex() {
	vec2 uv = sample_uv(UV);
	float noise = sample_noise(uv);
	float mask = sin(UV.y * PI);
	
	VERTEX += NORMAL * noise * 0.1 * mask;
}

void fragment() {
	vec2 uv = sample_uv(UV);
	
	float noise1 = sample_noise(uv);
	float noise = noise1;
	if(double_noise){
		float noise2 = sample_noise(uv * 2.0);
		noise = overlay(noise, noise2);
	}
	noise = pow(noise, noise_shape);
	
	float pass1 = pow(smoothstep(0.5, 1.0, noise), 1.0) * 0.5;
	float pass2 = pow(smoothstep(0.0, 0.5, noise), 1.5) * 0.5;
	
	float value = pass1 + pass2;
	
	float fresnel = pow(1.0 - dot(VIEW, NORMAL), 3.0);
	float wave = sin(sample_uv(UV).x * TAU * 4.0 + TIME * 4.0) * 0.4 + 0.6;
	
	value *= wave;
	value = value + fresnel;
	
	float secondary_value = smoothstep(0.0, 0.2, value);
	float primary_value = smoothstep(0.0, 1.0, value);
	
	vec3 color = mix(tertiary_color, secondary_color, secondary_value);
	color = mix(color, primary_color, primary_value);
	
	ALBEDO = color * emission;
	
	float alpha = clamp((noise + 1.0) - (effect_decay) * 2.0, 0.0, 1.0);
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
