/// ZigZag integration seam for the current Minga renderer.
///
/// This module intentionally links ZigZag into `minga-renderer` without changing runtime behavior. Later epic slices may adapt BEAM-owned semantic payloads into ZigZag component inputs here, but this file must not become a second renderer product path or an owner of durable editor state.
const std = @import("std");
const zz = @import("zigzag");

/// Exact ZigZag revision made available to the current renderer.
pub const revision = "v0.1.5 / 4286ed5a1f919c1ee19ef4831021a57d18322905";

/// Components and primitives verified against the vendored ZigZag revision.
pub const verified_component_names = [_][]const u8{
    "TabGroup",
    "StatusBar",
    "StatusSegment",
    "Tree",
    "SplitPane",
    "CommandPalette",
    "List",
    "VirtualList",
    "StyledList",
    "Tooltip",
    "Modal",
    "ContextMenu",
    "Dropdown",
    "TextInput",
    "TextArea",
    "CodeView",
    "DiffView",
    "RichLog",
    "Help",
    "Markdown",
    "Viewport",
    "Table",
    "DataTable",
    "SortableTable",
    "Paginator",
    "HitBox",
    "MouseState",
    "KeyMap",
    "KeyBinding",
    "Breadcrumb",
    "Stepper",
    "Progress",
    "Gauge",
    "Spinner",
    "Timer",
    "Toast",
    "Notification",
    "Form",
    "Confirm",
    "Checkbox",
    "CheckboxGroup",
    "RadioGroup",
    "Slider",
    "FilePicker",
    "MenuBar",
    "Calendar",
    "Chart",
    "BarChart",
    "Sparkline",
    "Heatmap",
    "Canvas",
    "BrailleCanvas",
    "renderWithRanges",
    "renderWithHighlights",
    "fuzzy",
    "Style",
    "Color",
    "Border",
    "Theme",
    "AdaptivePalette",
    "Program",
    "Terminal",
    "CacheImage",
    "measure",
    "join",
    "place",
    "Flex",
    "layer",
};

/// Returns the verified component inventory for PR evidence and tests.
pub fn componentInventory() []const []const u8 {
    return verified_component_names[0..];
}

test "ZigZag component inventory compiles in minga-renderer" {
    // Reference every export directly in the function body so a renamed or
    // missing ZigZag component fails compilation here. These must NOT live in a
    // nested struct: Zig analyzes container-level declarations lazily, so
    // `_ = SomeStruct` would resolve the type without ever checking the
    // `zz.X` references inside it, silently defeating this guard. A function-body
    // tuple is analyzed eagerly, so each `zz.X` is resolved when the tuple is built.
    const component_refs = .{
        zz.TabGroup,
        zz.StatusBar,
        zz.StatusSegment,
        zz.Tree,
        zz.SplitPane,
        zz.CommandPalette,
        zz.List,
        zz.components.VirtualList,
        zz.StyledList,
        zz.Tooltip,
        zz.Modal,
        zz.ContextMenu,
        zz.Dropdown,
        zz.TextInput,
        zz.TextArea,
        zz.components.CodeView,
        zz.components.DiffView,
        zz.RichLog,
        zz.components.Help,
        zz.Markdown,
        zz.Viewport,
        zz.Table,
        zz.DataTable,
        zz.components.SortableTable,
        zz.components.Paginator,
        zz.HitBox,
        zz.MouseState,
        zz.KeyMap,
        zz.KeyBinding,
        zz.Breadcrumb,
        zz.Stepper,
        zz.Progress,
        zz.Gauge,
        zz.Spinner,
        zz.components.Timer,
        zz.Toast,
        zz.Notification,
        zz.Form,
        zz.Confirm,
        zz.Checkbox,
        zz.CheckboxGroup,
        zz.RadioGroup,
        zz.Slider,
        zz.components.FilePicker,
        zz.MenuBar,
        zz.Calendar,
        zz.Chart,
        zz.BarChart,
        zz.Sparkline,
        zz.Heatmap,
        zz.Canvas,
        zz.BrailleCanvas,
        zz.renderWithRanges,
        zz.renderWithHighlights,
        zz.fuzzy,
        zz.Style,
        zz.Color,
        zz.Border,
        zz.Theme,
        zz.AdaptivePalette,
        zz.Program,
        zz.Terminal,
        zz.CacheImage,
        zz.measure,
        zz.join,
        zz.place,
        zz.Flex,
        zz.layout.layer,
    };

    // Building the tuple above is the real export check (a renamed/missing
    // component fails compilation here). Tie its length to the verified-name
    // list so the PR-evidence inventory cannot silently drift.
    try std.testing.expectEqual(component_refs.len, componentInventory().len);
    try std.testing.expectEqualStrings("TabGroup", componentInventory()[0]);
    try std.testing.expectEqualStrings("layer", componentInventory()[componentInventory().len - 1]);
}
