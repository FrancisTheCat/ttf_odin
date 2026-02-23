#version 450

layout (location = 0) in vec2 v_position;

layout (location = 0) out vec4 f_color;

uniform usampler2DMS u_stencil_texture;
uniform vec2         u_resolution;
uniform vec3         u_color;
uniform vec3         u_background;
uniform uint         u_samples;

void main() {
    uint counts[7] = { 0, 0, 0, 0, 0, 0, 0, };
    for (int offset = 0; offset < 7; offset += 1) {
        for (int sample_index = 0; sample_index < u_samples; sample_index += 1) {
            counts[offset] += texelFetch(
                u_stencil_texture,
                ivec2(v_position * u_resolution) * ivec2(3, 1) +
                ivec2(offset - 3, 0),
                sample_index
            ).x % 2;
        }
    }
    vec3 channel_weights = vec3(0);
    for (int channel = 0; channel < 3; channel += 1) {
        const float WEIGHTS[] = {
            1.0 / 9,
            2.0 / 9,
            3.0 / 9,
            2.0 / 9,
            1.0 / 9,
        };
        for (int i = 0; i < 5; i += 1) {
            channel_weights[channel] += WEIGHTS[i] * counts[i + channel];
        }
    }
    f_color.rgb = mix(u_background, u_color, pow(channel_weights / u_samples, vec3(1 / 2.2)));
}
