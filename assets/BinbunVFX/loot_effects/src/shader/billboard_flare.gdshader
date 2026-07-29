shader_type spatial;
render_mode unshaded, blend_mix;

#include "../../../shared/shader/util/uv_util.gdshaderinc"
#include "../../../shared/shader/util/hsl_util.gdshaderinc"

uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 2.0;
uniform float hue_variation : hint_range(0.0, 1.0, 0.01) = 0.05;

uniform float flare_streaks = 20.0;
uniform float flare_ring : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float flare_amount : hint_range(0.0, 1.0, 0.01) = 1.0;


uniform bool billboard = true;

uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;

uniform sampler2D noise_texture;

void vertex() {
	if(billboard){
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
}

void fragment() {
	vec2 polar_uv = to_polar(UV);
	
	float view_offset = (NORMAL.x * 4.0);
	
	float gradient_01 = sin((polar_uv.x * PI * (flare_streaks * 0.4)) + view_offset + TIME);
	float gradient_02 = -sin((polar_uv.x * PI * flare_streaks) - view_offset - TIME);
	
	float value = clamp(gradient_01 * gradient_02, 0.0, 1.0);
	
	float flare_mask = pow(max(sin(polar_uv.y * PI),0.0), 8.0);
	
	value = pow(value, polar_uv.y * 2.0);
	
	float ledge = 0.4 * edge_hardness;
	float redge = mix(1.0, 0.41, edge_hardness);
	value = smoothstep(ledge, redge, value);
	value *= flare_mask;
	
	float ring = max(1.0 - abs(polar_uv.y * 2.0 - 1.0),0.0);
	ring *= ring * ring * ring;
	
	value += ring * flare_ring;
	value *= flare_amount;
	
	
	ALPHA = value * 0.2;
	
	vec3 color = mix(secondary_color, primary_color, value);
	
	float noise = texture(noise_texture, UV).r;
	float hue = (noise * 2.0 - 1.0) * hue_variation;
	color = shift_hue(color, hue);
	
	ALBEDO = color * emission;
}