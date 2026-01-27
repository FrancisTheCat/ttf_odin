package ttf_odin

import "base:intrinsics"

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:simd"
import "core:strings"
import "core:time"
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
	cmap_offset:  int,
	cmap_record:  ^Cmap_Encoding_Record,
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
	groups:    [0]Sequential_Map_Group,
}

Sequential_Map_Group :: struct {
	startCharCode: u32be,
	endCharCode:   u32be,
	startGlyphId:  u32be,
}

Cmap_Subtable_Format_4 :: struct {
	format:         u16be,
	length:         u16be,
	language:       u16be,
	segCountX2:     u16be,
	_searchRange:   u16be,
	_entrySelector: u16be,
	_rangeShift:    u16be,
	data:           [0]byte,
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
			font.cmap_offset = int(table.offset)

			Cmap_Header :: struct {
				version, numTables: u16be,
			}

			cmap_header      := (^Cmap_Header)(&data[table.offset])
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
			font.cmap_record = record
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

Range :: struct {
	min, max: f32,
}

Render_Shape :: struct {
	beziers: struct {
		y_ranges:   [^]Range,
		p0, p1, p2: Points_SOA,
		n_chunks:   int,
	},
	linears: struct {
		y_ranges:  [^]Range,
		a, b:      Points_SOA,
		n_chunks:  int,
	},
	min, max: [2]f32,
}

Shape :: struct {
	linears:         []Segment_Linear,
	beziers:         []Segment_Bezier,
	linear_y_ranges: []Range,
	bezier_y_ranges: []Range,
	linear_chunks:   int,
	bezier_chunks:   int,
	min, max:        [2]f32,
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

Segment_Linear :: struct { a, b:       [2]f32, }
Segment_Bezier :: struct { p0, p1, p2: [2]f32, }

@(require_results)
glyph_get_shape :: proc(font: Font, glyph: Glyph, allocator := context.allocator) -> (shape: Shape) {
	glyph_header := get_glyph_header(font, glyph)
	if glyph_header == nil {
		return
	}

	shape.min.x = f32(glyph_header.xMin)
	shape.max.x = f32(glyph_header.xMax)
	shape.min.y = f32(glyph_header.yMin)
	shape.max.y = f32(glyph_header.yMax)

	linears := make([dynamic]Segment_Linear, allocator)
	beziers := make([dynamic]Segment_Bezier, allocator)

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
						bezier := pop(&beziers)
						if bezier.p0.y > bezier.p2.y {
							bezier.p0, bezier.p2 = bezier.p2, bezier.p0
						}
						denom := bezier.p0.y - 2 * bezier.p1.y + bezier.p2.y
						if abs(denom) < 0.0001 {
							append(&beziers, bezier)
						} else {
							t_split := (bezier.p0.y - bezier.p1.y) / denom
							if 0 < t_split && t_split < 1 {
								assert((bezier.p1.y > bezier.p2.y) != (bezier.p1.y < bezier.p0.y))

								q0 := math.lerp(bezier.p0, bezier.p1, t_split)
								q1 := math.lerp(bezier.p1, bezier.p2, t_split)
								s  := math.lerp(q0,        q1,        t_split)

								if bezier.p1.y > bezier.p2.y {
									append(&beziers, Segment_Bezier { bezier.p0, q0, s, })
									append(&beziers, Segment_Bezier { bezier.p2, q1, s, })
								} else {
									append(&beziers, Segment_Bezier { s, q0, bezier.p0, })
									append(&beziers, Segment_Bezier { s, q1, bezier.p2, })
								}
							} else {
								append(&beziers, bezier)
							}
						}
					}

					if current + 1 > end {
						if .ON_CURVE_POINT in flags[start] {
							append(&beziers, Segment_Bezier { p0 = prev, p1 = coords[current], p2 = coords[start], })
						} else {
							mid := (coords[current] + coords[start]) / 2
							append(&beziers, Segment_Bezier { p0 = prev, p1 = coords[current], p2 = mid, })
						}
						break
					}

					if .ON_CURVE_POINT in flags[current + 1] {
						append(&beziers, Segment_Bezier { p0 = prev, p1 = coords[current], p2 = coords[current + 1], })
						prev     = coords[current + 1]
						current += 1
					} else {
						mid := (coords[current] + coords[current + 1]) / 2
						append(&beziers, Segment_Bezier { p0 = prev, p1 = coords[current], p2 = mid, })
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

	when ODIN_DEBUG do for bezier in beziers {
		assert(bezier.p0.y <= bezier.p1.y)
		assert(bezier.p1.y <= bezier.p2.y)
	}

	// Build acceleration structure

	slice.sort_by(linears[:], proc(a, b: Segment_Linear) -> bool {
		return a.a.y < b.a.y
	})
	slice.sort_by(beziers[:], proc(a, b: Segment_Bezier) -> bool {
		return a.p0.y < b.p0.y
	})

	#assert((RENDER_CHUNK_SIZE - 1) & RENDER_CHUNK_SIZE == 0)
	shape.bezier_chunks = (len(beziers) + RENDER_CHUNK_SIZE - 1) / RENDER_CHUNK_SIZE
	shape.linear_chunks = (len(linears) + RENDER_CHUNK_SIZE - 1) / RENDER_CHUNK_SIZE

	shape.bezier_y_ranges = make([]Range, shape.bezier_chunks, allocator)
	shape.linear_y_ranges = make([]Range, shape.linear_chunks, allocator)

	max_y := min(f32)
	for chunk in 0 ..< shape.linear_chunks {
		i     := chunk * RENDER_CHUNK_SIZE
		min_y := max(f32)
		for j in 0 ..< RENDER_CHUNK_SIZE {
			if i + j >= len(linears) {
				break
			}

			linear := linears[i + j]
			min_y   = min(min_y, linear.a.y, linear.b.y)
			max_y   = max(max_y, linear.a.y, linear.b.y)
		}
		shape.linear_y_ranges[chunk] = { min = min_y, max = max_y, }
	}

	max_y = min(f32)
	for chunk in 0 ..< shape.bezier_chunks {
		i     := chunk * RENDER_CHUNK_SIZE
		min_y := max(f32)
		for j in 0 ..< RENDER_CHUNK_SIZE {
			if i + j >= len(beziers) {
				break
			}

			bezier := beziers[i + j]
			min_y   = min(min_y, bezier.p0.y, bezier.p1.y, bezier.p2.y)
			max_y   = max(max_y, bezier.p0.y, bezier.p1.y, bezier.p2.y)
		}
		shape.bezier_y_ranges[chunk] = { min = min_y, max = max_y, }
	}

	shape.beziers = beziers[:]
	shape.linears = linears[:]
	return
}

get_intersections :: proc(
	shape:         Shape,
	y:             f32,
	intersections: []f32,
	min_linear :=  0,
	max_linear := -1,
	min_bezier :=  0,
	max_bezier := -1,
) -> (n_intersections: int) {
	max_linear := max_linear >= 0 ? max_linear : len(shape.linears)
	max_bezier := max_bezier >= 0 ? max_bezier : len(shape.beziers)

	for linear in shape.linears[min_linear:max_linear] {
		if !(linear.a.y <= y && y < linear.b.y) {
			continue
	    }

		t  := (y - linear.a.y) / (linear.b.y - linear.a.y)
		vx := (1 - t) * linear.a.x + t * linear.b.x

		intersections[n_intersections] = vx
		n_intersections               += 1
	}

	for bezier in shape.beziers[min_bezier:max_bezier] {
		if !(bezier.p0.y <= y && y < bezier.p2.y) {
			continue
		}

		a := bezier.p0.y - 2 * bezier.p1.y + bezier.p2.y
		b := -2 * bezier.p0.y + 2 * bezier.p1.y
		c := bezier.p0.y - y

		t: f32
		if abs(a) < 0.0001 {
			t = (y - bezier.p0.y) / (bezier.p2.y - bezier.p0.y)
	    } else {
			t = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
	    }

		vx                            := math.lerp(math.lerp(bezier.p0.x, bezier.p1.x, t), math.lerp(bezier.p1.x, bezier.p2.x, t), t)
		intersections[n_intersections] = vx
		n_intersections               += 1
	}

	return
}

RENDER_CHUNK_SIZE :: 8

@(require_results)
get_render_shape :: proc(shape: Shape, allocator := context.allocator) -> (render_shape: Render_Shape) {
	round_up :: proc(x, y: int) -> int {
		mask := y - 1
		return (x + mask) &~ mask
	}

	linears_len                  := round_up(len(shape.linears), RENDER_CHUNK_SIZE)
	beziers_len                  := round_up(len(shape.beziers), RENDER_CHUNK_SIZE)
	allocation_len               := 4 * linears_len + 6 * beziers_len + 2 * linears_len / RENDER_CHUNK_SIZE + 2 * beziers_len / RENDER_CHUNK_SIZE
	allocation                   := ([^]f32)(mem.alloc(allocation_len * size_of(f32), RENDER_CHUNK_SIZE * size_of(f32), allocator) or_else panic("Failed to allocate memory"))[:allocation_len]

	render_shape.beziers.p0.x     = raw_data(allocation);           allocation = allocation[beziers_len:]
	render_shape.beziers.p0.y     = raw_data(allocation);           allocation = allocation[beziers_len:]
	render_shape.beziers.p1.x     = raw_data(allocation);           allocation = allocation[beziers_len:]
	render_shape.beziers.p1.y     = raw_data(allocation);           allocation = allocation[beziers_len:]
	render_shape.beziers.p2.x     = raw_data(allocation);           allocation = allocation[beziers_len:]
	render_shape.beziers.p2.y     = raw_data(allocation);           allocation = allocation[beziers_len:]

	render_shape.linears.a.x      = raw_data(allocation);           allocation = allocation[linears_len:]
	render_shape.linears.a.y      = raw_data(allocation);           allocation = allocation[linears_len:]
	render_shape.linears.b.x      = raw_data(allocation);           allocation = allocation[linears_len:]
	render_shape.linears.b.y      = raw_data(allocation);           allocation = allocation[linears_len:]

	render_shape.beziers.y_ranges = auto_cast raw_data(allocation); allocation = allocation[2 * beziers_len / RENDER_CHUNK_SIZE:]
	render_shape.linears.y_ranges = auto_cast raw_data(allocation); allocation = allocation[2 * linears_len / RENDER_CHUNK_SIZE:]

	assert(len(allocation) == 0)

	render_shape.beziers.n_chunks = beziers_len / RENDER_CHUNK_SIZE
	max_y := min(f32)
	for chunk in 0 ..< render_shape.beziers.n_chunks {
		i     := chunk * RENDER_CHUNK_SIZE
		min_y := max(f32)
		for j in 0 ..< RENDER_CHUNK_SIZE {
			if i + j >= len(shape.beziers) {
				break
			}

			bezier := shape.beziers[i + j]

			render_shape.beziers.p0.x[i + j] = bezier.p0.x
			render_shape.beziers.p0.y[i + j] = bezier.p0.y
			render_shape.beziers.p1.x[i + j] = bezier.p1.x
			render_shape.beziers.p1.y[i + j] = bezier.p1.y
			render_shape.beziers.p2.x[i + j] = bezier.p2.x
			render_shape.beziers.p2.y[i + j] = bezier.p2.y

			min_y = min(min_y, bezier.p0.y, bezier.p1.y, bezier.p2.y)
			max_y = max(max_y, bezier.p0.y, bezier.p1.y, bezier.p2.y)
		}
		render_shape.beziers.y_ranges[chunk] = { min = min_y, max = max_y, }
	}

	render_shape.linears.n_chunks = linears_len / RENDER_CHUNK_SIZE
	max_y = min(f32)
	for chunk in 0 ..< render_shape.linears.n_chunks {
		i     := chunk * RENDER_CHUNK_SIZE
		min_y := max(f32)
		for j in 0 ..< RENDER_CHUNK_SIZE {
			if i + j >= len(shape.linears) {
				break
			}

			linear := shape.linears[i + j]

			render_shape.linears.a.x[i + j] = linear.a.x
			render_shape.linears.a.y[i + j] = linear.a.y
			render_shape.linears.b.x[i + j] = linear.b.x
			render_shape.linears.b.y[i + j] = linear.b.y

			min_y = min(min_y, linear.a.y, linear.b.y)
			max_y = max(max_y, linear.a.y, linear.b.y)
		}
		render_shape.linears.y_ranges[chunk] = { min = min_y, max = max_y, }
	}

	render_shape.min = shape.min
	render_shape.max = shape.max

	return
}

get_intersections_simd :: proc(
	shape:                    Render_Shape,
	y:                        f32,
	intersections:            []f32,
	start_linear, end_linear: ^int,
	start_bezier, end_bezier: ^int,
) -> (n_intersections: int) {
	for start_linear^ < shape.linears.n_chunks && y > shape.linears.y_ranges[start_linear^].max {
		start_linear^ += 1
	}
	for end_linear^ < shape.linears.n_chunks && y >= shape.linears.y_ranges[end_linear^].min {
		end_linear^ += 1
	}

	for start_bezier^ < shape.beziers.n_chunks && y > shape.beziers.y_ranges[start_bezier^].max {
		start_bezier^ += 1
	}
	for end_bezier^ < shape.beziers.n_chunks && y >= shape.beziers.y_ranges[end_bezier^].min {
		end_bezier^ += 1
	}

	for chunk in start_linear^ ..< end_linear^ {
		offset   := chunk * RENDER_CHUNK_SIZE
		ax       := (^#simd[RENDER_CHUNK_SIZE]f32)(&shape.linears.a.x[offset])^
		ay       := (^#simd[RENDER_CHUNK_SIZE]f32)(&shape.linears.a.y[offset])^
		bx       := (^#simd[RENDER_CHUNK_SIZE]f32)(&shape.linears.b.x[offset])^
		by       := (^#simd[RENDER_CHUNK_SIZE]f32)(&shape.linears.b.y[offset])^
		y        := ( #simd[RENDER_CHUNK_SIZE]f32)(y)
		hit_mask := simd.lanes_gt(by, y) & simd.lanes_le(ay, y)
		t        := (y - ay) / (by - ay)
		vx       := (1 - t) * ax + t * bx

		hits   := simd.to_array(hit_mask)
		values := simd.to_array(vx)
		for i in 0 ..< RENDER_CHUNK_SIZE {
			if hits[i] == 0 {
				continue
			}

			intersections[n_intersections] = values[i]
			n_intersections               += 1
		}
	}

	for chunk in start_bezier^ ..< end_bezier^ {
		N           :: RENDER_CHUNK_SIZE

		offset      := chunk * RENDER_CHUNK_SIZE

		p0x         := (^#simd[N]f32)(&shape.beziers.p0.x[offset])^
		p0y         := (^#simd[N]f32)(&shape.beziers.p0.y[offset])^
		p1x         := (^#simd[N]f32)(&shape.beziers.p1.x[offset])^
		p1y         := (^#simd[N]f32)(&shape.beziers.p1.y[offset])^
		p2x         := (^#simd[N]f32)(&shape.beziers.p2.x[offset])^
		p2y         := (^#simd[N]f32)(&shape.beziers.p2.y[offset])^
		y           := ( #simd[N]f32)(y)

		a           := p0y - 2 * p1y + p2y
		b           := -2 * p0y + 2 * p1y
		c           := p0y - y

		linear_mask := simd.lanes_lt(simd.abs(a), 0.0001)
		hit_mask    := simd.lanes_gt(p2y, y) & simd.lanes_le(p0y, y)

		t_linear    := (y - p0y) / (p2y - p0y)
		t_bezier    := (-b + simd.sqrt(b * b - 4 * a * c)) / (2 * a)

		t           := simd.select(linear_mask, t_linear, t_bezier)
		vx          := math.lerp(math.lerp(p0x, p1x, t), math.lerp(p1x, p2x, t), t)
		values      := simd.to_array(vx)
		hits        := simd.to_array(hit_mask)

		for i in 0 ..< N {
			if hits[i] == 0 {
				continue
			}

			intersections[n_intersections] = values[i]
			n_intersections               += 1
		}
	}
	return
}

get_intersections_fast :: proc(
	shape:                    Shape,
	y:                        f32,
	intersections:            []f32,
	start_linear, end_linear: ^int,
	start_bezier, end_bezier: ^int,
) -> (n_intersections: int) {
	for start_linear^ < shape.linear_chunks && y > shape.linear_y_ranges[start_linear^].max {
		start_linear^ += 1
	}
	for end_linear^ < shape.linear_chunks && y >= shape.linear_y_ranges[end_linear^].min {
		end_linear^ += 1
	}

	for start_bezier^ < shape.bezier_chunks && y > shape.bezier_y_ranges[start_bezier^].max {
		start_bezier^ += 1
	}
	for end_bezier^ < shape.bezier_chunks && y >= shape.bezier_y_ranges[end_bezier^].min {
		end_bezier^ += 1
	}

	return get_intersections(
		shape,
		y,
		intersections,
		min(start_linear^ * RENDER_CHUNK_SIZE, len(shape.linears)),
		min(end_linear^   * RENDER_CHUNK_SIZE, len(shape.linears)),
		min(start_bezier^ * RENDER_CHUNK_SIZE, len(shape.beziers)),
		min(end_bezier^   * RENDER_CHUNK_SIZE, len(shape.beziers)),
	)
}

get_codepoint_glyph :: proc(font: Font, codepoint: rune) -> Glyph {
	codepoint := u32(codepoint)

	if font.cmap_record.platformId != .Unicode {
		return 0
	}

	switch font.cmap_record.encodingId {
	case 3:
		subtable := (^Cmap_Subtable_Format_4)(&font.data[font.cmap_offset + int(font.cmap_record.offset)])
		assert(subtable.format == 4)

		seg_count := u32(subtable.segCountX2 / 2)

		data           := ([^]u16be)(raw_data(&subtable.data))
		endCodes       :=                   data[:seg_count]; data = data[seg_count:]
		data            =                   data[1:]
		startCodes     :=                   data[:seg_count]; data = data[seg_count:]
		idDeltas       := transmute([]i16be)data[:seg_count]; data = data[seg_count:]
		idRangeOffsets :=                   data[:seg_count]; data = data[seg_count:]
		glyphIdArray   :=                   data

		// TODO: do binary search
		for i in 0 ..< seg_count {
			start := u32(startCodes[i])
			end   := u32(endCodes[i])

			if !(start <= codepoint && codepoint <= end) {
				continue
			}

			delta := u32(idDeltas[i])

			if idRangeOffsets[i] == 0 {
				return Glyph((codepoint + delta) & 0xFFFF)
			}

			range_offset := u32(idRangeOffsets[i]) / 2
			glyph_index  := range_offset + (codepoint - start) - (seg_count - i)

			glyph := u32(glyphIdArray[glyph_index])
			if glyph == 0 {
				return 0
			}

			return Glyph((glyph + delta) & 0xFFFF)
		}
	case 4:
		subtable := (^Cmap_Subtable_Format_12)(&font.data[font.cmap_offset + int(font.cmap_record.offset)])
		assert(subtable.format == 12)
		#no_bounds_check groups := subtable.groups[:subtable.numGroups]
		group_index, found      := slice.binary_search_by(groups, codepoint, proc(group: Sequential_Map_Group, codepoint: u32) -> slice.Ordering {
			switch {
			case u32(group.startCharCode) > codepoint:
				return .Greater
			case u32(group.endCharCode) < codepoint:
				return .Less
			case:
				return .Equal
			}
		})
		if !found {
			return 0
		}
		return Glyph(u32(groups[group_index].startGlyphId) + codepoint - u32(groups[group_index].startCharCode))
	case:
		return 0
	}
	return 0
}

Y_SAMPLES :: 4

get_bitmap_size :: proc(font: Font, shape: Shape, font_size: f32) -> (w: int, h: int) {
	scale := font_size / f32(font.units_per_em)
	w      = int((shape.max.x - shape.min.x) * scale) + 2
	h      = int((shape.max.y - shape.min.y) * scale) + 2
	return
}

render_shape_bitmap :: proc(
	font:      Font,
	shape:     Shape,
	font_size: f32,
	pixels:    []u8,
	stride:    int = -1,
) {
	stride := stride

	intersections: [Y_SAMPLES][]f32
	for &i in intersections {
		i = make([]f32, len(shape.linears) + len(shape.beziers), context.temp_allocator)
	}

	scale := font_size / f32(font.units_per_em)
	w, h  := get_bitmap_size(font, shape, font_size)

	if stride <= 0 {
		stride = w
	}

	assert(len(pixels) >= stride * h)

	start_linear, end_linear: [Y_SAMPLES]int
	start_bezier, end_bezier: [Y_SAMPLES]int

	for y in 0 ..< h {
		n: [Y_SAMPLES]int
		for y_sample in 0 ..< Y_SAMPLES {
			render_y   := (f32(y) + f32(y_sample) / Y_SAMPLES - 0.5) / scale + shape.min.y
			n[y_sample] = get_intersections_fast(
				shape,
				render_y,
				intersections[y_sample],
				&start_linear[y_sample],
				&end_linear[y_sample],
				&start_bezier[y_sample],
				&end_bezier[y_sample],
			)
			slice.sort(intersections[y_sample][:n[y_sample]])
		}

		i: [Y_SAMPLES]int
		for x in 0 ..< w {
			coverage: f32
			for y_sample in 0 ..< Y_SAMPLES {
				start_x := (f32(x)     - 0.5) / scale + shape.min.x
				end_x   := (f32(x + 1) - 0.5) / scale + shape.min.x
				prev    := start_x

				for (
				    i[y_sample] < n[y_sample] &&
				    intersections[y_sample][i[y_sample]] < end_x
				) {
					ix := intersections[y_sample][i[y_sample]]

					if i[y_sample] & 1 == 1 {
						coverage += ix - prev
					}

					prev         = ix
					i[y_sample] += 1
				}

				if i[y_sample] & 1 == 1 {
					coverage += end_x - prev
				}
			}
			pixels[x + (h - y - 1) * w] = u8(255.999 * math.pow(scale * coverage / Y_SAMPLES, 1 / 2.2))
		}
	}
}

main :: proc() {
	FONT_SIZE :: 18

	// font   := load(#load("/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf")) or_else panic("Failed to load font")
	// font   := load(#load("/usr/share/fonts/inter/InterVariable.ttf"              )) or_else panic("Failed to load font")
	font   := load(#load("/usr/share/fonts/TTF/Inconsolata-Regular.ttf"          )) or_else panic("Failed to load font")
	glyph  := get_codepoint_glyph(font, '?')
	shape  := glyph_get_shape(font, glyph)
	w, h   := get_bitmap_size(font, shape, FONT_SIZE)
	pixels := make([]u8, w * h)

	start_fast := time.now()

	render_shape_bitmap(font, shape, FONT_SIZE, pixels)

	fmt.println("time:", time.since(start_fast))
	stbi.write_png("out.png", i32(w), i32(h), 1, raw_data(pixels), 0)
}
