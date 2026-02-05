package gpu_text

import "core:fmt"
import "core:time"

import "vendor:glfw"

import "glodin"

import ttf ".."

SAMPLES  :: 8
SUBPIXEL :: true

main :: proc() {
	FONT_SIZE :: 1000
	FONT_PATH :: "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"

	font, ok := ttf.load(#load(FONT_PATH))
	assert(ok)

	CODEPOINT :: ''
	// CODEPOINT :: ''
	glyph := ttf.get_codepoint_glyph(font, CODEPOINT)
	shape := ttf.get_glyph_shape(font, glyph)
	scale := ttf.font_height_to_scale(font, FONT_SIZE)

	w := 900
	h := 600

	glfw.Init()
	window := glfw.CreateWindow(i32(w), i32(h), "TTF", nil, nil)
	defer glfw.DestroyWindow(window)

	glodin.init_glfw(window)
	defer glodin.uninit()

	glfw.SwapInterval(0)

	Vertex :: struct {
		position: [2]f32,
	}

	vertex_buffer := make([]Vertex, len(shape.linears) * 3 + len(shape.beziers) * 3, context.temp_allocator)
	for linear, i in shape.linears {
		vertex_buffer[i * 3 + 0].position = (shape.min + shape.max) * 0.5
		vertex_buffer[i * 3 + 1].position = linear.a
		vertex_buffer[i * 3 + 2].position = linear.b
	}
	for bezier, i in shape.beziers {
		i                                := i + len(shape.linears)
		vertex_buffer[i * 3 + 0].position = (shape.min + shape.max) * 0.5
		vertex_buffer[i * 3 + 1].position = bezier.p0
		vertex_buffer[i * 3 + 2].position = bezier.p2
	}

	mesh := glodin.create_mesh(vertex_buffer)
	defer glodin.destroy(mesh)

	vertex_buffer = vertex_buffer[:len(shape.beziers) * 3]
	for bezier, i in shape.beziers {
		vertex_buffer[i * 3 + 0].position = bezier.p0
		vertex_buffer[i * 3 + 1].position = bezier.p1
		vertex_buffer[i * 3 + 2].position = bezier.p2
	}

	bezier_mesh := glodin.create_mesh(vertex_buffer)
	defer glodin.destroy(bezier_mesh)

	vertex_buffer = make([]Vertex, len(shape.linears) * 2 + 1, context.temp_allocator)

	vertex_buffer[0] = { { 0, 0, }, }
	vertex_buffer[1] = { { 0, 1, }, }
	vertex_buffer[2] = { { 1, 0, }, }

	vertex_buffer[3] = { { 1, 1, }, }
	vertex_buffer[4] = { { 1, 0, }, }
	vertex_buffer[5] = { { 0, 1, }, }

	quad := glodin.create_mesh(vertex_buffer)
	defer glodin.destroy(quad)

	stencil_program := glodin.create_program_source(#load("vertex.glsl"), #load("fragment.glsl")) or_else panic("Failed to compile program")
	defer glodin.destroy(stencil_program)

	when SUBPIXEL {
		resolve_program := glodin.create_program_source(#load("vertex.glsl"), #load("subpixel.glsl")) or_else panic("Failed to compile program")
	} else {
		resolve_program := glodin.create_program_source(#load("vertex.glsl"), #load("resolve.glsl")) or_else panic("Failed to compile program")
	}
	defer glodin.destroy(resolve_program)

	stencil_texture := glodin.create_texture(w * 3, h, format = .Stencil8, samples = SAMPLES)
	defer glodin.destroy(stencil_texture)

	// add a color texture to prevent renderdoc from shitting itself
	when ODIN_DEBUG {
		color_texture := glodin.create_texture(w * 3, h, format = .RGBA8, samples = SAMPLES)
		defer glodin.destroy(color_texture)
		color_textures := []glodin.Texture { color_texture, }
	} else {
		color_textures := []glodin.Texture {}
	}

	fb := glodin.create_framebuffer(color_textures, stencil_texture = stencil_texture)
	defer glodin.destroy(fb)

	glodin.set_uniforms(resolve_program, {
		{ "u_stencil_texture", stencil_texture,           },
		{ "u_resolution",      [2]f32{ f32(w), f32(h), }, },
		{ "u_color",           [3]f32{ 0.9, 0.9, 0.9,  }, },
		{ "u_background",      [3]f32{ 0.1, 0.1, 0.1,  }, },
		{ "u_samples",         u32(SAMPLES),              },
	})

	glodin.set_uniform(stencil_program, "u_transform", matrix[3, 3]f32{
		scale / f32(w),              0, 0,
		             0, scale / f32(h), 0,
		             0,              0, 0,
	})

	glodin.enable(.Stencil_Test)
	glodin.set_stencil_op(.Keep, .Keep, .Incr_Wrap)

	glodin.set_min_sample_shading(1)

	print_time := time.now()
	print_frames: int

	for !glfw.WindowShouldClose(window) {
		if time.since(print_time) > time.Second {
			glfw.SetWindowTitle(window, fmt.ctprint(print_frames))
			print_time   = time.time_add(print_time, time.Second)
			print_frames = 0
		}
		print_frames += 1

		{
			new_w, new_h := glfw.GetFramebufferSize(window)
			if int(new_w) != w || int(new_h) != h {
				glodin.destroy(stencil_texture)
				glodin.destroy(fb)

				w = int(new_w)
				h = int(new_h)

				render_width := w
				if SUBPIXEL {
					render_width *= 3
				}

				stencil_texture = glodin.create_texture(render_width, h, format = .Stencil8, samples = SAMPLES)

				when ODIN_DEBUG {
					glodin.destroy(color_texture)

					color_texture  = glodin.create_texture(render_width, h, format = .RGBA8, samples = SAMPLES)
					color_textures = []glodin.Texture { color_texture, }
				} else {
					color_textures = []glodin.Texture {}
				}

				fb = glodin.create_framebuffer(color_textures, stencil_texture = stencil_texture)

				glodin.set_uniforms(resolve_program, {
					{ "u_stencil_texture", stencil_texture,           },
					{ "u_resolution",      [2]f32{ f32(w), f32(h), }, },
				})
				glodin.set_uniform(stencil_program, "u_transform", matrix[3, 3]f32{
					scale / f32(w),              0, 0,
					             0, scale / f32(h), 0,
					             0,              0, 0,
				})
			}
		}

		glodin.clear_stencil(fb, 0)
		glodin.draw(fb, stencil_program, mesh)

		glodin.enable(.Sample_Shading)

		glodin.set_uniform(stencil_program, "u_bezier", true)
		glodin.draw(fb, stencil_program, bezier_mesh)
		glodin.set_uniform(stencil_program, "u_bezier", false)

		glodin.disable(.Sample_Shading)

		glodin.clear_color({}, { 0.1, 0.1, 0.1, 1, })
		glodin.draw({}, resolve_program, quad)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}
