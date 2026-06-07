/// ZigZag-backed local hitbox helpers for semantic renderer mouse routing.
///
/// These helpers deliberately translate terminal coordinates to existing semantic hit actions only. They do not own commands, editor state, or protocol meaning.
const std = @import("std");
const zz = @import("zigzag");

/// A terminal-space rectangle represented through ZigZag's HitBox primitive.
pub const Rect = struct {
    row: u16,
    col: u16,
    width: u16,
    height: u16,

    /// Builds the equivalent ZigZag hitbox, whose coordinates are x/y rather than row/col.
    pub fn asHitBox(self: Rect) zz.HitBox {
        return zz.HitBox.init(self.col, self.row, self.width, self.height);
    }

    /// Returns true when the terminal point lands inside this rectangle.
    pub fn contains(self: Rect, row: u16, col: u16) bool {
        return self.asHitBox().containsPoint(col, row);
    }

    /// Returns local row/col coordinates inside this rectangle.
    pub fn local(self: Rect, row: u16, col: u16) ?struct { row: u16, col: u16 } {
        if (!self.contains(row, col)) return null;
        return .{ .row = row - self.row, .col = col - self.col };
    }
};

/// Convenience constructor for terminal-space hitboxes.
pub fn rect(row: u16, col: u16, width: u16, height: u16) Rect {
    return .{ .row = row, .col = col, .width = width, .height = height };
}

/// Tracks local interaction state with ZigZag MouseState while keeping callers in terminal row/col terms.
pub fn updateMouseState(state: *zz.MouseState, box: Rect, row: u16, col: u16, button: zz.MouseButton, event_type: zz.MouseEventType) zz.MouseInteraction {
    const event = zz.MouseEvent{
        .x = col,
        .y = row,
        .button = button,
        .event_type = event_type,
        .modifiers = .{},
    };
    return state.update(box.asHitBox(), event);
}

test "semantic hitbox maps terminal row col through ZigZag HitBox" {
    const box = rect(3, 7, 10, 4);
    try std.testing.expect(box.contains(3, 7));
    try std.testing.expect(box.contains(6, 16));
    try std.testing.expect(!box.contains(7, 16));
    try std.testing.expect(!box.contains(6, 17));

    const local = box.local(5, 11) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 2), local.row);
    try std.testing.expectEqual(@as(u16, 4), local.col);
}

test "semantic hitbox tracks mouse state without owning behavior" {
    const box = rect(1, 2, 8, 3);
    var state = zz.MouseState{};
    const press = updateMouseState(&state, box, 2, 3, .left, .press);
    try std.testing.expectEqual(zz.MouseInteraction.press, press);
    try std.testing.expect(state.hover);
    try std.testing.expect(state.pressed);
}
