package ttf_odin

import "base:intrinsics"

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:math"

import stbi "vendor:stb/image"

File_Header :: struct {
	sfntVesion:    u32be,
	numTables:     u16be,
	searchRange:   u16be,
	entrySelector: u16be,
	rangeShift:    u16be,
}

Font :: struct {
	data:         []byte,
	glyph_count:  int,
	units_per_em: int,
	loca_offset:  int,
	glyf_offset:  int,
	loca_32_bit:  bool,
}

Table_Record :: struct {
	tableTag: [4]u8 `fmt:"s"`,
	checksum: u32be `fmt:"#08x"`,
	offset:   u32be `fmt:"#08x"`,
	length:   u32be `fmt:"#08x"`,
}

Maxp_Table :: struct {
	version:   [2]u16be,
	numGlyphs: u16be,
}

Font_Header_Table :: struct #packed {
	majorVersion:       u16be,
	minorVersion:       u16be,
	fontRevision:       u32be,
	checksumAdjustment: u32be,
	magicNumber:        u32be,
	flags:              u16be,
	unitsPerEm:         u16be,
	created:            i64be,
	modified:           i64be,
	xMin:               i16be,
	yMin:               i16be,
	xMax:               i16be,
	yMax:               i16be,
	macStyle:           u16be,
	lowestRecPPEM:      u16be,
	fontDirectionHint:  i16be,
	indexToLocFormat:   i16be,
	glyphDataFormat:    i16be,
}

@(require_results)
read_typed :: proc(bytes: []byte, $T: typeid, offset: int) -> (ret: T, ok: bool) {
	if len(bytes) < size_of(T) + offset {
		return
	}
	mem.copy(&ret, &bytes[offset], size_of(T))
	ok = true
	return
}

@(require_results)
load :: proc(data: []byte) -> (font: Font, ok: bool) {
	font.data = data

	header := read_typed(data, File_Header, 0) or_return
	tables := ([^]Table_Record)(&data[size_of(header)])[:header.numTables]

	for &table in tables {
		name := strings.truncate_to_byte(string(table.tableTag[:]), 0)
		switch name {
		case "maxp":
			maxp_table      := (^Maxp_Table)(&data[table.offset])
			font.glyph_count = int(maxp_table.numGlyphs)
		case "head":
			font_header_table := (^Font_Header_Table)(&data[table.offset])
			font.units_per_em  = int(font_header_table.unitsPerEm)
			font.loca_32_bit   = font_header_table.indexToLocFormat == 1
		case "hhea":
		case "loca":
			font.loca_offset = int(table.offset)
		case "glyf":
			font.glyf_offset = int(table.offset)
		case "cmap":
			Cmap_Header :: struct {
				version, numTables: u16be,
			}

			Cmap_Platform_Id :: enum u16be {
				Unicode   = 0,
				Macintosh = 1,
				ISO       = 2,
				Windows   = 3,
				Custom    = 4,
			}

			Cmap_Encoding_Record :: struct {
				platformId: Cmap_Platform_Id,
				encodingId: u16be,
				offset:     u32be,
			}

			Cmap_Subtable_Format_12 :: struct {
				format:    u16be,
				_reserved: u16be,
				length:    u32be,
				language:  u32be,
				numGroups: u32be,
			}

			Cmap_Subtable_Format_4 :: struct {
				format:         u16be,
				length:         u16be,
				language:       u16be,
				segCountX2:     u16be,
				_searchRange:   u16be,
				_entrySelector: u16be,
				_rangeShift:    u16be,
			}

			cmap_header := (^Cmap_Header)(&data[table.offset])
			encoding_records := ([^]Cmap_Encoding_Record)(&data[table.offset + size_of(Cmap_Header)])[:cmap_header.numTables]

			record: ^Cmap_Encoding_Record
			for &r in encoding_records {
				if r.platformId != .Unicode {
					continue
				}
				if r.encodingId == 3 && record == nil {
					record = &r
				}
				if r.encodingId == 4 {
					record = &r
				}
			}

			assert(record != nil)
		case "hmtx":
			{}
		case "OS/2":
			{}
		}
	}
	
	ok = true
	return
}

