/// FreeType font loader, loads and rasterizes glyphs on Linux.
///
/// The snapshot renderer only needs a narrow subset of FreeType: open a
/// monospace font, read cell metrics, and rasterize individual codepoints into
/// alpha bitmaps. Font discovery is intentionally simple and deterministic so
/// snapshots do not depend on fontconfig match results.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Atlas = @import("atlas.zig");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const FreeTypeFont = @This();

library: c.FT_Library,
face: c.FT_Face,
cell_width: u32,
cell_height: u32,
ascent: f64,
descent: f64,
leading: f64,
scale: f64,
alloc: Allocator,

/// Glyph information stored after rasterization.
pub const GlyphInfo = struct {
    /// Region in the atlas where this glyph's bitmap lives.
    atlas_x: u32,
    atlas_y: u32,
    width: u32,
    height: u32,

    /// Bearing offsets for positioning relative to the cell origin.
    offset_x: f64,
    offset_y: f64,

    /// FreeType path stores text glyphs as alpha masks, not color glyphs.
    is_color: bool,
};

/// Load a font for Linux snapshots. `name` may be an absolute font file path.
/// Otherwise the loader falls back to common monospace font paths available on
/// Debian, Ubuntu, Fedora, and Arch-based systems.
pub fn init(alloc: Allocator, name: []const u8, size: f64, scale: f64) !FreeTypeFont {
    var library: c.FT_Library = undefined;
    if (c.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
    errdefer _ = c.FT_Done_FreeType(library);

    const font_path = try resolveFontPath(name);
    const font_path_z = try alloc.dupeZ(u8, font_path);
    defer alloc.free(font_path_z);

    var face: c.FT_Face = undefined;
    if (c.FT_New_Face(library, font_path_z.ptr, 0, &face) != 0) return error.FontNotFound;
    errdefer _ = c.FT_Done_Face(face);

    const pixel_size: c.FT_UInt = @intFromFloat(@ceil(size * scale));
    if (c.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.FontSizeFailed;

    const metrics = face.*.size.*.metrics;
    const ascent = fixed26Dot6ToFloat(metrics.ascender);
    const descent = -fixed26Dot6ToFloat(metrics.descender);
    const height = fixed26Dot6ToFloat(metrics.height);
    const leading = @max(0.0, height - ascent - descent);
    const advance = try monospaceAdvance(face);

    return .{
        .library = library,
        .face = face,
        .cell_width = @max(1, @as(u32, @intFromFloat(@ceil(advance)))),
        .cell_height = @max(1, @as(u32, @intFromFloat(@ceil(height)))),
        .ascent = ascent,
        .descent = descent,
        .leading = leading,
        .scale = scale,
        .alloc = alloc,
    };
}

pub fn deinit(self: *FreeTypeFont) void {
    _ = c.FT_Done_Face(self.face);
    _ = c.FT_Done_FreeType(self.library);
    self.* = undefined;
}

/// Rasterize a single codepoint into the atlas. FreeType gives us an 8-bit
/// coverage bitmap, which the snapshot surface consumes through the BGRA atlas
/// alpha channel.
pub fn rasterizeGlyph(self: *FreeTypeFont, atlas: *Atlas, alloc: Allocator, codepoint: u32) !GlyphInfo {
    const flags = c.FT_LOAD_RENDER | c.FT_LOAD_TARGET_NORMAL;
    if (c.FT_Load_Char(self.face, codepoint, flags) != 0) return error.GlyphLoadFailed;

    const glyph = self.face.*.glyph;
    const bitmap = glyph.*.bitmap;
    const render_width: u32 = @intCast(bitmap.width);
    const render_height: u32 = @intCast(bitmap.rows);

    if (render_width == 0 or render_height == 0) {
        return .{
            .atlas_x = 0,
            .atlas_y = 0,
            .width = 0,
            .height = 0,
            .offset_x = @floatFromInt(glyph.*.bitmap_left),
            .offset_y = self.ascent - @as(f64, @floatFromInt(glyph.*.bitmap_top)),
            .is_color = false,
        };
    }

    const pad: u32 = 1;
    const padded_width = render_width + pad * 2;
    const padded_height = render_height + pad * 2;
    const region = try atlas.reserve(alloc, padded_width, padded_height);

    const bgra_size = @as(usize, render_width) * render_height * 4;
    const bgra_buf = try alloc.alloc(u8, bgra_size);
    defer alloc.free(bgra_buf);
    @memset(bgra_buf, 0);

    const pitch_abs: usize = @intCast(@abs(bitmap.pitch));
    const pitch_negative = bitmap.pitch < 0;

    for (0..render_height) |row| {
        const source_row = if (pitch_negative) render_height - 1 - row else row;
        const row_start = @as(usize, source_row) * pitch_abs;
        for (0..render_width) |col| {
            const alpha = bitmap.buffer[row_start + col];
            const off = (row * @as(usize, render_width) + col) * 4;
            bgra_buf[off + 0] = 255;
            bgra_buf[off + 1] = 255;
            bgra_buf[off + 2] = 255;
            bgra_buf[off + 3] = alpha;
        }
    }

    const glyph_region = Atlas.Region{
        .x = region.x + pad,
        .y = region.y + pad,
        .width = render_width,
        .height = render_height,
    };
    atlas.set(glyph_region, bgra_buf);

    return .{
        .atlas_x = glyph_region.x,
        .atlas_y = glyph_region.y,
        .width = render_width,
        .height = render_height,
        .offset_x = @floatFromInt(glyph.*.bitmap_left),
        .offset_y = self.ascent - @as(f64, @floatFromInt(glyph.*.bitmap_top)),
        .is_color = false,
    };
}

fn monospaceAdvance(face: c.FT_Face) !f64 {
    if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) != 0) return error.GlyphLoadFailed;
    return fixed26Dot6ToFloat(face.*.glyph.*.advance.x);
}

fn fixed26Dot6ToFloat(value: c.FT_Pos) f64 {
    return @as(f64, @floatFromInt(value)) / 64.0;
}

fn resolveFontPath(name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null and fileExists(name)) return name;

    const candidates = [_][]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
        "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    };

    for (candidates) |path| {
        if (fileExists(path)) return path;
    }

    return error.FontNotFound;
}

fn fileExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (path.len >= path_buf.len) return false;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    return c.access(&path_buf, c.F_OK) == 0;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "load fallback monospace font" {
    var font = try FreeTypeFont.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer font.deinit();

    try std.testing.expect(font.cell_width > 0);
    try std.testing.expect(font.cell_height > 0);
    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.descent >= 0);
}

test "rasterize ASCII A produces non-zero pixels" {
    var font = try FreeTypeFont.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer font.deinit();

    var atlas = try Atlas.init(std.testing.allocator, 256, .bgra);
    defer atlas.deinit(std.testing.allocator);

    const info = try font.rasterizeGlyph(&atlas, std.testing.allocator, 'A');
    try std.testing.expect(info.width > 0);
    try std.testing.expect(info.height > 0);

    const depth = atlas.format.depth();
    var has_nonzero = false;
    for (0..info.height) |row| {
        const start = ((info.atlas_y + @as(u32, @intCast(row))) * atlas.size + info.atlas_x) * depth;
        for (atlas.data[start..][0 .. info.width * depth]) |byte| {
            if (byte != 0) {
                has_nonzero = true;
                break;
            }
        }
        if (has_nonzero) break;
    }
    try std.testing.expect(has_nonzero);
}
