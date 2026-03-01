/// CoreText font loader — loads fonts and rasterizes glyphs on macOS.
///
/// Uses Apple's CoreText framework via @cImport to:
///   1. Load a named font (e.g. "Menlo") at a given size
///   2. Extract cell metrics (width, height, ascent, descent)
///   3. Rasterize individual glyphs into alpha bitmaps
///
/// This module only works on macOS (requires CoreText, CoreGraphics).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Atlas = @import("atlas.zig");

const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreText/CoreText.h");
});

const CoreTextFont = @This();

/// Opaque CoreText font reference. Must be released with CFRelease.
ct_font: c.CTFontRef,

/// Cell metrics in points (1x, for grid layout).
cell_width: u32,
cell_height: u32,
ascent: f64,
descent: f64,
leading: f64,

/// Backing scale factor for glyph rasterization (2.0 for Retina).
/// Bitmaps in the atlas are rasterized at this scale.
scale: f64,

/// Allocator for rasterization scratch buffers.
alloc: Allocator,

/// Glyph information stored after rasterization.
pub const GlyphInfo = struct {
    /// Region in the atlas where this glyph's bitmap lives.
    atlas_x: u32,
    atlas_y: u32,
    width: u32,
    height: u32,

    /// Bearing offsets for positioning (in point space, fractional).
    /// Stored as floats to preserve sub-pixel precision — truncating to
    /// integers causes per-glyph rounding errors that create visible
    /// vertical wobble when scaled for Retina rendering.
    offset_x: f64,
    offset_y: f64,
};

/// Load a font by name (e.g. "Menlo", "SF Mono") at the given point size.
/// Falls back to the system monospace font if the named font isn't found.
/// `scale` is the backing scale factor (2.0 for Retina) — glyph bitmaps
/// are rasterized at this multiple of the point size for crisp rendering.
pub fn init(alloc: Allocator, name: []const u8, size: f64, scale: f64) !CoreTextFont {
    const ct_font = try createFont(name, size);
    errdefer c.CFRelease(ct_font);

    // Compute cell metrics.
    const ascent = c.CTFontGetAscent(ct_font);
    const descent = c.CTFontGetDescent(ct_font);
    const leading = c.CTFontGetLeading(ct_font);

    // For monospace fonts, the advance of any glyph gives the cell width.
    // Use 'M' as a representative glyph.
    const cell_width_f = getMonospaceAdvance(ct_font);
    const cell_height_f = ascent + descent + leading;

    return .{
        .ct_font = ct_font,
        .cell_width = @intFromFloat(@ceil(cell_width_f)),
        .cell_height = @intFromFloat(@ceil(cell_height_f)),
        .ascent = ascent,
        .descent = descent,
        .leading = leading,
        .scale = scale,
        .alloc = alloc,
    };
}

pub fn deinit(self: *CoreTextFont) void {
    c.CFRelease(self.ct_font);
    self.* = undefined;
}

