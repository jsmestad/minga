/// ZigZag integration seam for the current Minga renderer.
///
/// This module intentionally links ZigZag into `minga-renderer` without changing runtime behavior. Later epic slices may adapt BEAM-owned semantic payloads into ZigZag component inputs here, but this file must not become a second renderer product path or an owner of durable editor state.
const std = @import("std");
const zz = @import("zigzag");

/// Exact ZigZag revision made available to the current renderer.
pub const revision = "v0.1.5 / 4286ed5a1f919c1ee19ef4831021a57d18322905";

/// Components and primitives verified against the vendored ZigZag revision.
///
/// Single source of truth: each entry pairs an inventory name with the real
/// ZigZag export it refers to. Building this tuple resolves every `zz.X` at
/// compile time, so a renamed or missing component fails `zig build test`; the
/// name list is derived from the same entries, so the documented inventory and
/// the verified refs cannot drift. Eight components are not re-exported at the
/// top level and are reached through `zz.components.*`.
const verified_components = .{
    .{ "TabGroup", zz.TabGroup },
    .{ "StatusBar", zz.StatusBar },
    .{ "StatusSegment", zz.StatusSegment },
    .{ "Tree", zz.Tree },
    .{ "SplitPane", zz.SplitPane },
    .{ "CommandPalette", zz.CommandPalette },
    .{ "List", zz.List },
    .{ "VirtualList", zz.components.VirtualList },
    .{ "StyledList", zz.StyledList },
    .{ "Tooltip", zz.Tooltip },
    .{ "Modal", zz.Modal },
    .{ "ContextMenu", zz.ContextMenu },
    .{ "Dropdown", zz.Dropdown },
    .{ "TextInput", zz.TextInput },
    .{ "TextArea", zz.TextArea },
    .{ "CodeView", zz.components.CodeView },
    .{ "DiffView", zz.components.DiffView },
    .{ "RichLog", zz.RichLog },
    .{ "Help", zz.components.Help },
    .{ "Markdown", zz.Markdown },
    .{ "Viewport", zz.Viewport },
    .{ "Table", zz.Table },
    .{ "DataTable", zz.DataTable },
    .{ "SortableTable", zz.components.SortableTable },
    .{ "Paginator", zz.components.Paginator },
    .{ "HitBox", zz.HitBox },
    .{ "MouseState", zz.MouseState },
    .{ "KeyMap", zz.KeyMap },
    .{ "KeyBinding", zz.KeyBinding },
    .{ "Breadcrumb", zz.Breadcrumb },
    .{ "Stepper", zz.Stepper },
    .{ "Progress", zz.Progress },
    .{ "Gauge", zz.Gauge },
    .{ "Spinner", zz.Spinner },
    .{ "Timer", zz.components.Timer },
    .{ "Toast", zz.Toast },
    .{ "Notification", zz.Notification },
    .{ "Form", zz.Form },
    .{ "Confirm", zz.Confirm },
    .{ "Checkbox", zz.Checkbox },
    .{ "CheckboxGroup", zz.CheckboxGroup },
    .{ "RadioGroup", zz.RadioGroup },
    .{ "Slider", zz.Slider },
    .{ "FilePicker", zz.components.FilePicker },
    .{ "MenuBar", zz.MenuBar },
    .{ "Calendar", zz.Calendar },
    .{ "Chart", zz.Chart },
    .{ "BarChart", zz.BarChart },
    .{ "Sparkline", zz.Sparkline },
    .{ "Heatmap", zz.Heatmap },
    .{ "Canvas", zz.Canvas },
    .{ "BrailleCanvas", zz.BrailleCanvas },
    .{ "renderWithRanges", zz.renderWithRanges },
    .{ "renderWithHighlights", zz.renderWithHighlights },
    .{ "fuzzy", zz.fuzzy },
    .{ "Style", zz.Style },
    .{ "Color", zz.Color },
    .{ "Border", zz.Border },
    .{ "Theme", zz.Theme },
    .{ "AdaptivePalette", zz.AdaptivePalette },
    .{ "Program", zz.Program },
    .{ "Terminal", zz.Terminal },
    .{ "CacheImage", zz.CacheImage },
    .{ "measure", zz.measure },
    .{ "join", zz.join },
    .{ "place", zz.place },
    .{ "Flex", zz.Flex },
    .{ "layer", zz.layout.layer },
};

/// Inventory names, derived from `verified_components` so they cannot drift.
pub const verified_component_names = blk: {
    var names: [verified_components.len][]const u8 = undefined;
    for (verified_components, 0..) |entry, i| names[i] = entry[0];
    break :blk names;
};

/// Returns the verified component inventory for PR evidence and tests.
pub fn componentInventory() []const []const u8 {
    return &verified_component_names;
}

test "ZigZag component inventory compiles in minga-renderer" {
    // componentInventory() is built from `verified_components`, so calling it
    // forces every paired `zz.X` ref to resolve: a renamed or missing ZigZag
    // export fails compilation here.
    try std.testing.expectEqual(verified_components.len, componentInventory().len);
    try std.testing.expectEqualStrings("TabGroup", componentInventory()[0]);
    try std.testing.expectEqualStrings("layer", componentInventory()[componentInventory().len - 1]);
}
