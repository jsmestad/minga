/// Font — top-level font module providing glyph caching and atlas management.
///
/// Wraps the platform-specific font loader (CoreText on macOS) and the
/// texture atlas, adding a glyph cache that maps codepoints → GlyphInfo.
/// New glyphs are rasterized on demand when first requested.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Atlas = @import("atlas.zig");
pub const CoreTextFont = if (builtin.os.tag == .macos) @import("coretext.zig") else struct {};

/// Glyph cache entry with atlas coordinates and metrics.
pub const Glyph = struct {
    /// Top-left corner in the atlas texture.
    atlas_x: u32,
    atlas_y: u32,
    /// Glyph bitmap dimensions in pixels.
    width: u32,
    height: u32,
    /// Bearing offsets for positioning relative to the baseline.
    /// Bearing offsets in point space (fractional precision preserved).
    offset_x: f64,
    offset_y: f64,
};

/// Font face with glyph cache. Thread-safe for concurrent lookups
/// (cache is populated lazily with a mutex).
pub const Face = struct {
    loader: CoreTextFont,
    atlas: Atlas,
    cache: std.AutoHashMapUnmanaged(u32, Glyph),
    alloc: Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Cell dimensions in pixels — use these for grid layout.
    cell_width: u32,
    cell_height: u32,

    /// Initialize a font face. Loads the named font and creates an atlas.
    /// `scale` is the backing scale factor (2.0 for Retina) — glyph bitmaps
    /// are rasterized at this multiple for crisp rendering on HiDPI displays.
    pub fn init(alloc: Allocator, name: []const u8, size: f64, scale: f64) !Face {
        var loader = try CoreTextFont.init(alloc, name, size, scale);
        errdefer loader.deinit();

        // Start with a 512×512 atlas (enough for ~500 glyphs at 14pt).
        var atlas = try Atlas.init(alloc, 512, .grayscale);
        errdefer atlas.deinit(alloc);

        return .{
            .loader = loader,
            .atlas = atlas,
            .cache = .{},
            .alloc = alloc,
            .cell_width = loader.cell_width,
            .cell_height = loader.cell_height,
        };
    }

    pub fn deinit(self: *Face) void {
        self.cache.deinit(self.alloc);
        self.atlas.deinit(self.alloc);
        self.loader.deinit();
    }

    /// Look up a glyph by codepoint. Rasterizes on first access.
    pub fn getGlyph(self: *Face, codepoint: u32) !Glyph {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cache.get(codepoint)) |g| return g;

        // Rasterize and cache.
        const info = self.loader.rasterizeGlyph(&self.atlas, self.alloc, codepoint) catch |err| {
            if (err == Atlas.Error.AtlasFull) {
                // Double the atlas size and retry.
                try self.atlas.grow(self.alloc, self.atlas.size * 2);
                const retry_info = try self.loader.rasterizeGlyph(&self.atlas, self.alloc, codepoint);
                const retry_glyph = glyphFromInfo(retry_info);
                try self.cache.put(self.alloc, codepoint, retry_glyph);
                return retry_glyph;
            }
            return err;
        };

        const glyph = glyphFromInfo(info);
        try self.cache.put(self.alloc, codepoint, glyph);
        return glyph;
    }

    fn glyphFromInfo(info: CoreTextFont.GlyphInfo) Glyph {
        return .{
            .atlas_x = info.atlas_x,
            .atlas_y = info.atlas_y,
            .width = info.width,
            .height = info.height,
            .offset_x = info.offset_x,
            .offset_y = info.offset_y,
        };
    }

    /// Pre-rasterize all printable ASCII glyphs (0x20..0x7E).
    /// Call this at startup to avoid rasterization hitches during rendering.
    pub fn preloadAscii(self: *Face) !void {
        var cp: u32 = 0x20;
        while (cp <= 0x7E) : (cp += 1) {
            _ = try self.getGlyph(cp);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Face init and deinit" {
    var face = try Face.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer face.deinit();

    try std.testing.expect(face.cell_width > 0);
    try std.testing.expect(face.cell_height > 0);
}

test "Face getGlyph returns consistent results" {
    var face = try Face.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer face.deinit();

    const g1 = try face.getGlyph('A');
    const g2 = try face.getGlyph('A');

    // Same glyph should return same atlas coordinates.
    try std.testing.expectEqual(g1.atlas_x, g2.atlas_x);
    try std.testing.expectEqual(g1.atlas_y, g2.atlas_y);
}

test "Face preloadAscii succeeds" {
    var face = try Face.init(std.testing.allocator, "Menlo", 14.0, 1.0);
    defer face.deinit();

    try face.preloadAscii();

    // All ASCII should now be cached.
    try std.testing.expect(face.cache.count() >= 95); // 0x7E - 0x20 + 1
}

test {
    _ = Atlas;
    if (builtin.os.tag == .macos) {
        _ = CoreTextFont;
    }
}
