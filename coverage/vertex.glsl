#version 450

layout (location = 0) in vec2 a_position;

layout (location = 0) out vec2 v_position;
layout (location = 1) out vec2 v_tex_coords;

uniform mat3 u_transform = mat3(1);

void main() {
    v_tex_coords = vec2(a_position.x, 1 - a_position.y);
    v_position   = (u_transform * vec3(a_position, 1)).xy;
    gl_Position  = vec4(v_position * 2 - 1, 0, 1);
}