Points_SOA :: struct {
	x, y: [^]f32,
}

Render_Shape :: struct {
	beziers: struct {
		a, b, c: Points_SOA,
		len:     int,
	},
	linears: struct {
		a, b: Points_SOA,
		len:  int,
	},
	min, max: [2]f32,
}

Shape :: struct {
	linears:  []Segment_Linear,
	beziers:  []Segment_Bezier,
	min, max: [2]f32,
}

Glyph :: distinct int

Glyph_Header :: struct {
	numberOfContours: i16be,
	xMin:             i16be,
	yMin:             i16be,
	xMax:             i16be,
	yMax:             i16be,
}

@(require_results)
get_glyph_header :: proc(font: Font, glyph: Glyph) -> ^Glyph_Header {
	offset, next: int
	if font.loca_32_bit {
		offset = int(([^]u32be)(&font.data[font.loca_offset])[glyph + 0])
		next   = int(([^]u32be)(&font.data[font.loca_offset])[glyph + 1])
	} else {
		offset = int(([^]u16be)(&font.data[font.loca_offset])[glyph + 0]) * 2
		next   = int(([^]u16be)(&font.data[font.loca_offset])[glyph + 1]) * 2
	}
	if offset == next {
		return nil
	}
	assert(next - offset >= size_of(Glyph_Header))
	return (^Glyph_Header)(&font.data[font.glyf_offset + int(offset)])
}

Segment_Linear :: struct { a, b:    [2]f32, }
Segment_Bezier :: struct { a, b, c: [2]f32, }

