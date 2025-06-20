RSRC                    ShaderMaterial            ��������                                            +      resource_local_to_scene    resource_name    code    script    noise_type    seed 
   frequency    offset    fractal_type    fractal_octaves    fractal_lacunarity    fractal_gain    fractal_weighted_strength    fractal_ping_pong_strength    cellular_distance_function    cellular_jitter    cellular_return_type    domain_warp_enabled    domain_warp_type    domain_warp_amplitude    domain_warp_frequency    domain_warp_fractal_type    domain_warp_fractal_octaves    domain_warp_fractal_lacunarity    domain_warp_fractal_gain    width    height    invert    in_3d_space    generate_mipmaps 	   seamless    seamless_blend_skirt    as_normal_map    bump_strength 
   normalize    color_ramp    noise    shader !   shader_parameter/overlay_texture    shader_parameter/zoom_factor    shader_parameter/move_speed    shader_parameter/transparency    shader_parameter/enchant_color           local://Shader_kdbgb �         local://FastNoiseLite_oy6xt �
         local://NoiseTexture2D_nevoj       /   res://shaders/purple_enchantment_material.tres 4         Shader            shader_type canvas_item;

// Uniforms to control the overlay texture and transparency level
uniform sampler2D overlay_texture : hint_default_white;
uniform float zoom_factor : hint_range(1.0, 10.0) = 2.0;
uniform float move_speed : hint_range(0.0, 5.0) = 2.0;
uniform float transparency : hint_range(1.0, 100.0) = 60.0; // Transparency level between 1 and 100
uniform vec4 enchant_color : source_color = vec4(0.38, 0.00, 1.00, 0.90); // 附魔效果的颜色

void fragment() {
    // Base texture color
    vec4 base_color = texture(TEXTURE, UV);

    // Calculate offset for random movement based on time
    float offset_x = sin(TIME * move_speed * 1.3 + sin(TIME * move_speed * 0.7)) * 0.05;
    float offset_y = cos(TIME * move_speed * 0.9 + cos(TIME * move_speed * 0.5)) * 0.05;

    // Apply zoom and offset to UV coordinates for the overlay
    vec2 zoomed_uv = (UV - 0.5) / zoom_factor + 0.5 + vec2(offset_x, offset_y);

    // Sample the overlay texture
    vec4 overlay_color = texture(overlay_texture, zoomed_uv);

    // 应用附魔颜色
    overlay_color = overlay_color * enchant_color;

    // Convert transparency percentage to a 0.0 - 1.0 range
    float transparency_factor = clamp(transparency / 100.0, 0.0, 1.0);

    // Determine if the overlay should be applied per pixel
    float overlay_blend_factor = (base_color.a > 0.0) ? (transparency_factor * overlay_color.a) : 0.0;

    // Blend the overlay with the base texture using the computed blend factor
    COLOR = mix(base_color, overlay_color, overlay_blend_factor);
}
          FastNoiseLite             NoiseTexture2D    $                     ShaderMaterial    %             &            '         @(         @)        pB*      ��>?���>  �?��f?      RSRC