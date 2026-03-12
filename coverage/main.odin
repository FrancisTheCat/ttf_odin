package coverage

import la "core:math/linalg"
import    "core:slice"
import    "core:time"

import "vendor:glfw"

import "../vendor/glodin"

import ttf ".."

main :: proc() {
	FONT_SIZE :: 100
	FONT_PATH :: "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"

	font, ok := ttf.load(#load(FONT_PATH))
	assert(ok)

	CODEPOINT :: ''
	// CODEPOINT :: ''
	glyph          := ttf.get_codepoint_glyph(font, CODEPOINT)
	shape          := ttf.get_glyph_shape(font, glyph)
	scale          := ttf.font_height_to_scale(font, FONT_SIZE)
	size_x, size_y := ttf.get_bitmap_size(font, shape, scale)
	SAMPLING_PATTERN :: ttf.SAMPLING_PATTERN_16_DEFAULT
	N                :: len(SAMPLING_PATTERN)
	P                :: bit_set[0 ..< N]

	mask_table := ttf.sampling_mask_table_generate(SAMPLING_PATTERN)
	coverage   := make([]P, size_x * size_y)
	ttf.render_shape_coverage_mask(font, shape, scale, SAMPLING_PATTERN, coverage, size_x)

	w := 900
	h := 600

	glfw.Init()
	window := glfw.CreateWindow(i32(w), i32(h), "TTF", nil, nil)
	defer glfw.DestroyWindow(window)

	glodin.init_glfw(window)
	defer glodin.uninit()

	// glfw.SwapInterval(0)

	Vertex :: struct {
		position: [2]f32,
	}

	vertex_buffer := [6]Vertex {
		0 = { position = { 0, 1, }, },
		1 = { position = { 0, 0, }, },
		2 = { position = { 1, 0, }, },

		3 = { position = { 1, 0, }, },
		4 = { position = { 1, 1, }, },
		5 = { position = { 0, 1, }, },
	}

	texture := glodin.create_texture(
		size_x + 2,
		size_y + 2,
		format     = .R16UI,
		mag_filter = .Nearest,
		min_filter = .Nearest,
		wrap       = { .Clamp_To_Border, .Clamp_To_Border, },
	)
	glodin.set_texture_data(texture, slice.reinterpret([]u16, coverage), 1, 1, size_x, size_y)
	defer glodin.destroy(texture)

	quad := glodin.create_mesh(vertex_buffer[:])
	defer glodin.destroy(quad)

	program := glodin.create_program_source(#load("vertex.glsl"), #load("fragment.glsl")) or_else panic("Failed to compile program")
	defer glodin.destroy(program)

	mask_table_u32: [len(mask_table)]u32
	for &mask, i in &mask_table_u32 {
		mask = u32(transmute(u16)mask_table[i])
	}

	mask_buffer := glodin.create_uniform_buffer(mask_table_u32[:])
	defer glodin.destroy(mask_buffer)

	glodin.set_uniforms(program, {
		{ "u_coverage",        texture,     },
		{ "mask_table_buffer", mask_buffer, },
	})

	glodin.enable(.Blend)
	glodin.enable(.Cull_Face)
	
	start_time := time.now()
	for !glfw.WindowShouldClose(window) {
		{
			new_w, new_h := glfw.GetFramebufferSize(window)
			w, h          = int(new_w), int(new_h)
		}

		current_time := f32(time.duration_seconds(time.since(start_time)))
		position     := [2]f32 {
			f32(w - size_x) / 2 + la.sin(current_time) * 10,
			f32(h - size_y) / 2 + la.cos(current_time) * 10,
		}

		// It is possible to calculate the shift in a shader, based on the non-floored position, but for the purposes of this example, I find it to be clearer to pass it in as a uniform
		glodin.set_uniform(program, "u_shift", la.array_cast(la.fract(position) * 16, i32))
		glodin.set_uniform(program, "u_transform", matrix[3, 3]f32 {
			f32(size_x + 2) / f32(w), 0, la.floor(position.x) / f32(w),
			0, f32(size_y + 2) / f32(h), la.floor(position.y) / f32(h),
			0, 0, 1,
		})

		glodin.clear_color({}, { 0.1, 0.1, 0.1, 1, })

		glodin.draw({}, program, quad)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}