/// Rasterize a single codepoint into the atlas. Returns glyph info with
/// atlas coordinates and bearing offsets.
pub fn rasterizeGlyph(self: *CoreTextFont, atlas: *Atlas, alloc: Allocator, codepoint: u32) !GlyphInfo {
    // Convert codepoint to glyph ID via CoreText.
    var utf16_buf: [2]u16 = undefined;
    var glyph_buf: [2]c.CGGlyph = undefined;
    const utf16_len = unicodeToUtf16(codepoint, &utf16_buf);

    if (!c.CTFontGetGlyphsForCharacters(
        self.ct_font,
        &utf16_buf,
        &glyph_buf,
        @intCast(utf16_len),
    )) {
        // Glyph not found — use .notdef (0).
        glyph_buf[0] = 0;
    }
    const glyph_id = glyph_buf[0];

    // Get bounding rect for this glyph.
    var bounding_rect: c.CGRect = undefined;
    _ = c.CTFontGetBoundingRectsForGlyphs(
        self.ct_font,
        c.kCTFontOrientationDefault,
        &glyph_id,
        &bounding_rect,
        1,
    );

    // Calculate bitmap dimensions from bounding rect, scaled for Retina.
    // Bounding rect is in point space; multiply by scale to get pixel dimensions.
    const scale = self.scale;
    const bmp_width: u32 = @intFromFloat(@ceil(bounding_rect.size.width * scale));
    const bmp_height: u32 = @intFromFloat(@ceil(bounding_rect.size.height * scale));

    // For empty glyphs (space, etc.), use scaled cell dimensions.
    const scaled_cell_w: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(self.cell_width)) * scale));
    const scaled_cell_h: u32 = @intFromFloat(@ceil(@as(f64, @floatFromInt(self.cell_height)) * scale));
    const render_width = if (bmp_width == 0) scaled_cell_w else bmp_width;
    const render_height = if (bmp_height == 0) scaled_cell_h else bmp_height;

    // Reserve space in the atlas.
    const region = try atlas.reserve(alloc, render_width, render_height);

    // Rasterize into an RGBA temporary buffer. CoreText uses a superior
    // font rendering pipeline (LCD subpixel + smoothing) when drawing to
    // an RGBA context vs. grayscale.  We draw white-on-black, then extract
    // the green channel as our grayscale alpha value.
    const rgba_stride = @as(usize, render_width) * 4;
    const rgba_size = rgba_stride * render_height;
    const rgba_buf = try alloc.alloc(u8, rgba_size);
    defer alloc.free(rgba_buf);
    @memset(rgba_buf, 0);

    const color_space = c.CGColorSpaceCreateDeviceRGB();
    defer c.CGColorSpaceRelease(color_space);

    const ctx = c.CGBitmapContextCreate(
        rgba_buf.ptr,
        render_width,
        render_height,
        8, // bits per component
        @intCast(rgba_stride), // 4 bytes per pixel
        color_space,
        c.kCGImageAlphaPremultipliedLast, // RGBA
    ) orelse return error.BitmapContextFailed;
    defer c.CGContextRelease(ctx);

    // Scale the context so CoreText rasterizes at Retina resolution.
    c.CGContextScaleCTM(ctx, @floatCast(scale), @floatCast(scale));

    // Enable full font smoothing — CoreText renders significantly better
    // with LCD smoothing in an RGBA context.
    c.CGContextSetAllowsFontSmoothing(ctx, true);
    c.CGContextSetShouldSmoothFonts(ctx, true);
    c.CGContextSetShouldAntialias(ctx, true);
    c.CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    c.CGContextSetShouldSubpixelPositionFonts(ctx, true);
    c.CGContextSetAllowsFontSubpixelQuantization(ctx, true);
    c.CGContextSetShouldSubpixelQuantizeFonts(ctx, true);

    // White foreground on black background.
    c.CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, 1.0);

    // Position the glyph in point space (pre-scale). The CTM scale
    // transform converts these to pixel coordinates automatically.
    const draw_x: c.CGFloat = -bounding_rect.origin.x;
    const draw_y: c.CGFloat = -bounding_rect.origin.y;

    var position = c.CGPoint{ .x = draw_x, .y = draw_y };
    c.CTFontDrawGlyphs(self.ct_font, &glyph_id, &position, 1, ctx);

    // Extract grayscale from RGBA: take max(R,G,B) for maximum glyph
    // coverage across all subpixel channels, then apply gamma correction
    // to boost stroke weight to match native macOS text rendering.
    const buf_size = @as(usize, render_width) * render_height;
    const buf = try alloc.alloc(u8, buf_size);
    defer alloc.free(buf);

    const gamma: f32 = 0.7;
    for (0..render_height) |row| {
        for (0..render_width) |col| {
            const rgba_off = row * rgba_stride + col * 4;
            const gray_off = row * @as(usize, render_width) + col;
            // max(R,G,B) captures the best coverage from any channel.
            const r = rgba_buf[rgba_off];
            const g = rgba_buf[rgba_off + 1];
            const b = rgba_buf[rgba_off + 2];
            const v = @max(r, @max(g, b));
            if (v > 0) {
                const normalized: f32 = @as(f32, @floatFromInt(v)) / 255.0;
                const corrected: f32 = std.math.pow(f32, normalized, gamma);
                buf[gray_off] = @intFromFloat(@round(corrected * 255.0));
            } else {
                buf[gray_off] = 0;
            }
        }
    }

    // Write the rasterized data into the atlas.
    atlas.set(region, buf);

    return .{
        .atlas_x = region.x,
        .atlas_y = region.y,
        .width = render_width,
        .height = render_height,
        .offset_x = bounding_rect.origin.x,
        .offset_y = bounding_rect.origin.y + bounding_rect.size.height,
    };
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Create a CTFont from a name string. Falls back to system monospace.
fn createFont(name: []const u8, size: f64) !c.CTFontRef {
    // Create a CFString from the name.
    const cf_name = c.CFStringCreateWithBytes(
        null,
        name.ptr,
        @intCast(name.len),
        c.kCFStringEncodingUTF8,
        0,
    ) orelse return error.FontNameCreationFailed;
    defer c.CFRelease(cf_name);

    // Try creating the named font.
    const font = c.CTFontCreateWithName(cf_name, size, null);
    if (font != null) return font.?;

    // Fallback: system monospace font.
    const system_font = c.CTFontCreateUIFontForLanguage(
        c.kCTFontUIFontUserFixedPitch,
        size,
        null,
    );
    if (system_font != null) return system_font.?;

    return error.FontNotFound;
}

