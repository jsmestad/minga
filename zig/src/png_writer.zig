/// Minimal PNG encoder using Zig's stdlib deflate compression.
///
/// Writes an unfiltered RGBA PNG from a raw pixel buffer. Sufficient for
/// snapshot-sized images where encoding speed is irrelevant.
const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Writes a PNG file for an RGBA pixel buffer to the given path.
pub fn writePng(alloc: Allocator, io: std.Io, path: []const u8, pixels: []const u8, width: u32, height: u32) !void {
    const file = try std.Io.Dir.createFile(.cwd(), io, path, .{});
    defer file.close(io);
    var file_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &file_buf);
    try writePngToWriter(alloc, &writer.interface, pixels, width, height);
    try writer.flush();
}

/// Writes a PNG to any std.Io.Writer (used by both file output and tests).
pub fn writePngToWriter(alloc: Allocator, writer: *std.Io.Writer, pixels: []const u8, width: u32, height: u32) !void {
    const row_bytes: usize = @as(usize, width) * 4;
    std.debug.assert(pixels.len == row_bytes * height);

    // PNG signature
    try writer.writeAll(&.{ 137, 80, 78, 71, 13, 10, 26, 10 });

    // IHDR chunk
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(writer, "IHDR", &ihdr);

    // Build raw (unfiltered) scanlines: each row gets a 0x00 filter byte prefix.
    const raw_len = height * (1 + row_bytes);
    const raw = try alloc.alloc(u8, raw_len);
    defer alloc.free(raw);

    for (0..height) |row| {
        const dst_offset = row * (1 + row_bytes);
        raw[dst_offset] = 0; // filter: none
        const src_start = row * row_bytes;
        @memcpy(raw[dst_offset + 1 ..][0..row_bytes], pixels[src_start..][0..row_bytes]);
    }

    // Compress with deflate (zlib container)
    const compressed = try compress(alloc, raw);
    defer alloc.free(compressed);

    // IDAT chunk
    try writeChunk(writer, "IDAT", compressed);

    // IEND chunk
    try writeChunk(writer, "IEND", &.{});
}

fn writeChunk(writer: *std.Io.Writer, chunk_type: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try writer.writeAll(&len_buf);
    try writer.writeAll(chunk_type);
    if (data.len > 0) try writer.writeAll(data);

    var hasher = std.hash.crc.Crc32IsoHdlc.init();
    hasher.update(chunk_type);
    if (data.len > 0) hasher.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, hasher.final(), .big);
    try writer.writeAll(&crc_buf);
}

fn compress(alloc: Allocator, input: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = try .initCapacity(alloc, @max(input.len / 2, 64));
    errdefer output.deinit();

    var window_buf: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(&output.writer, &window_buf, .zlib, flate.Compress.Options.level_6);
    try comp.writer.writeAll(input);
    try comp.finish();

    return output.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "writePng produces valid PNG signature" {
    const alloc = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    // 1x1 red pixel (RGBA)
    const pixels = [_]u8{ 255, 0, 0, 255 };
    try writePngToWriter(alloc, &output.writer, &pixels, 1, 1);

    const data = output.written();
    // PNG signature
    try std.testing.expectEqualSlices(u8, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }, data[0..8]);
    // IHDR chunk type
    try std.testing.expectEqualSlices(u8, "IHDR", data[12..16]);
}

test "writePng 2x2 image has correct IHDR dimensions" {
    const alloc = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    // 2x2 RGBA pixels
    var pixels: [2 * 2 * 4]u8 = undefined;
    @memset(&pixels, 128);
    try writePngToWriter(alloc, &output.writer, &pixels, 2, 2);

    const data = output.written();
    // IHDR data starts at byte 16 (8 sig + 4 len + 4 type)
    const w = std.mem.readInt(u32, data[16..20], .big);
    const h = std.mem.readInt(u32, data[20..24], .big);
    try std.testing.expectEqual(@as(u32, 2), w);
    try std.testing.expectEqual(@as(u32, 2), h);
}
