RSRC                    Shader            ��������                                                  resource_local_to_scene    resource_name    code    script           local://Shader_gqfff �          Shader          �  shader_type canvas_item;
render_mode blend_premul_alpha;

uniform sampler2D gradient;
uniform vec2 from;
uniform vec2 delta;
uniform int type;

float angle(vec2 dir) {
	return atan(dir.x / dir.y) / PI * 0.5 + (dir.y < 0.0 ? 0.75 : 0.25);
}

void fragment() {
	if (texture(TEXTURE, UV).r < 0.5) discard;
	float pos;
	switch (type)
	{
		case 0: // Line
			// Stolen again from:
			// https://iquilezles.org/articles/forgot-the-exact-link
			vec2 delta_rotated = vec2(-delta.y, delta.x);
			vec2 diff = UV - from;
			float h = dot(diff, delta_rotated) / dot(delta_rotated, delta_rotated);
			if (dot(diff, delta) > 0.0)
				pos = length(diff - h * delta_rotated) / length(delta);

			break;

		case 1: // Line Mirrored
			vec2 delta_rotated = vec2(-delta.y, delta.x);
			float h = dot(UV - from, delta_rotated) / dot(delta_rotated, delta_rotated);
			pos = length(UV - from - h * delta_rotated) / length(delta);
			break;

		case 2: // Radial
			pos = length(UV - from) / length(delta);
			break;

		case 3: // Conic
			vec2 dir = (UV - from);
			pos = mod(angle(dir) - angle(delta), 1.0);
			break;

		case 4: // Bounds
			vec2 abs_delta = abs(delta);
			vec2 abs_from = from;
			if (delta.x < 0.0) abs_from.x -= abs_delta.x;
			if (delta.y < 0.0) abs_from.y -= abs_delta.y;
			pos = min(
				min(UV.x - abs_from.x, abs_delta.x - UV.x + abs_from.x),
				min(UV.y - abs_from.y, abs_delta.y - UV.y + abs_from.y)
			) / min(abs_delta.x, abs_delta.y) * 2.0;
			break;
	}
	COLOR = texture(gradient, vec2(clamp(pos, 0.0, 0.999999), 0.5));
}
       RSRC