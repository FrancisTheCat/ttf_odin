layout (location = 0) in vec2 a_position;

layout (location = 0) out vec2 v_position;
layout (location = 1) out vec2 v_tex_coord;

uniform mat3 u_transform = mat3(1);

void main() {
    switch (gl_VertexID % 3) {
    case 0: {
        v_tex_coord = vec2(0);
    } break;
    case 1: {
        v_tex_coord = vec2(0.5, 0);
    } break;
    case 2: {
        v_tex_coord = vec2(1);
    } break;
    }

    v_position  = (u_transform * vec3(a_position, 1)).xy;
    gl_Position = vec4(v_position * 2 - 1, 0, 1);
}
