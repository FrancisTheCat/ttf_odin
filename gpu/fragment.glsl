#version 450

layout (location = 0) in vec2 v_position;
layout (location = 1) in vec2 v_tex_coord;

uniform bool u_bezier = false;

void main() {
    if (u_bezier && v_tex_coord.x * v_tex_coord.x - v_tex_coord.y > 0) {
        discard;
    }
}
