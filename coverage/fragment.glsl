#version 450

layout (location = 0) in vec2 v_position;
layout (location = 1) in vec2 v_tex_coords;

layout (location = 0) out vec4 f_color;

uniform usampler2D u_coverage;
uniform ivec2      u_shift;

#define N 16

uniform mask_table_buffer {
	uint u_mask_table[N];
};

void main() {
    uvec4 coverage = textureGather(u_coverage, v_tex_coords, 0);
    uint  tl       = coverage.x;
    uint  tr       = coverage.y;
    uint  bl       = coverage.w;
    uint  br       = coverage.z;
	uint  xmask    = u_mask_table[u_shift.x];
	uint  ymask    = (1 << u_shift.y) - 1; // `(1 << (N - 1 - u_shift.y)) - 1` without flipped UVs

	uint result = (
		bl & ~xmask & ~ymask |
		br &  xmask & ~ymask |
		tl & ~xmask &  ymask |
		tr &  xmask &  ymask
	);

	float alpha = float(bitCount(result)) / N;
    f_color     = vec4(0.9, 0.9, 0.9, 1) * pow(alpha, 1 / 2.2);
}
