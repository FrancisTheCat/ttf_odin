#version 450

layout (location = 0) in vec2 v_position;

layout (location = 0) out vec4 f_color;

uniform usampler2DMS u_stencil_texture;
uniform vec2         u_resolution;
uniform vec3         u_color;
uniform vec3         u_background;
uniform uint         u_samples;

void main() {
    uint count = 0;
    for (int sample_index = 0; sample_index < u_samples; sample_index += 1) {
        count += texelFetch(
            u_stencil_texture,
            ivec2(v_position * u_resolution),
            sample_index
        ).x % 2;
    }
    f_color.rgb = mix(u_background, u_color, pow(float(count) / u_samples, 1 / 2.2));
}
