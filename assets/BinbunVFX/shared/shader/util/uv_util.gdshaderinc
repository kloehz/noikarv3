vec2 to_polar(vec2 uv)
{
	vec2 dir = uv - 0.5;
	float radius = length(dir) * 2.0;
	float angle = atan(dir.y, dir.x) * 1.0/(PI * 2.0);
	return vec2(angle, radius);
}

vec2 rotate(vec2 uv, vec2 pivot, float angle)
{
	mat2 rotation = mat2(vec2(sin(angle), -cos(angle)),
						vec2(cos(angle), sin(angle)));
	
	uv -= pivot;
	uv = uv * rotation;
	uv += pivot;
	return uv;
}

vec2 local_uv(vec2 screen_uv, vec4 node_clip){
	vec2 local_uv = (screen_uv * 2.0 - 1.0) * node_clip.w - node_clip.xy;
	
	return local_uv;
}