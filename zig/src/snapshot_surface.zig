/// SnapshotSurface — Surface implementation that rasterizes to an in-memory pixel buffer.
///
/// Implements the Surface interface (see surface.zig) by compositing glyph
/// bitmaps from a font.Face into a RGBA pixel buffer. After processing all
/// render commands, the buffer can be written as a PNG for visual inspection.
const std = @import("std");
const surface_mod = @import("surface.zig");
const font_mod = @import("font/main.zig");
const Cell = surface_mod.Cell;
const protocol = @import("protocol.zig");
const png_writer = @import("png_writer.zig");

const SnapshotSurface = @This();

/// RGBA pixel buffer (row-major, 4 bytes per pixel).
pixels: []u8,
/// Grid dimensions in cells.
cols: u16,
rows: u16,
/// Cell dimensions in pixels (from font metrics).
cell_width: u32,
cell_height: u32,
/// Pixel dimensions of the entire image.
pixel_width: u32,
pixel_height: u32,
/// Font face for glyph rasterization.
face: *font_mod.Face,
/// Allocator for the pixel buffer.
alloc: std.mem.Allocator,
/// Output file path for the PNG.
output_path: []const u8,
/// No-op writer that discards set_title output.
tty_writer: NullWriter = .{},
/// Cursor state.
cursor_col: u16 = 0,
cursor_row: u16 = 0,
cursor_visible: bool = false,
cursor_shape: surface_mod.CursorShape = .block,

const NullWriter = struct {
    pub fn print(_: *NullWriter, comptime _: []const u8, _: anytype) !void {}
};

pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16, face: *font_mod.Face, output_path: []const u8) !SnapshotSurface {
    const pixel_width = @as(u32, cols) * face.cell_width;
    const pixel_height = @as(u32, rows) * face.cell_height;
    const buf_size = @as(usize, pixel_width) * pixel_height * 4;
    const pixels = try alloc.alloc(u8, buf_size);
    @memset(pixels, 0);

    return .{
        .pixels = pixels,
        .cols = cols,
        .rows = rows,
        .cell_width = face.cell_width,
        .cell_height = face.cell_height,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
        .face = face,
        .alloc = alloc,
        .output_path = output_path,
    };
}

pub fn deinit(self: *SnapshotSurface) void {
    self.alloc.free(self.pixels);
}

pub fn clear(self: *SnapshotSurface) void {
    @memset(self.pixels, 0);
    self.cursor_visible = false;
}

pub fn fillBg(self: *SnapshotSurface, bg: u24) void {
    const r: u8 = @intCast((bg >> 16) & 0xFF);
    const g: u8 = @intCast((bg >> 8) & 0xFF);
    const b: u8 = @intCast(bg & 0xFF);

    const total_pixels = @as(usize, self.pixel_width) * self.pixel_height;
    for (0..total_pixels) |i| {
        const offset = i * 4;
        self.pixels[offset] = r;
        self.pixels[offset + 1] = g;
        self.pixels[offset + 2] = b;
        self.pixels[offset + 3] = 255;
    }
}

