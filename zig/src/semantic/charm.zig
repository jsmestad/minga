const vaxis = @import("vaxis");

pub fn writeText(
    surface: anytype,
    row: u16,
    start_col: u16,
    max_width: u16,
    text: []const u8,
    fg: u24,
    bg: u24,
    attrs: u8,
) u16 {
    var col = start_col;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (col >= max_width) break;
        const raw = grapheme.bytes(text);
        const width: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
        const cell_width: u16 = if (width == 0) 1 else width;
        surface.writeCell(col, row, .{
            .grapheme = raw,
            .width = @intCast(cell_width),
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
        });
        col +|= cell_width;
    }
    return col;
}

pub fn textWidth(text: []const u8) u16 {
    var total: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const raw = grapheme.bytes(text);
        const width: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
        total +|= if (width == 0) 1 else width;
    }
    return total;
}

pub fn writeAsciiText(surface: anytype, row: u16, start_col: u16, max_width: u16, text: []const u8, fg: u24, bg: u24, attrs: u8) void {
    var col = start_col;
    for (text) |byte| {
        if (col >= max_width) break;
        surface.writeCell(col, row, .{
            .grapheme = asciiGrapheme(byte),
            .width = 1,
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
        });
        col += 1;
    }
}

pub fn writeAsciiStableText(surface: anytype, row: u16, start_col: u16, max_width: u16, text: []const u8, fg: u24, bg: u24, attrs: u8) u16 {
    var col = start_col;
    for (text) |byte| {
        if (col >= max_width) break;
        surface.writeCell(col, row, .{
            .grapheme = asciiGrapheme(byte),
            .width = 1,
            .fg = fg,
            .bg = bg,
            .attrs = attrs,
        });
        col += 1;
    }
    return col;
}

pub fn asciiGrapheme(byte: u8) []const u8 {
    return switch (byte) {
        ' ' => " ",
        '!' => "!",
        '/' => "/",
        '+' => "+",
        '-' => "-",
        ':' => ":",
        '0' => "0",
        '1' => "1",
        '2' => "2",
        '3' => "3",
        '4' => "4",
        '5' => "5",
        '6' => "6",
        '7' => "7",
        '8' => "8",
        '9' => "9",
        'A' => "A",
        'B' => "B",
        'C' => "C",
        'D' => "D",
        'E' => "E",
        'F' => "F",
        'G' => "G",
        'H' => "H",
        'I' => "I",
        'J' => "J",
        'K' => "K",
        'L' => "L",
        'M' => "M",
        'N' => "N",
        'O' => "O",
        'P' => "P",
        'Q' => "Q",
        'R' => "R",
        'S' => "S",
        'T' => "T",
        'U' => "U",
        'V' => "V",
        'W' => "W",
        'X' => "X",
        'Y' => "Y",
        'Z' => "Z",
        'a' => "a",
        'b' => "b",
        'c' => "c",
        'd' => "d",
        'e' => "e",
        'f' => "f",
        'g' => "g",
        'h' => "h",
        'i' => "i",
        'j' => "j",
        'k' => "k",
        'l' => "l",
        'm' => "m",
        'n' => "n",
        'o' => "o",
        'p' => "p",
        'q' => "q",
        'r' => "r",
        's' => "s",
        't' => "t",
        'u' => "u",
        'v' => "v",
        'w' => "w",
        'x' => "x",
        'y' => "y",
        'z' => "z",
        else => "?",
    };
}

pub fn clearRow(surface: anytype, row: u16, width: u16) void {
    clearRowRange(surface, row, 0, width);
}

pub fn clearRowRange(surface: anytype, row: u16, start_col: u16, end_col: u16) void {
    var col: u16 = 0;
    col = start_col;
    while (col < end_col) : (col += 1) {
        surface.writeCell(col, row, .{ .grapheme = " ", .width = 1, .fg = 0, .bg = 0, .attrs = 0 });
    }
}

pub fn fillRowRangeWith(surface: anytype, screen_row: u16, start_col: u16, end_col: u16, row_bg: u24) void {
    var col = start_col;
    while (col < end_col) : (col += 1) {
        surface.writeCell(col, screen_row, .{
            .grapheme = " ",
            .width = 1,
            .fg = 0,
            .bg = row_bg,
            .attrs = 0,
        });
    }
}
