const std = @import("std");
const highlighter_mod = @import("highlighter.zig");
const protocol = @import("protocol.zig");

const line_count = 2000;
const iterations = 160;
const warmup_iterations = 20;

pub fn main() !void {
    const alloc = std.heap.smp_allocator;

    var source = try buildElixirSource(alloc);
    defer source.deinit(alloc);

    var hl = try highlighter_mod.Highlighter.init(alloc);
    defer hl.deinit();

    if (!hl.setLanguage("elixir")) return error.LanguageUnavailable;
    try hl.parse(source.items);

    for (0..warmup_iterations) |i| {
        const edit = try mutateOneLine(alloc, &source, i);
        try hl.parseIncremental(&.{edit}, source.items);
        var result = try hl.highlightWithInjections();
        result.deinit();
    }

    var parse_times = try alloc.alloc(f64, iterations);
    defer alloc.free(parse_times);
    var highlight_times = try alloc.alloc(f64, iterations);
    defer alloc.free(highlight_times);
    var total_times = try alloc.alloc(f64, iterations);
    defer alloc.free(total_times);
    var span_counts = try alloc.alloc(f64, iterations);
    defer alloc.free(span_counts);

    for (0..iterations) |i| {
        const edit = try mutateOneLine(alloc, &source, i + warmup_iterations);

        const start_ns = nanoTimestamp();
        try hl.parseIncremental(&.{edit}, source.items);
        const parse_ns = nanoTimestamp();

        var result = try hl.highlightWithInjections();
        const end_ns = nanoTimestamp();

        parse_times[i] = micros(parse_ns - start_ns);
        highlight_times[i] = micros(end_ns - parse_ns);
        total_times[i] = micros(end_ns - start_ns);
        span_counts[i] = @floatFromInt(result.spans.len);
        result.deinit();
    }

    printMetric("ts_update_highlight_us", percentile(total_times, 0.50));
    printMetric("ts_update_highlight_p95_us", percentile(total_times, 0.95));
    printMetric("ts_parse_us", percentile(parse_times, 0.50));
    printMetric("ts_highlight_us", percentile(highlight_times, 0.50));
    printMetric("ts_highlight_p95_us", percentile(highlight_times, 0.95));
    printMetric("ts_span_count", percentile(span_counts, 0.50));
    printMetric("ts_line_count", @as(f64, @floatFromInt(line_count)));
}

fn buildElixirSource(alloc: std.mem.Allocator) !std.ArrayListUnmanaged(u8) {
    var source = std.ArrayListUnmanaged(u8).empty;
    errdefer source.deinit(alloc);

    for (0..line_count) |i| {
        const line = try std.fmt.allocPrint(
            alloc,
            "def render_row_{d}(value), do: value |> Kernel.+({d}) |> Integer.to_string() # benchmark line {d}\n",
            .{ i, i, i },
        );
        defer alloc.free(line);
        try source.appendSlice(alloc, line);
    }

    return source;
}

fn mutateOneLine(alloc: std.mem.Allocator, source: *std.ArrayListUnmanaged(u8), iteration: usize) !protocol.EditDelta {
    const marker = "# benchmark line ";
    const found = std.mem.lastIndexOf(u8, source.items, marker) orelse return error.MarkerNotFound;
    const start = found + marker.len;
    var line_start = start;
    while (line_start > 0 and source.items[line_start - 1] != '\n') : (line_start -= 1) {}
    var end = start;
    while (end < source.items.len and source.items[end] != '\n') : (end += 1) {}

    var buf: [32]u8 = undefined;
    const replacement = try std.fmt.bufPrint(&buf, "{d}", .{iteration});
    const edit = protocol.EditDelta{
        .start_byte = @intCast(start),
        .old_end_byte = @intCast(end),
        .new_end_byte = @intCast(start + replacement.len),
        .start_row = line_count - 1,
        .start_col = @intCast(start - line_start),
        .old_end_row = line_count - 1,
        .old_end_col = @intCast(end - line_start),
        .new_end_row = line_count - 1,
        .new_end_col = @intCast(start - line_start + replacement.len),
        .inserted_text = replacement,
    };
    try source.replaceRange(alloc, start, end - start, replacement);
    return edit;
}

fn nanoTimestamp() u64 {
    const c = std.c;
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}

fn percentile(values: []f64, p: f64) f64 {
    std.mem.sortUnstable(f64, values, {}, std.sort.asc(f64));
    if (values.len == 0) return 0;
    const idx_float = @as(f64, @floatFromInt(values.len - 1)) * p;
    const idx: usize = @intFromFloat(idx_float);
    return values[@min(idx, values.len - 1)];
}

fn printMetric(name: []const u8, value: f64) void {
    std.debug.print("METRIC {s}={d:.2}\n", .{ name, value });
}
