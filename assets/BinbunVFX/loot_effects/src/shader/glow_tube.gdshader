shader_type spatial;
render_mode unshaded, cull_disabled, blend_add;

#include "../../../shared/shader/util/uv_util.gdshaderinc"
#include "../../../shared/shader/util/hsl_util.gdshaderinc"
#include "../../../shared/shader/util/blend_util.gdshaderinc"

uniform vec3 primary_color : source_color;
uniform vec3 secondary_color : source_color;
uniform float emission = 2.0;
uniform float hue_variation : hint_range(0.0, 1.0, 0.01) = 0.05;

uniform bool align = false;

uniform sampler2D noise_texture;

uniform float edge_hardness : hint_range(0.0, 1.0, 0.01) = 0.0;

uniform vec2 direction = vec2(1.0,0.0);
uniform vec2 detail_direction = vec2(0.0,1.0);

uniform float density : hint_range(0.0, 1.0, 0.01) = 0.6;
uniform float streaks : hint_range(0.0, 64.0, 0.5) = 8.0;

uniform float scroll = 1.0;
uniform float scale = 2.0;
uniform float falloff = 4.0;

void vertex() {
	VERTEX.y += sin(TIME * 2.0) * 0.05;
}

void fragment() {
	float dir = dot(UV, direction);
	
	float gradient = 1.0 - abs(mod(((dir - 0.5) * scale * 2.0) + TIME * scroll, 2.0) - 1.0);
	gradient *= gradient;
	float fresnel = dot(VIEW, NORMAL);
	fresnel = fresnel * fresnel * fresnel;
	
	float glow = gradient * fresnel;
	
	vec2 detail_uv = align ? vec2(UV.y, UV.x) : UV;
	float detail_dir = dot(detail_uv, detail_direction);
	float detail = abs(mod((detail_dir - 0.5) * streaks + TIME, 2.0) - 1.0);
	detail = sqrt(detail) * 2.0 - (2.0 - density);
	glow *= detail;
	
	float ledge = 0.03 * edge_hardness;
	float redge = mix(0.4, 0.03, edge_hardness);
	glow = smoothstep(ledge, redge, glow);
	
	float noise = texture(noise_texture, UV).r;
	
	glow = overlay(glow, noise);
	
	ALPHA = clamp(glow, 0.0 ,1.0);
	
	vec3 color = mix(secondary_color, primary_color, fresnel);
	
	float hue = noise * 2.0 - 1.0;
	hue *= hue_variation;
	color = shift_hue(color, hue);
	ALBEDO = color * (emission / 2.0);
}