@(require_results)
glyph_get_shape :: proc(font: Font, glyph: Glyph) -> (shape: Shape) {
	glyph_header := get_glyph_header(font, glyph)
	if glyph_header == nil {
		return
	}

	shape.min.x = f32(glyph_header.xMin)
	shape.max.x = f32(glyph_header.xMax)
	shape.min.y = f32(glyph_header.yMin)
	shape.max.y = f32(glyph_header.yMax)

	linears: [dynamic]Segment_Linear
	beziers: [dynamic]Segment_Bezier

	if glyph_header.numberOfContours >= 0 {
		description        := ([^]byte)(glyph_header)[size_of(glyph_header^):]
		end_points         := ([^]u16be)(description)[:glyph_header.numberOfContours]
		instruction_length := ([^]u16be)(description)[glyph_header.numberOfContours]
		n_points           := int(end_points[glyph_header.numberOfContours - 1] + 1)
		points             := description[int(glyph_header.numberOfContours) * size_of(u16be) + size_of(u16be) + int(instruction_length):]

		flags  := make([]Simple_Glyph_Flags, n_points, context.temp_allocator)
		coords := make([][2]f32,             n_points, context.temp_allocator)

		Simple_Glyph_Flag :: enum {
	        ON_CURVE_POINT                       = intrinsics.constant_log2(0x01),
	        X_SHORT_VECTOR                       = intrinsics.constant_log2(0x02),
	        Y_SHORT_VECTOR                       = intrinsics.constant_log2(0x04),
	        REPEAT_FLAG                          = intrinsics.constant_log2(0x08),
	        X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR = intrinsics.constant_log2(0x10),
	        Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR = intrinsics.constant_log2(0x20),
	        OVERLAP_SIMPLE                       = intrinsics.constant_log2(0x40),
		}
		Simple_Glyph_Flags :: bit_set[Simple_Glyph_Flag; u8]

		flag: Simple_Glyph_Flags
		for i := 0; i < n_points; i += 1 {
			flag   = transmute(Simple_Glyph_Flags)points[0]
			points = points[1:]
			if .REPEAT_FLAG in flag {
				repeat_count := int(points[0])
				points        = points[1:]
				for j in 0 ..< repeat_count + 1 {
					flags[i + j] = flag
				}
				i += repeat_count
			} else {
				flags[i] = flag
			}
		}

		x: int
		for i in 0 ..< n_points {
			flag := flags[i]
			if .X_SHORT_VECTOR in flag {
				dx    := int(points[0])
				points = points[1:]
				x     += (.X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR in flag) ? dx : -dx
			} else {
				if .X_IS_SAME_OR_POSITIVE_X_SHORT_VECTOR not_in flag {
					x     += int((^i16be)(points)^)
					points = points[2:]
				}
			}
			coords[i].x = f32(x)
		}

		y: int
		for i in 0 ..< n_points {
			flag := flags[i]
			if .Y_SHORT_VECTOR in flag {
				dy    := int(points[0])
				points = points[1:]
				y     += (.Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR in flag) ? dy : -dy
			} else {
				if .Y_IS_SAME_OR_POSITIVE_Y_SHORT_VECTOR not_in flag {
					y     += int((^i16be)(points)^)
					points = points[2:]
				}
			}
			coords[i].y = f32(y)
		}

		current: int
		for c in 0 ..< glyph_header.numberOfContours {
			end := int(end_points[c])

			prev:    [2]f32
			prev_on: bool

			if .ON_CURVE_POINT in flags[end] {
				prev    = coords[end]
				prev_on = true
			} else {
				prev    = (coords[current] + coords[end]) / 2
				prev_on = false
			}

			start := current
			for current <= end {
				if .ON_CURVE_POINT in flags[current] {
					if prev_on {
						if prev.y < coords[current].y {
							append(&linears, Segment_Linear { a = prev, b = coords[current], })
						} else {
							append(&linears, Segment_Linear { a = coords[current], b = prev, })
						}
					} else {
						prev_on = true
					}
					prev = coords[current]
				} else {
					defer {
						bezier := &beziers[len(beziers) - 1]
						if bezier.a.y > bezier.c.y {
							bezier.a, bezier.c = bezier.c, bezier.a
						}
					}

					if current + 1 > end {
						if .ON_CURVE_POINT in flags[start] {
							append(&beziers, Segment_Bezier { a = prev, b = coords[current], c = coords[start], })
						} else {
							mid := (coords[current] + coords[start]) / 2
							append(&beziers, Segment_Bezier { a = prev, b = coords[current], c = mid, })
						}
						break
					}

					if .ON_CURVE_POINT in flags[current + 1] {
						append(&beziers, Segment_Bezier { a = prev, b = coords[current], c = coords[current + 1], })
						prev     = coords[current + 1]
						current += 1
					} else {
						mid := (coords[current] + coords[current + 1]) / 2
						append(&beziers, Segment_Bezier { a = prev, b = coords[current], c = mid, })
						prev = mid
					}
				}
				current += 1
			}

			current = end + 1
		}
	} else {
		unimplemented()
	}

	shape.beziers = beziers[:]
	shape.linears = linears[:]
	return
}

