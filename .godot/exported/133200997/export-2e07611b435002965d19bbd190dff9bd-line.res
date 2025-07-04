RSRC                    Shader            ��������                                                  resource_local_to_scene    resource_name    code    script           local://Shader_h0m0e �          Shader          �  shader_type canvas_item;
render_mode blend_premul_alpha;

uniform vec4 color;
uniform vec2 origin;
uniform vec2 delta;
uniform float width;
uniform bool enable_aa;


float get_sdf(vec2 pos) {
	if (delta == vec2(0.0)) return float(-1.0);
	
	float h = clamp(dot(pos, delta) / dot(delta, delta), 0.0, 1.0);
	return length(pos - h * delta);
}


vec4 sdf_to_color(float sdf) {
	if (enable_aa)
		return vec4(color.rgb, mix(
			0.0,
			color.a,
			(width * 0.5 - sdf) * 2.0
		));
	else
		return vec4(color.rgb, 1.0 - floor(sdf / (width * 0.5)));
}

void fragment() {
	COLOR = sdf_to_color(get_sdf(
		floor(UV / TEXTURE_PIXEL_SIZE) - origin
	));
}
       RSRC