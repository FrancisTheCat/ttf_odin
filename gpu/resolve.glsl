layout (location = 0) in vec2 v_position;

layout (location = 0) out vec4 f_color;

uniform usampler2DMS u_stencil_texture;
uniform vec2         u_resolution;
uniform vec4         u_color;
uniform uint         u_samples;

void main() {
    uint count = 0;
    for (int i = 0; i < u_samples; i += 1) {
        count += texelFetch(u_stencil_texture, ivec2(v_position * u_resolution), i).x % 2;
    }
    f_color = u_color * pow(float(count) / float(u_samples), 1 / 2.2);
}
