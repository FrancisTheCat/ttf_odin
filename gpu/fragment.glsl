layout (location = 0) in vec2 v_position;

layout (location = 0) out vec4 f_color;

uniform usampler2D u_stencil_texture;
uniform vec2       u_resolution;

void main() {
    uvec4 coord = texelFetch(u_stencil_texture, ivec2(v_position * u_resolution), 0);
    f_color = vec4(0.9, 0.9, 0.9, 1) * float(coord.x % 2);
}