pub fn writeCell(self: *SnapshotSurface, col: u16, row: u16, cell: Cell) void {
    if (col >= self.cols or row >= self.rows) return;

    const px_x = @as(u32, col) * self.cell_width;
    const px_y = @as(u32, row) * self.cell_height;

    // Fill cell rectangle with background color.
    const bg_r: u8 = @intCast((cell.bg >> 16) & 0xFF);
    const bg_g: u8 = @intCast((cell.bg >> 8) & 0xFF);
    const bg_b: u8 = @intCast(cell.bg & 0xFF);
    const bg_a: u8 = if (cell.bg == 0) 0 else 255;

    self.fillRect(px_x, px_y, self.cell_width, self.cell_height, bg_r, bg_g, bg_b, bg_a);

    // Render the glyph if present.
    if (cell.grapheme.len == 0 or std.mem.eql(u8, cell.grapheme, " ")) return;

    const view = std.unicode.Utf8View.init(cell.grapheme) catch return;
    var iter = view.iterator();
    const cp21 = iter.nextCodepoint() orelse return;
    const codepoint: u32 = cp21;
    const glyph = self.face.getGlyph(codepoint) catch return;
    if (glyph.width == 0 or glyph.height == 0) return;

    const fg_r: u8 = @intCast((cell.fg >> 16) & 0xFF);
    const fg_g: u8 = @intCast((cell.fg >> 8) & 0xFF);
    const fg_b: u8 = @intCast(cell.fg & 0xFF);

    // Position glyph within the cell using bearing offsets.
    const glyph_x: i32 = @as(i32, @intCast(px_x)) + @as(i32, @intFromFloat(glyph.offset_x));
    const glyph_y: i32 = @as(i32, @intCast(px_y)) + @as(i32, @intFromFloat(glyph.offset_y));

    const atlas_data = self.face.atlas.data;
    const atlas_stride = @as(usize, self.face.atlas.size) * self.face.atlas.format.depth();
    const depth = self.face.atlas.format.depth();

    for (0..glyph.height) |gy| {
        const dst_y = glyph_y + @as(i32, @intCast(gy));
        if (dst_y < 0 or dst_y >= @as(i32, @intCast(self.pixel_height))) continue;
        const dst_y_u: u32 = @intCast(dst_y);

        for (0..glyph.width) |gx| {
            const dst_x = glyph_x + @as(i32, @intCast(gx));
            if (dst_x < 0 or dst_x >= @as(i32, @intCast(self.pixel_width))) continue;
            const dst_x_u: u32 = @intCast(dst_x);

            const atlas_offset = (@as(usize, glyph.atlas_y) + gy) * atlas_stride + (@as(usize, glyph.atlas_x) + gx) * depth;

            const dst_offset = (@as(usize, dst_y_u) * self.pixel_width + dst_x_u) * 4;

            if (glyph.is_color and depth == 4) {
                // Color glyph (emoji): BGRA atlas data, copy as RGBA.
                const b = atlas_data[atlas_offset];
                const g = atlas_data[atlas_offset + 1];
                const r = atlas_data[atlas_offset + 2];
                const a = atlas_data[atlas_offset + 3];
                if (a > 0) {
                    self.pixels[dst_offset] = r;
                    self.pixels[dst_offset + 1] = g;
                    self.pixels[dst_offset + 2] = b;
                    self.pixels[dst_offset + 3] = a;
                }
            } else {
                // Grayscale glyph: atlas value is alpha, use fg color.
                const alpha = if (depth == 4) atlas_data[atlas_offset + 3] else atlas_data[atlas_offset];
                if (alpha > 0) {
                    // Alpha blend over existing pixel.
                    const a_f: f32 = @as(f32, @floatFromInt(alpha)) / 255.0;
                    const inv_a: f32 = 1.0 - a_f;
                    self.pixels[dst_offset] = @intFromFloat(@as(f32, @floatFromInt(fg_r)) * a_f + @as(f32, @floatFromInt(self.pixels[dst_offset])) * inv_a);
                    self.pixels[dst_offset + 1] = @intFromFloat(@as(f32, @floatFromInt(fg_g)) * a_f + @as(f32, @floatFromInt(self.pixels[dst_offset + 1])) * inv_a);
                    self.pixels[dst_offset + 2] = @intFromFloat(@as(f32, @floatFromInt(fg_b)) * a_f + @as(f32, @floatFromInt(self.pixels[dst_offset + 2])) * inv_a);
                    self.pixels[dst_offset + 3] = 255;
                }
            }
        }
    }

    // Underline decoration
    if (cell.attrs & protocol.ATTR_UNDERLINE != 0) {
        const ul_y = px_y + self.cell_height - 2;
        const ul_r: u8 = if (cell.ul_color != 0) @intCast((cell.ul_color >> 16) & 0xFF) else fg_r;
        const ul_g: u8 = if (cell.ul_color != 0) @intCast((cell.ul_color >> 8) & 0xFF) else fg_g;
        const ul_b: u8 = if (cell.ul_color != 0) @intCast(cell.ul_color & 0xFF) else fg_b;
        const cell_w = self.cell_width * @as(u32, if (cell.width > 1) cell.width else 1);
        self.drawUnderline(px_x, ul_y, cell_w, cell.ul_style, ul_r, ul_g, ul_b);
    }

    // Strikethrough decoration
    if (cell.strikethrough) {
        const st_y = px_y + self.cell_height / 2;
        const cell_w = self.cell_width * @as(u32, if (cell.width > 1) cell.width else 1);
        self.fillRect(px_x, st_y, cell_w, 1, fg_r, fg_g, fg_b, 255);
    }
}

pub fn showCursor(self: *SnapshotSurface, col: u16, row: u16) void {
    self.cursor_col = col;
    self.cursor_row = row;
    self.cursor_visible = true;
}

pub fn setCursorShape(self: *SnapshotSurface, shape: surface_mod.CursorShape) void {
    self.cursor_shape = shape;
}

pub fn scrollRegion(_: *SnapshotSurface, _: u16, _: u16, _: i16) void {
    // Scroll is a no-op for snapshots since we receive the full frame.
}

pub fn render(self: *SnapshotSurface) !void {
    // Render cursor if visible.
    if (self.cursor_visible and self.cursor_col < self.cols and self.cursor_row < self.rows) {
        const cx = @as(u32, self.cursor_col) * self.cell_width;
        const cy = @as(u32, self.cursor_row) * self.cell_height;
        switch (self.cursor_shape) {
            .block => self.fillRect(cx, cy, self.cell_width, self.cell_height, 200, 200, 200, 180),
            .beam => self.fillRect(cx, cy, 2, self.cell_height, 200, 200, 200, 220),
            .underline => self.fillRect(cx, cy + self.cell_height -| 2, self.cell_width, 2, 200, 200, 200, 220),
        }
    }

    try png_writer.writePng(self.alloc, self.output_path, self.pixels, self.pixel_width, self.pixel_height);
}

