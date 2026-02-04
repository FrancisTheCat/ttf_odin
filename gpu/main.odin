package gpu_text

import "core:fmt"

import "vendor:glfw"

import "../../glodin"

import ttf ".."

main :: proc() {
	FONT_SIZE :: 20
	FONT_PATH :: "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"

	font, ok := ttf.load(#load(FONT_PATH))
	assert(ok)

	CODEPOINT :: ''
	// CODEPOINT :: 'T'
	glyph := ttf.get_codepoint_glyph(font, CODEPOINT)
	shape := ttf.get_glyph_shape(font, glyph)

	w := 900
	h := 600

	glfw.Init()
	window := glfw.CreateWindow(i32(w), i32(h), "TTF", nil, nil)
	defer glfw.DestroyWindow(window)

	glodin.init_glfw(window)
	defer glodin.uninit()

	glodin.window_size_callback(w, h)

	Vertex :: struct {
		position: [2]f32,
	}
	vertex_buffer := make([]Vertex, len(shape.linears) * 3 + len(shape.beziers) * 3, context.temp_allocator)
	for linear, i in shape.linears {
		vertex_buffer[i * 3 + 1].position = linear.a / 1000
		vertex_buffer[i * 3 + 2].position = linear.b / 1000
	}
	for bezier, i in shape.beziers {
		i                                := i + len(shape.linears)
		vertex_buffer[i * 3 + 1].position = bezier.p0 / 1000
		vertex_buffer[i * 3 + 2].position = bezier.p2 / 1000
	}

	mesh := glodin.create_mesh(vertex_buffer)
	defer glodin.destroy(mesh)

	vertex_buffer = make([]Vertex, len(shape.linears) * 2 + 1, context.temp_allocator)

	vertex_buffer[0] = { { 0, 0, }, }
	vertex_buffer[1] = { { 0, 1, }, }
	vertex_buffer[2] = { { 1, 0, }, }

	vertex_buffer[3] = { { 1, 1, }, }
	vertex_buffer[4] = { { 1, 0, }, }
	vertex_buffer[5] = { { 0, 1, }, }

	quad := glodin.create_mesh(vertex_buffer)
	defer glodin.destroy(quad)

	program := glodin.create_program_source(#load("vertex.glsl"), #load("fragment.glsl")) or_else panic("Failed to compile program")
	defer glodin.destroy(program)

	stencil_texture := glodin.create_texture(
		w,
		h,
		format     = .Stencil8,
		mag_filter = .Nearest,
		min_filter = .Nearest,
	)
	defer glodin.destroy(stencil_texture)

	fb := glodin.create_framebuffer({}, stencil_texture = stencil_texture)
	defer glodin.destroy(fb)

	glodin.set_uniforms(program, {
		{ "u_stencil_texture", stencil_texture,           },
		{ "u_resolution",      [2]f32{ f32(w), f32(h), }, },
	})

	glodin.enable(.Stencil_Test)
	glodin.set_stencil_op(.Keep, .Keep, .Incr_Wrap)

	for !glfw.WindowShouldClose(window) {
		{
			new_w, new_h := glfw.GetFramebufferSize(window)
			if int(new_w) != w || int(new_h) != h {
				glodin.destroy(stencil_texture)
				glodin.destroy(fb)

				w = int(new_w)
				h = int(new_h)

				stencil_texture = glodin.create_texture(
					w,
					h,
					format     = .Stencil8,
					mag_filter = .Nearest,
					min_filter = .Nearest,
				)
				fb = glodin.create_framebuffer({}, stencil_texture = stencil_texture)

				glodin.set_uniforms(program, {
					{ "u_stencil_texture", stencil_texture,           },
					{ "u_resolution",      [2]f32{ f32(w), f32(h), }, },
				})
			}
		}

		glodin.clear_stencil(fb, 0)
		glodin.draw(fb, program, mesh)

		glodin.clear_color({}, { 0.1, 0.1, 0.1, 1, })
		glodin.draw({}, program, quad)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}
