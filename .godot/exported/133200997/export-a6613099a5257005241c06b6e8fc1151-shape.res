RSRC                    Shader            ��������                                                  resource_local_to_scene    resource_name    code    script           local://Shader_sks4o �          Shader          {  shader_type canvas_item;
render_mode blend_premul_alpha;

uniform int shape_index;
// if you are reading this file and know 
// what hint_color is called in 4.0
// please open an issue or pull request
uniform vec4 color_border;
uniform vec4 color_fill;
uniform vec2 origin;
uniform vec2 shape_size;
uniform float border_width;
uniform vec2 drag_delta;
uniform bool enable_aa;


float get_sdf(vec2 pos, vec2 size) {
	size -= vec2(1.0);
	if (size == vec2(0.0)) return -1.0;
	switch(shape_index) {
		case 0: // Rect
			return min(
				min(pos.x, size.x - pos.x),
				min(pos.y, size.y - pos.y)
			);

		case 1: // Ellipse
			// Stolen from:
			// https://iquilezles.org/articles/ellipsedist/
			vec2 extents = size * 0.5;
			vec2 posf = abs(vec2(pos) - extents);

			vec2 q = extents * (posf - extents);
			vec2 cs = normalize(q.x < q.y ? vec2(0.01, 1) : vec2(1, 0.01));
			for (int i = 0; i < 3; i++) {
				vec2 u = extents * vec2(+cs.x, cs.y);
				vec2 v = extents * vec2(-cs.y, cs.x);
				float a = dot(posf - u, v);
				float c = dot(posf - u, u) + dot(v, v);
				float b = sqrt(c * c - a * a);
				cs = vec2(cs.x * b - cs.y * a, cs.y * b + cs.x * a) / c;
			}

			float d = length(posf - extents * cs);
			return dot(posf / extents, posf / extents) > 1.0 ? -d : d;

		case 2: // RA Triangle
			float aspect = size.x / size.y;
			float distance_to_diag = 0.0;
			if ((drag_delta.x < 0.0) == (drag_delta.y < 0.0))
				// Main diag
				if (drag_delta.x < drag_delta.y)
					// Bottom filled
					distance_to_diag = (pos.x - pos.y * aspect);
				
				else
					// Top filled
					// !!! incorrest sdf
					distance_to_diag = (pos.y * aspect - pos.x);

			else
				// Secondary diag
				if (drag_delta.x < -drag_delta.y)
					// Bottom filled
					// !!! incorrest sdf
					distance_to_diag = (pos.y * aspect - size.x + pos.x);

				else
					// Top filled
					distance_to_diag = (size.x - pos.x - pos.y * aspect);

			float rect_dist = min(
				min(pos.x, size.x - pos.x),
				min(pos.y, size.y - pos.y)
			);
			return min(distance_to_diag / aspect, rect_dist);

		case 3: // Diamond
			vec2 from_center = abs(vec2(pos * 2.0) - size) * 0.5;
			from_center.y *= size.x / size.y;
			return size.x * 0.5 - (from_center.x + from_center.y);

		case 4: // Hex
			if ((drag_delta.x < 0.0) == (drag_delta.y < 0.0)) {
				pos = pos.yx;
				size = size.yx;
			}
			vec2 diamond_from_center = abs(pos * 2.0 - size) * vec2(0.25, 0.5);
			return size.x * 0.5 - max(
				diamond_from_center.x + diamond_from_center.y * size.x / size.y,
				abs(pos.x - size.x * 0.5)
			);

	return -1.0;
}


vec4 sdf_to_color(float sdf) {
	// Debug
//	return vec4(sdf * 0.1, -sdf * 0.1, 0.0, 1.0);
	if (sdf < -0.5) {
		return vec4(color_border.rgb, 0.0);
	}
	if (sdf < 0.0 && enable_aa) {
		sdf = (0.5 + sdf) * 2.0;
		return mix(vec4(color_border.rgb, 0.0), color_border, sdf * sdf);
	}
	if (sdf <= border_width - 0.5) {
		return color_border;
	}
	if (sdf < border_width && enable_aa) {
		sdf = -(sdf - border_width + 0.5) * 2.0;
		return mix(color_fill, color_border, 1.0 - sdf * sdf);
	}
	return color_fill;
}

void fragment() {
	COLOR = sdf_to_color(get_sdf(
		floor(UV / TEXTURE_PIXEL_SIZE) - origin,
		shape_size
	));
}
       RSRC