pub fn width(self: *SnapshotSurface) u16 {
    return self.cols;
}

pub fn height(self: *SnapshotSurface) u16 {
    return self.rows;
}

// ── Internal helpers ─────────────────────────────────────────────────────────

fn fillRect(self: *SnapshotSurface, x: u32, y: u32, w: u32, h: u32, r: u8, g: u8, b: u8, a: u8) void {
    for (0..h) |dy| {
        const py = y + @as(u32, @intCast(dy));
        if (py >= self.pixel_height) break;
        for (0..w) |dx| {
            const px = x + @as(u32, @intCast(dx));
            if (px >= self.pixel_width) break;
            const offset = (@as(usize, py) * self.pixel_width + px) * 4;
            if (a == 255) {
                self.pixels[offset] = r;
                self.pixels[offset + 1] = g;
                self.pixels[offset + 2] = b;
                self.pixels[offset + 3] = 255;
            } else if (a > 0) {
                const a_f: f32 = @as(f32, @floatFromInt(a)) / 255.0;
                const inv_a: f32 = 1.0 - a_f;
                self.pixels[offset] = @intFromFloat(@as(f32, @floatFromInt(r)) * a_f + @as(f32, @floatFromInt(self.pixels[offset])) * inv_a);
                self.pixels[offset + 1] = @intFromFloat(@as(f32, @floatFromInt(g)) * a_f + @as(f32, @floatFromInt(self.pixels[offset + 1])) * inv_a);
                self.pixels[offset + 2] = @intFromFloat(@as(f32, @floatFromInt(b)) * a_f + @as(f32, @floatFromInt(self.pixels[offset + 2])) * inv_a);
                self.pixels[offset + 3] = @max(self.pixels[offset + 3], a);
            }
        }
    }
}

fn drawUnderline(self: *SnapshotSurface, x: u32, y: u32, w: u32, style: u3, r: u8, g: u8, b: u8) void {
    switch (style) {
        0 => {
            // Single straight line
            self.fillRect(x, y, w, 1, r, g, b, 255);
        },
        1 => {
            // Curl (sine wave approximation)
            for (0..w) |dx| {
                const px = x + @as(u32, @intCast(dx));
                if (px >= self.pixel_width) break;
                const phase: f32 = @as(f32, @floatFromInt(dx)) * std.math.pi * 2.0 / @as(f32, @floatFromInt(self.cell_width));
                const wave_y: i32 = @as(i32, @intCast(y)) + @as(i32, @intFromFloat(@sin(phase) * 1.5));
                if (wave_y >= 0 and wave_y < @as(i32, @intCast(self.pixel_height))) {
                    const offset = (@as(usize, @intCast(wave_y)) * self.pixel_width + px) * 4;
                    self.pixels[offset] = r;
                    self.pixels[offset + 1] = g;
                    self.pixels[offset + 2] = b;
                    self.pixels[offset + 3] = 255;
                }
            }
        },
        2 => {
            // Dashed
            for (0..w) |dx| {
                if ((dx / 3) % 2 == 0) {
                    const px = x + @as(u32, @intCast(dx));
                    if (px >= self.pixel_width) break;
                    if (y < self.pixel_height) {
                        const offset = (@as(usize, y) * self.pixel_width + px) * 4;
                        self.pixels[offset] = r;
                        self.pixels[offset + 1] = g;
                        self.pixels[offset + 2] = b;
                        self.pixels[offset + 3] = 255;
                    }
                }
            }
        },
        3 => {
            // Dotted
            for (0..w) |dx| {
                if (dx % 2 == 0) {
                    const px = x + @as(u32, @intCast(dx));
                    if (px >= self.pixel_width) break;
                    if (y < self.pixel_height) {
                        const offset = (@as(usize, y) * self.pixel_width + px) * 4;
                        self.pixels[offset] = r;
                        self.pixels[offset + 1] = g;
                        self.pixels[offset + 2] = b;
                        self.pixels[offset + 3] = 255;
                    }
                }
            }
        },
        4 => {
            // Double
            self.fillRect(x, y, w, 1, r, g, b, 255);
            if (y + 2 < self.pixel_height) {
                self.fillRect(x, y + 2, w, 1, r, g, b, 255);
            }
        },
        else => {
            // Fall back to single line for unknown styles.
            self.fillRect(x, y, w, 1, r, g, b, 255);
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// Compile-time verification that SnapshotSurface satisfies the Surface interface.
comptime {
    surface_mod.assertSurface(SnapshotSurface);
}
