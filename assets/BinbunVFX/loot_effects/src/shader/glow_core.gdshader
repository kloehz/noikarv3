shader_type spatial;
render_mode unshaded, blend_add;

#include "../../../shared/shader/util/uv_util.gdshaderinc"
#include "../../../shared/shader/util/hsl_util.gdshaderinc"

uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 2.0;
uniform float hue_variation : hint_range(0.0, 1.0, 0.01) = 0.05;

uniform float glow_amount : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float fade_bottom : hint_range(0.0, 1.0, 0.01) = 0.0;

uniform float bob_amount : hint_range(0.0, 1.0, 0.01) = 0.05;

uniform sampler2D noise_texture;

void vertex(){
	VERTEX.y += sin(TIME * 2.0) * bob_amount;
}

void fragment() {
	
	float fresnel = pow(dot(VIEW, NORMAL), 4.0);
	fresnel *= glow_amount;
	
	fresnel = smoothstep(0.0,1.0,fresnel);
	
	if(fade_bottom > 0.01){
		float fade = pow((1.0 - UV.y) * 2.0 - 1.0, 0.2);
		fresnel = mix(fresnel, fresnel * fade, fade_bottom);
	}
	
	ALPHA = clamp(fresnel, 0.0 ,1.0);
	
	vec3 color = mix(secondary_color, primary_color, fresnel);
	
	float noise = texture(noise_texture, UV).r;
	float hue = (noise * 2.0 - 1.0) * (min(UV.y, 1.0 - UV.y) * 2.0) * hue_variation;
	color = shift_hue(color, hue);
	ALBEDO = color * emission;
}
