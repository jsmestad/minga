/// Atlas — texture atlas for packing glyph bitmaps.
///
/// A rectangle bin-packing implementation (shelf/skyline algorithm) that
/// allocates rectangular regions within a square texture. Used to pack
/// rasterized glyph bitmaps for GPU sampling.
///
/// Based on the approach described in "A Thousand Ways to Pack the Bin" by
/// Jukka Jylänki, simplified for the common case of similarly-sized glyphs.
///
/// The atlas stores single-channel (grayscale/alpha) data by default.
const std = @import("std");
const Allocator = std.mem.Allocator;

const Atlas = @This();

/// Raw texture data. Layout: row-major, `size * size * depth` bytes.
data: []u8,

/// Width and height of the atlas (always square).
size: u32,

/// Format of the stored pixel data.
format: Format,

/// Skyline nodes — tracks the top edge of allocated space.
nodes: std.ArrayListUnmanaged(Node),

/// Incremented on every modification (write/reserve). Consumers can
/// compare against a cached value to know when to re-upload to GPU.
modified: usize = 0,

/// Incremented on every resize. Distinct from `modified` because a
/// resize requires creating a new GPU texture, not just updating data.
resized: usize = 0,

pub const Format = enum(u2) {
    /// 1 byte per pixel — alpha/grayscale.
    grayscale,
    /// 4 bytes per pixel — BGRA.
    bgra,

    pub fn depth(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .bgra => 4,
        };
    }
};

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Error = error{
    AtlasFull,
};

/// Initialize an atlas with the given square size and pixel format.
pub fn init(alloc: Allocator, size: u32, format: Format) !Atlas {
    var result = Atlas{
        .data = try alloc.alloc(u8, @as(usize, size) * size * format.depth()),
        .size = size,
        .format = format,
        .nodes = .{},
    };
    errdefer result.deinit(alloc);

    result.nodes = try std.ArrayListUnmanaged(Node).initCapacity(alloc, 64);
    result.clear();

    return result;
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    self.* = undefined;
}

/// Reset the atlas to empty (all zeroes, single spanning node).
pub fn clear(self: *Atlas) void {
    @memset(self.data, 0);
    self.nodes.clearRetainingCapacity();
    self.nodes.appendAssumeCapacity(.{ .x = 0, .y = 0, .width = self.size });
    self.modified +%= 1;
}

/// Reserve a region of `width × height` pixels in the atlas.
/// Returns the top-left corner coordinates.
pub fn reserve(self: *Atlas, alloc: Allocator, width: u32, height: u32) (Allocator.Error || Error)!Region {
    if (width == 0 and height == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    var region = Region{ .x = 0, .y = 0, .width = width, .height = height };

    // Find best-fit node (lowest y, then narrowest).
    const best_idx: usize = best: {
        var best_h: u32 = std.math.maxInt(u32);
        var best_w: u32 = best_h;
        var chosen: ?usize = null;

        for (self.nodes.items, 0..) |_, i| {
            const y = self.fit(i, width, height) orelse continue;
            const node = self.nodes.items[i];
            if ((y + height) < best_h or
                ((y + height) == best_h and node.width > 0 and node.width < best_w))
            {
                chosen = i;
                best_w = node.width;
                best_h = y + height;
                region.x = node.x;
                region.y = y;
            }
        }
        break :best chosen orelse return Error.AtlasFull;
    };

    // Insert new skyline node.
    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });

    // Shrink/remove overlapping nodes to the right.
    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < prev.x + prev.width) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -|= shrink;
            if (node.width == 0) {
                _ = self.nodes.orderedRemove(i);
                continue;
            }
        }
        i += 1;
    }

    // Merge adjacent nodes at the same y.
    self.merge();
    self.modified +%= 1;

    return region;
}

/// Write pixel data into a previously reserved region.
pub fn set(self: *Atlas, region: Region, source: []const u8) void {
    const d = self.format.depth();
    std.debug.assert(source.len == @as(usize, region.width) * region.height * d);

    const atlas_stride = @as(usize, self.size) * d;

    for (0..region.height) |row| {
        const src_start = row * @as(usize, region.width) * d;
        const dst_start = (@as(usize, region.y) + row) * atlas_stride + @as(usize, region.x) * d;

        @memcpy(
            self.data[dst_start..][0 .. @as(usize, region.width) * d],
            source[src_start..][0 .. @as(usize, region.width) * d],
        );
    }

    self.modified +%= 1;
}