/// Get the monospace advance width for a font using the 'M' glyph.
fn getMonospaceAdvance(font: c.CTFontRef) f64 {
    var chars = [1]u16{'M'};
    var glyphs: [1]c.CGGlyph = undefined;
    _ = c.CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1);

    var advance: c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(
        font,
        c.kCTFontOrientationDefault,
        &glyphs,
        &advance,
        1,
    );

    return advance.width;
}

/// Convert a Unicode codepoint to UTF-16 (handling surrogate pairs).
/// Returns the number of u16 values written (1 or 2).
fn unicodeToUtf16(codepoint: u32, buf: *[2]u16) u8 {
    if (codepoint <= 0xFFFF) {
        buf[0] = @intCast(codepoint);
        return 1;
    }
    // Surrogate pair.
    const cp = codepoint - 0x10000;
    buf[0] = @intCast(0xD800 + (cp >> 10));
    buf[1] = @intCast(0xDC00 + (cp & 0x3FF));
    return 2;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "unicodeToUtf16 BMP codepoint" {
    var buf: [2]u16 = undefined;
    const len = unicodeToUtf16('A', &buf);
    try std.testing.expectEqual(@as(u8, 1), len);
    try std.testing.expectEqual(@as(u16, 'A'), buf[0]);
}

test "unicodeToUtf16 supplementary codepoint" {
    var buf: [2]u16 = undefined;
    const len = unicodeToUtf16(0x1F600, &buf); // 😀
    try std.testing.expectEqual(@as(u8, 2), len);
    try std.testing.expectEqual(@as(u16, 0xD83D), buf[0]);
    try std.testing.expectEqual(@as(u16, 0xDE00), buf[1]);
}

test "load Menlo font" {
    var font = try CoreTextFont.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer font.deinit();

    // Menlo at 14pt should have reasonable cell dimensions.
    try std.testing.expect(font.cell_width > 0);
    try std.testing.expect(font.cell_height > 0);
    try std.testing.expect(font.cell_width < 20);
    try std.testing.expect(font.cell_height < 30);
    try std.testing.expect(font.ascent > 0);
    try std.testing.expect(font.descent > 0);
}

test "load system fallback font" {
    // A nonsense name should fall back to system monospace.
    var font = try CoreTextFont.init(std.testing.allocator, "NonexistentFont12345", 14.0, 1.0);
    defer font.deinit();

    try std.testing.expect(font.cell_width > 0);
    try std.testing.expect(font.cell_height > 0);
}

test "rasterize ASCII 'A' produces non-zero pixels" {
    var font = try CoreTextFont.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer font.deinit();

    var atlas = try Atlas.init(std.testing.allocator, 256, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    const info = try font.rasterizeGlyph(&atlas, std.testing.allocator, 'A');

    // The glyph should have non-zero dimensions.
    try std.testing.expect(info.width > 0);
    try std.testing.expect(info.height > 0);

    // Check that at least one pixel in the atlas region is non-zero.
    var has_nonzero = false;
    for (0..info.height) |row| {
        const start = (info.atlas_y + @as(u32, @intCast(row))) * atlas.size + info.atlas_x;
        for (atlas.data[start..][0..info.width]) |pixel| {
            if (pixel != 0) {
                has_nonzero = true;
                break;
            }
        }
        if (has_nonzero) break;
    }
    try std.testing.expect(has_nonzero);
}

test "rasterize space glyph succeeds" {
    var font = try CoreTextFont.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer font.deinit();

    var atlas = try Atlas.init(std.testing.allocator, 256, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    // Space should rasterize without error (even if all pixels are zero).
    const info = try font.rasterizeGlyph(&atlas, std.testing.allocator, ' ');
    try std.testing.expect(info.width > 0);
    try std.testing.expect(info.height > 0);
}

test "rasterize all printable ASCII" {
    var font = try CoreTextFont.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer font.deinit();

    var atlas = try Atlas.init(std.testing.allocator, 512, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    // Rasterize 0x20..0x7E (all printable ASCII).
    var cp: u32 = 0x20;
    while (cp <= 0x7E) : (cp += 1) {
        const info = try font.rasterizeGlyph(&atlas, std.testing.allocator, cp);
        try std.testing.expect(info.width > 0);
        try std.testing.expect(info.height > 0);
    }
}