get_intersections :: proc(shape: Shape, y: f32, intersections: []f32) -> (n_intersections: int) {
	for linear in shape.linears {
	    if (
	      linear.b.y >  y &&
	      linear.a.y <= y
	    ) {
			t  := (y - linear.a.y) / (linear.b.y - linear.a.y)
			vx := (1 - t) * linear.a.x + t * linear.b.x

			intersections[n_intersections] = vx
			n_intersections               += 1
	    }
	}

	for bezier in shape.beziers {
		// if true {
		//     if (
		//       bezier.c.y >  y &&
		//       bezier.a.y <= y
		//     ) {
		// 		t  := (y - bezier.a.y) / (bezier.c.y - bezier.a.y)
		// 		vx := (1 - t) * bezier.a.x + t * bezier.c.x
		// 		intersections[n_intersections] = vx
		// 		n_intersections               += 1
		//     }
		// 	continue
		// }

	    a := bezier.a.y - 2 * bezier.b.y + bezier.c.y
	    b := -2 * bezier.a.y + 2 * bezier.b.y
	    c := bezier.a.y - y

	    t, vx, dy: f32
	    if abs(a) < 0.0001 {
			if (
				bezier.c.y >  y &&
				bezier.a.y <= y
			) {
				t  = (y - bezier.a.y) / (bezier.c.y - bezier.a.y)
				vx = (1 - t) * ((1 - t) * bezier.a.x + t * bezier.b.x) + t * ((1 - t) * bezier.b.x + t * bezier.c.x)

				intersections[n_intersections] = vx
				n_intersections               += 1
			}
			continue
	    }

		determinant := b * b - 4 * a * c
		if determinant < 0 {
			continue
		}

		bezier_curve_intersection :: proc(
		  bezier: Segment_Bezier,
		  y, dy:  f32,
		) -> bool{
			// "U"
			if bezier.b.y < bezier.a.y {
				if (dy < 0) {
					if (bezier.a.y > y) {
						return true
					}
				} else {
					if (bezier.c.y > y) {
						return true
					}
				}
			// "^"
			} else if (bezier.b.y >= bezier.c.y) {
				if (dy > 0) {
					if (bezier.a.y <= y) {
						return true
					}
						} else {
						if (bezier.c.y <= y) {
						return true
					}
				}
			// "/"
			} else {
				if (
					bezier.c.y >  y &&
					bezier.a.y <= y
				) {
					return true
				}
			}

			return false
		}


		root := math.sqrt(determinant)

		t  = (-b + root) / (2 * a)
		vx = (1 - t) * ((1 - t) * bezier.a.x + t * bezier.b.x) + t * ((1 - t) * bezier.b.x + t * bezier.c.x)
		dy = 2 * (1 - t) * (bezier.b.y - bezier.a.y) + 2 * t * (bezier.c.y - bezier.b.y)

		if abs(dy) < 0.0001 {
			if y == bezier.a.y {
				intersections[n_intersections] = bezier.a.x 
				n_intersections               += 1
			}
			continue
		}

		if (
			0 <= t && t <= 1 &&
			bezier_curve_intersection(bezier, y, dy)
		) {
			intersections[n_intersections] = vx
			n_intersections               += 1
		}

		t  = (-b - root) / (2 * a)
		vx = (1 - t) * ((1 - t) * bezier.a.x + t * bezier.b.x) + t * ((1 - t) * bezier.b.x + t * bezier.c.x)
		dy = 2 * (1 - t) * (bezier.b.y - bezier.a.y) + 2 * t * (bezier.c.y - bezier.b.y)

		if (
			0 <= t && t <= 1 &&
			bezier_curve_intersection(bezier, y, dy)
		) {
			intersections[n_intersections] = vx
			n_intersections               += 1
		}
	}

	return
}

get_codepoint_glyph :: proc(font: Font, codepoint: rune) -> Glyph {
	return 0
}

main :: proc() {
	font   := load(#load("/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf")) or_else panic("Failed to load font")
	shape  := glyph_get_shape(font, 69)
	w      := int(shape.max.x - shape.min.x) 
	h      := int(shape.max.y - shape.min.y) 
	pixels := make([]u8, w * h)

	intersections := make([]f32, len(shape.linears) + len(shape.beziers))

	for y in 0 ..< h {
		n := get_intersections(shape, f32(y) + shape.min.y + 0.5, intersections)
		slice.sort(intersections[:n])

		i := 0
		for x in 0 ..< w {
			for i < n && f32(x) + shape.min.x + 0.5 > intersections[i] {
				i += 1
			}
			if i % 2 == 1 {
				pixels[x + y * w] = 255
			}
		}
	}

	stbi.write_png("out.png", i32(w), i32(h), 1, raw_data(pixels), 0)
}
