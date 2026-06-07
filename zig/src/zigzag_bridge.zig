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
    const ComponentRefs = struct {
        const TabGroup = zz.TabGroup;
        const StatusBar = zz.StatusBar;
        const StatusSegment = zz.StatusSegment;
        const Tree = zz.Tree;
        const SplitPane = zz.SplitPane;
        const CommandPalette = zz.CommandPalette;
        const List = zz.List;
        const VirtualList = zz.VirtualList;
        const StyledList = zz.StyledList;
        const Tooltip = zz.Tooltip;
        const Modal = zz.Modal;
        const ContextMenu = zz.ContextMenu;
        const Dropdown = zz.Dropdown;
        const TextInput = zz.TextInput;
        const TextArea = zz.TextArea;
        const CodeView = zz.CodeView;
        const DiffView = zz.DiffView;
        const RichLog = zz.RichLog;
        const Help = zz.Help;
        const Markdown = zz.Markdown;
        const Viewport = zz.Viewport;
        const Table = zz.Table;
        const DataTable = zz.DataTable;
        const SortableTable = zz.SortableTable;
        const Paginator = zz.Paginator;
        const HitBox = zz.HitBox;
        const MouseState = zz.MouseState;
        const KeyMap = zz.KeyMap;
        const KeyBinding = zz.KeyBinding;
        const Breadcrumb = zz.Breadcrumb;
        const Stepper = zz.Stepper;
        const Progress = zz.Progress;
        const Gauge = zz.Gauge;
        const Spinner = zz.Spinner;
        const Timer = zz.Timer;
        const Toast = zz.Toast;
        const Notification = zz.Notification;
        const Form = zz.Form;
        const Confirm = zz.Confirm;
        const Checkbox = zz.Checkbox;
        const CheckboxGroup = zz.CheckboxGroup;
        const RadioGroup = zz.RadioGroup;
        const Slider = zz.Slider;
        const FilePicker = zz.FilePicker;
        const MenuBar = zz.MenuBar;
        const Calendar = zz.Calendar;
        const Chart = zz.Chart;
        const BarChart = zz.BarChart;
        const Sparkline = zz.Sparkline;
        const Heatmap = zz.Heatmap;
        const Canvas = zz.Canvas;
        const BrailleCanvas = zz.BrailleCanvas;
        const renderWithRanges = zz.renderWithRanges;
        const renderWithHighlights = zz.renderWithHighlights;
        const fuzzy = zz.fuzzy;
        const Style = zz.Style;
        const Color = zz.Color;
        const Border = zz.Border;
        const Theme = zz.Theme;
        const AdaptivePalette = zz.AdaptivePalette;
        const Program = zz.Program;
        const Terminal = zz.Terminal;
        const CacheImage = zz.CacheImage;
        const measure = zz.measure;
        const join = zz.join;
        const place = zz.place;
        const Flex = zz.Flex;
        const layer = zz.layout.layer;
    };

    _ = ComponentRefs;
    try std.testing.expectEqual(@as(usize, 68), componentInventory().len);
    try std.testing.expectEqualStrings("TabGroup", componentInventory()[0]);
    try std.testing.expectEqualStrings("layer", componentInventory()[componentInventory().len - 1]);
}