/// Grow the atlas to `new_size` (must be > current size). Copies existing data.
pub fn grow(self: *Atlas, alloc: Allocator, new_size: u32) !void {
    std.debug.assert(new_size > self.size);
    const d = self.format.depth();
    const new_data = try alloc.alloc(u8, @as(usize, new_size) * new_size * d);
    @memset(new_data, 0);

    // Copy existing rows.
    const old_stride = @as(usize, self.size) * d;
    const new_stride = @as(usize, new_size) * d;
    for (0..self.size) |row| {
        @memcpy(
            new_data[row * new_stride ..][0..old_stride],
            self.data[row * old_stride ..][0..old_stride],
        );
    }

    alloc.free(self.data);
    self.data = new_data;
    self.size = new_size;

    // Add a node spanning the new right edge.
    self.nodes.appendAssumeCapacity(.{
        .x = self.size,
        .y = 0,
        .width = new_size - self.size,
    });

    self.resized +%= 1;
    self.modified +%= 1;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

/// Check if a region of `width × height` fits at node `idx`.
/// Returns the y-coordinate it would sit at, or null if it doesn't fit.
fn fit(self: *const Atlas, idx: usize, width: u32, height: u32) ?u32 {
    var node = self.nodes.items[idx];
    if (node.x + width > self.size) return null;

    var y = node.y;
    var remaining_width: i64 = @intCast(width);
    var i = idx;

    while (remaining_width > 0) {
        if (i >= self.nodes.items.len) return null;
        node = self.nodes.items[i];
        y = @max(y, node.y);
        if (y + height > self.size) return null;
        remaining_width -= @as(i64, @intCast(node.width));
        i += 1;
    }

    return y;
}

/// Merge adjacent nodes that share the same y.
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i + 1 < self.nodes.items.len) {
        const a = &self.nodes.items[i];
        const b = self.nodes.items[i + 1];
        if (a.y == b.y) {
            a.width += b.width;
            _ = self.nodes.orderedRemove(i + 1);
        } else {
            i += 1;
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "init creates zeroed atlas" {
    var atlas = try Atlas.init(std.testing.allocator, 64, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 64), atlas.size);
    try std.testing.expectEqual(@as(usize, 64 * 64), atlas.data.len);
    for (atlas.data) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "reserve returns valid region" {
    var atlas = try Atlas.init(std.testing.allocator, 64, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    const r = try atlas.reserve(std.testing.allocator, 8, 16);
    try std.testing.expectEqual(@as(u32, 0), r.x);
    try std.testing.expectEqual(@as(u32, 0), r.y);
    try std.testing.expectEqual(@as(u32, 8), r.width);
    try std.testing.expectEqual(@as(u32, 16), r.height);
}

test "reserve multiple regions don't overlap" {
    var atlas = try Atlas.init(std.testing.allocator, 64, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    const r1 = try atlas.reserve(std.testing.allocator, 10, 10);
    const r2 = try atlas.reserve(std.testing.allocator, 10, 10);

    // They should not overlap.
    const r1_right = r1.x + r1.width;
    const r2_right = r2.x + r2.width;
    const r1_bottom = r1.y + r1.height;
    const r2_bottom = r2.y + r2.height;

    const no_overlap = r1_right <= r2.x or r2_right <= r1.x or
        r1_bottom <= r2.y or r2_bottom <= r1.y;
    try std.testing.expect(no_overlap);
}

test "reserve returns AtlasFull when exhausted" {
    var atlas = try Atlas.init(std.testing.allocator, 4, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    // 4×4 atlas can fit one 4×4 region.
    _ = try atlas.reserve(std.testing.allocator, 4, 4);
    const result = atlas.reserve(std.testing.allocator, 1, 1);
    try std.testing.expectError(Error.AtlasFull, result);
}

test "set writes data correctly" {
    var atlas = try Atlas.init(std.testing.allocator, 8, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    const r = try atlas.reserve(std.testing.allocator, 2, 2);
    const pixel_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    atlas.set(r, &pixel_data);

    // Check first row.
    try std.testing.expectEqual(@as(u8, 0xAA), atlas.data[r.y * 8 + r.x]);
    try std.testing.expectEqual(@as(u8, 0xBB), atlas.data[r.y * 8 + r.x + 1]);
    // Second row.
    try std.testing.expectEqual(@as(u8, 0xCC), atlas.data[(r.y + 1) * 8 + r.x]);
    try std.testing.expectEqual(@as(u8, 0xDD), atlas.data[(r.y + 1) * 8 + r.x + 1]);
}

test "clear resets atlas" {
    var atlas = try Atlas.init(std.testing.allocator, 8, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    _ = try atlas.reserve(std.testing.allocator, 4, 4);
    atlas.clear();

    // Should be able to reserve the full space again.
    _ = try atlas.reserve(std.testing.allocator, 8, 8);
}

test "modified counter increments" {
    var atlas = try Atlas.init(std.testing.allocator, 8, .grayscale);
    defer atlas.deinit(std.testing.allocator);

    const m0 = atlas.modified;
    _ = try atlas.reserve(std.testing.allocator, 2, 2);
    try std.testing.expect(atlas.modified > m0);
}

test "Format depth returns correct values" {
    try std.testing.expectEqual(@as(u8, 1), Format.grayscale.depth());
    try std.testing.expectEqual(@as(u8, 4), Format.bgra.depth());
}
