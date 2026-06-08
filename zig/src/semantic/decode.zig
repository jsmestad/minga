const std = @import("std");
const protocol = @import("../protocol.zig");
const types = @import("types.zig");

const Error = types.Error;
const StatusSegment = types.StatusSegment;
const Tab = types.Tab;
const TabBar = types.TabBar;
const MinibufferCandidate = types.MinibufferCandidate;
const Minibuffer = types.Minibuffer;
const WhichKeyBinding = types.WhichKeyBinding;
const WhichKey = types.WhichKey;
const CompletionItem = types.CompletionItem;
const Completion = types.Completion;
const Breadcrumb = types.Breadcrumb;
const PickerItem = types.PickerItem;
const Picker = types.Picker;
const PreviewSegment = types.PreviewSegment;
const PreviewLine = types.PreviewLine;
const PickerPreview = types.PickerPreview;
const HoverSegment = types.HoverSegment;
const HoverLine = types.HoverLine;
const HoverPopup = types.HoverPopup;
const SignatureParameter = types.SignatureParameter;
const Signature = types.Signature;
const SignatureHelp = types.SignatureHelp;
const FloatPopup = types.FloatPopup;
const GitStatusEntry = types.GitStatusEntry;
const GitToast = types.GitToast;
const GitStatus = types.GitStatus;
const BottomPanelTab = types.BottomPanelTab;
const BottomPanelEntry = types.BottomPanelEntry;
const BottomPanel = types.BottomPanel;
const VerticalSeparator = types.VerticalSeparator;
const HorizontalSeparator = types.HorizontalSeparator;
const SplitSeparators = types.SplitSeparators;
const WindowSpan = types.WindowSpan;
const WindowRow = types.WindowRow;
const WindowRowsDelta = types.WindowRowsDelta;
const WindowSelection = types.WindowSelection;
const SearchMatch = types.SearchMatch;
const DiagnosticRange = types.DiagnosticRange;
const DocumentHighlight = types.DocumentHighlight;
const LineAnnotation = types.LineAnnotation;
const WindowOverlayDelta = types.WindowOverlayDelta;
const FileTreeRow = types.FileTreeRow;
const FileTree = types.FileTree;
const FileTreeSelection = types.FileTreeSelection;
const Sidebar = types.Sidebar;
const Sidebars = types.Sidebars;
const GutterEntry = types.GutterEntry;
const Gutter = types.Gutter;
const IndentGuides = types.IndentGuides;
const ThemeSlot = types.ThemeSlot;
const Theme = types.Theme;
const Workspace = types.Workspace;
const WorkspaceTab = types.WorkspaceTab;
const Workspaces = types.Workspaces;
const SearchState = types.SearchState;
const ChangeSummaryEntry = types.ChangeSummaryEntry;
const ChangeSummary = types.ChangeSummary;
const NotificationAction = types.NotificationAction;
const NotificationItem = types.NotificationItem;
const Notifications = types.Notifications;
const TimelineEntry = types.TimelineEntry;
const EditTimeline = types.EditTimeline;
const ExtensionOverlay = types.ExtensionOverlay;
const ExtensionOverlayEntry = types.ExtensionOverlayEntry;
const ExtensionPanel = types.ExtensionPanel;
const ExtensionPanelEntry = types.ExtensionPanelEntry;
const Observatory = types.Observatory;
const ObservatoryNode = types.ObservatoryNode;
const AgentContext = types.AgentContext;
const ToolSummary = types.ToolSummary;
const ToolManager = types.ToolManager;
const Cursorline = types.Cursorline;
const GutterSeparator = types.GutterSeparator;
const LineSpacing = types.LineSpacing;
const CursorAnimation = types.CursorAnimation;
const ConfigState = types.ConfigState;
const HoverAction = types.HoverAction;
const BoardCard = types.BoardCard;
const Board = types.Board;
const AgentChat = types.AgentChat;
const AgentChatMessage = types.AgentChatMessage;
const WindowContent = types.WindowContent;
const StatusBar = types.StatusBar;

/// Decodes a `gui_tab_bar` packet into owned tab state.
pub fn decodeTabBar(alloc: std.mem.Allocator, packet: []const u8) Error!TabBar {
    if (packet.len < 3 or packet[0] != protocol.OP_GUI_TAB_BAR) return error.Malformed;

    var tabs = TabBar{
        .active_index = packet[1],
        .tabs = try alloc.alloc(Tab, packet[2]),
    };
    @memset(tabs.tabs, .{});
    errdefer tabs.deinit(alloc);

    var offset: usize = 3;
    var index: usize = 0;
    errdefer {
        for (tabs.tabs[0..index]) |*tab| tab.deinit(alloc);
    }

    while (index < tabs.tabs.len) : (index += 1) {
        tabs.tabs[index] = try decodeTab(alloc, packet, &offset);
    }

    return tabs;
}

fn decodeTab(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!Tab {
    if (packet.len < offset.* + 8) return error.Malformed;
    const flags = packet[offset.*];
    offset.* += 1;
    const id = readU32(packet[offset.* .. offset.* + 4]);
    offset.* += 4;
    const group_id = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    const icon = try readString8(packet, offset);
    const label = try readString16(packet, offset);
    if (packet.len < offset.* + 4) return error.Malformed;
    const tint = readU32(packet[offset.* .. offset.* + 4]);
    offset.* += 4;

    return .{
        .id = id,
        .group_id = group_id,
        .flags = flags,
        .icon = try alloc.dupe(u8, icon),
        .label = try alloc.dupe(u8, label),
        .tint = tint,
    };
}

/// Decodes a `gui_minibuffer` packet into owned minibuffer state.
pub fn decodeMinibuffer(alloc: std.mem.Allocator, packet: []const u8) Error!Minibuffer {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_MINIBUFFER) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 8) return error.Malformed;

    var offset: usize = 2;
    const mode = packet[offset];
    offset += 1;
    const cursor_pos = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const prompt = try readString8(packet, &offset);
    const input = try readString16(packet, &offset);
    const context = try readString16(packet, &offset);
    if (packet.len < offset + 6) return error.Malformed;
    const selected_index = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const candidate_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const total_candidates = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;

    var minibuffer = Minibuffer{
        .visible = true,
        .mode = mode,
        .cursor_pos = cursor_pos,
        .selected_index = selected_index,
        .total_candidates = total_candidates,
    };
    errdefer minibuffer.deinit(alloc);

    minibuffer.prompt = try alloc.dupe(u8, prompt);
    minibuffer.input = try alloc.dupe(u8, input);
    minibuffer.context = try alloc.dupe(u8, context);
    minibuffer.candidates = try alloc.alloc(MinibufferCandidate, candidate_count);
    @memset(minibuffer.candidates, .{});

    var index: usize = 0;
    while (index < minibuffer.candidates.len) : (index += 1) {
        minibuffer.candidates[index] = try decodeMinibufferCandidate(alloc, packet, &offset);
    }

    return minibuffer;
}

/// Decodes a `gui_which_key` packet into owned overlay state.
pub fn decodeWhichKey(alloc: std.mem.Allocator, packet: []const u8) Error!WhichKey {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_WHICH_KEY) return error.Malformed;
    if (packet[1] == 0) return .{};

    var offset: usize = 2;
    const prefix = try readString16(packet, &offset);
    if (packet.len < offset + 4) return error.Malformed;
    const page = packet[offset];
    offset += 1;
    const page_count = packet[offset];
    offset += 1;
    const binding_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;

    var which_key = WhichKey{
        .visible = true,
        .page = page,
        .page_count = page_count,
    };
    errdefer which_key.deinit(alloc);

    which_key.prefix = try alloc.dupe(u8, prefix);
    which_key.bindings = try alloc.alloc(WhichKeyBinding, binding_count);
    @memset(which_key.bindings, .{});

    var index: usize = 0;
    while (index < which_key.bindings.len) : (index += 1) {
        which_key.bindings[index] = try decodeWhichKeyBinding(alloc, packet, &offset);
    }

    return which_key;
}

fn decodeWhichKeyBinding(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!WhichKeyBinding {
    if (packet.len < offset.* + 1) return error.Malformed;
    const kind = packet[offset.*];
    offset.* += 1;
    const key = try readString8(packet, offset);
    const description = try readString16(packet, offset);
    const icon = try readString8(packet, offset);

    return .{
        .kind = kind,
        .key = try alloc.dupe(u8, key),
        .description = try alloc.dupe(u8, description),
        .icon = try alloc.dupe(u8, icon),
    };
}

/// Decodes a `gui_completion` packet into owned popup state.
pub fn decodeCompletion(alloc: std.mem.Allocator, packet: []const u8) Error!Completion {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_COMPLETION) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 10) return error.Malformed;

    var offset: usize = 2;
    const cursor_row = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const cursor_col = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const selected_index = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const item_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;

    var completion = Completion{
        .visible = true,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
        .selected_index = selected_index,
        .items = try alloc.alloc(CompletionItem, item_count),
    };
    @memset(completion.items, .{});
    errdefer completion.deinit(alloc);

    var index: usize = 0;
    while (index < completion.items.len) : (index += 1) {
        completion.items[index] = try decodeCompletionItem(alloc, packet, &offset);
    }

    return completion;
}

fn decodeCompletionItem(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!CompletionItem {
    if (packet.len < offset.* + 1) return error.Malformed;
    const kind = packet[offset.*];
    offset.* += 1;
    const label = try readString16(packet, offset);
    const detail = try readString16(packet, offset);

    return .{
        .kind = kind,
        .label = try alloc.dupe(u8, label),
        .detail = try alloc.dupe(u8, detail),
    };
}

/// Decodes a `gui_breadcrumb` packet into owned path segments.
pub fn decodeBreadcrumb(alloc: std.mem.Allocator, packet: []const u8) Error!Breadcrumb {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_BREADCRUMB) return error.Malformed;

    var breadcrumb = Breadcrumb{
        .segments = try alloc.alloc([]u8, packet[1]),
    };
    @memset(breadcrumb.segments, &.{});
    errdefer breadcrumb.deinit(alloc);

    var offset: usize = 2;
    var index: usize = 0;
    while (index < breadcrumb.segments.len) : (index += 1) {
        const segment = try readString16(packet, &offset);
        breadcrumb.segments[index] = try alloc.dupe(u8, segment);
    }

    return breadcrumb;
}

/// Decodes a `gui_picker` packet into owned picker state.
pub fn decodePicker(alloc: std.mem.Allocator, packet: []const u8) Error!Picker {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_PICKER) return error.Malformed;
    if (packet[1] == 0) return .{};

    var picker = Picker{ .visible = true };
    errdefer picker.deinit(alloc);

    var offset: usize = 2;
    var section_index: u8 = 0;
    while (section_index < packet[1]) : (section_index += 1) {
        if (packet.len < offset + 3) return error.Malformed;
        const section_id = packet[offset];
        const section_len: usize = std.mem.readInt(u16, packet[offset + 1 ..][0..2], .big);
        offset += 3;
        if (packet.len < offset + section_len) return error.Malformed;
        const payload = packet[offset .. offset + section_len];
        offset += section_len;

        switch (section_id) {
            0x01 => try decodePickerHeader(alloc, payload, &picker),
            0x02 => try replaceString16(alloc, payload, 0, &picker.query),
            0x03 => try decodePickerItems(alloc, payload, &picker),
            0x04 => try decodePickerActions(alloc, payload, &picker),
            0x05 => try replaceString16(alloc, payload, 0, &picker.mode_prefix),
            0x06 => try decodePickerLoadStatus(alloc, payload, &picker),
            else => {},
        }
    }

    return picker;
}

fn decodePickerHeader(alloc: std.mem.Allocator, payload: []const u8, picker: *Picker) Error!void {
    if (payload.len < 10) return error.Malformed;
    picker.selected_index = std.mem.readInt(u16, payload[1..][0..2], .big);
    picker.filtered_count = std.mem.readInt(u16, payload[3..][0..2], .big);
    picker.total_count = std.mem.readInt(u16, payload[5..][0..2], .big);
    picker.has_preview = payload[7] != 0;
    var offset: usize = 8;
    const title = try readString16(payload, &offset);
    if (payload.len < offset + 2) return error.Malformed;
    picker.marked_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    try replaceOwned(alloc, title, &picker.title);
}

fn decodePickerItems(alloc: std.mem.Allocator, payload: []const u8, picker: *Picker) Error!void {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var items = try alloc.alloc(PickerItem, count);
    @memset(items, .{});
    errdefer {
        for (items) |*item| item.deinit(alloc);
        alloc.free(items);
    }

    var index: usize = 0;
    while (index < items.len) : (index += 1) {
        items[index] = try decodePickerItem(alloc, payload, &offset);
    }

    for (picker.items) |*item| item.deinit(alloc);
    alloc.free(picker.items);
    picker.items = items;
}

fn decodePickerItem(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!PickerItem {
    if (payload.len < offset.* + 4) return error.Malformed;
    const icon_color = readU24(payload[offset.* .. offset.* + 3]);
    offset.* += 3;
    const flags = payload[offset.*];
    offset.* += 1;
    const label = try readString16(payload, offset);
    const description = try readString16(payload, offset);
    const annotation = try readString16(payload, offset);
    if (payload.len < offset.* + 1) return error.Malformed;
    const match_count: usize = payload[offset.*];
    offset.* += 1;
    if (payload.len < offset.* + match_count * 2) return error.Malformed;
    offset.* += match_count * 2;

    return .{
        .label = try alloc.dupe(u8, label),
        .description = try alloc.dupe(u8, description),
        .annotation = try alloc.dupe(u8, annotation),
        .icon_color = icon_color,
        .flags = flags,
    };
}

fn decodePickerActions(alloc: std.mem.Allocator, payload: []const u8, picker: *Picker) Error!void {
    if (payload.len < 1) return error.Malformed;
    picker.action_visible = payload[0] != 0;
    if (!picker.action_visible) {
        for (picker.actions) |action| alloc.free(action);
        alloc.free(picker.actions);
        picker.actions = &.{};
        picker.action_index = 0;
        return;
    }
    if (payload.len < 3) return error.Malformed;
    picker.action_index = payload[1];
    const count: usize = payload[2];
    var offset: usize = 3;

    var actions = try alloc.alloc([]u8, count);
    @memset(actions, &.{});
    errdefer {
        for (actions) |action| alloc.free(action);
        alloc.free(actions);
    }

    var index: usize = 0;
    while (index < actions.len) : (index += 1) {
        const action = try readString16(payload, &offset);
        actions[index] = try alloc.dupe(u8, action);
    }

    for (picker.actions) |action| alloc.free(action);
    alloc.free(picker.actions);
    picker.actions = actions;
}

fn decodePickerLoadStatus(alloc: std.mem.Allocator, payload: []const u8, picker: *Picker) Error!void {
    if (payload.len < 1) return error.Malformed;
    picker.load_status = payload[0];
    if (payload[0] == 2) {
        try replaceString16(alloc, payload, 1, &picker.load_error);
    } else {
        alloc.free(picker.load_error);
        picker.load_error = &.{};
    }
}

/// Decodes a `gui_picker_preview` packet into owned preview lines.
pub fn decodePickerPreview(alloc: std.mem.Allocator, packet: []const u8) Error!PickerPreview {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_PICKER_PREVIEW) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 4) return error.Malformed;

    var offset: usize = 2;
    const line_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;

    var preview = PickerPreview{
        .visible = true,
        .lines = try alloc.alloc(PreviewLine, line_count),
    };
    @memset(preview.lines, .{});
    errdefer preview.deinit(alloc);

    var index: usize = 0;
    while (index < preview.lines.len) : (index += 1) {
        preview.lines[index] = try decodePreviewLine(alloc, packet, &offset);
    }

    return preview;
}

fn decodePreviewLine(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!PreviewLine {
    if (packet.len < offset.* + 1) return error.Malformed;
    const segment_count = packet[offset.*];
    offset.* += 1;

    var line = PreviewLine{
        .segments = try alloc.alloc(PreviewSegment, segment_count),
    };
    @memset(line.segments, .{});
    errdefer line.deinit(alloc);

    var index: usize = 0;
    while (index < line.segments.len) : (index += 1) {
        line.segments[index] = try decodePreviewSegment(alloc, packet, offset);
    }

    return line;
}

fn decodePreviewSegment(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!PreviewSegment {
    if (packet.len < offset.* + 6) return error.Malformed;
    const fg = readU24(packet[offset.* .. offset.* + 3]);
    offset.* += 3;
    const flags = packet[offset.*];
    offset.* += 1;
    const text = try readString16(packet, offset);

    return .{
        .text = try alloc.dupe(u8, text),
        .fg = fg,
        .bold = flags & 0x01 != 0,
    };
}

/// Decodes a `gui_hover_popup` packet into owned rich hover lines.
pub fn decodeHoverPopup(alloc: std.mem.Allocator, packet: []const u8) Error!HoverPopup {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_HOVER_POPUP) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 11) return error.Malformed;

    var offset: usize = 2;
    const anchor_row = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const anchor_col = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const focused = packet[offset] != 0;
    offset += 1;
    const scroll_offset = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const line_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;

    var hover = HoverPopup{
        .visible = true,
        .anchor_row = anchor_row,
        .anchor_col = anchor_col,
        .focused = focused,
        .scroll_offset = scroll_offset,
        .lines = try alloc.alloc(HoverLine, line_count),
    };
    @memset(hover.lines, .{});
    errdefer hover.deinit(alloc);

    var index: usize = 0;
    while (index < hover.lines.len) : (index += 1) {
        hover.lines[index] = try decodeHoverLine(alloc, packet, &offset);
    }

    return hover;
}

fn decodeHoverLine(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!HoverLine {
    if (packet.len < offset.* + 3) return error.Malformed;
    const line_type = packet[offset.*];
    offset.* += 1;
    const segment_count = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;

    var line = HoverLine{
        .line_type = line_type,
        .segments = try alloc.alloc(HoverSegment, segment_count),
    };
    @memset(line.segments, .{});
    errdefer line.deinit(alloc);

    var index: usize = 0;
    while (index < line.segments.len) : (index += 1) {
        line.segments[index] = try decodeHoverSegment(alloc, packet, offset);
    }

    return line;
}

fn decodeHoverSegment(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!HoverSegment {
    if (packet.len < offset.* + 1) return error.Malformed;
    const style = packet[offset.*];
    offset.* += 1;

    var fg: u24 = 0;
    var flags: u8 = 0;
    if (style == 13) {
        if (packet.len < offset.* + 4) return error.Malformed;
        fg = readU24(packet[offset.* .. offset.* + 3]);
        offset.* += 3;
        flags = packet[offset.*];
        offset.* += 1;
    }

    const text = try readString16(packet, offset);
    return .{
        .style = style,
        .fg = fg,
        .flags = flags,
        .text = try alloc.dupe(u8, text),
    };
}

/// Decodes a `gui_signature_help` packet into owned signature help state.
pub fn decodeSignatureHelp(alloc: std.mem.Allocator, packet: []const u8) Error!SignatureHelp {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_SIGNATURE_HELP) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 9) return error.Malformed;

    var offset: usize = 2;
    const anchor_row = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const anchor_col = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const active_signature = packet[offset];
    offset += 1;
    const active_parameter = packet[offset];
    offset += 1;
    const signature_count = packet[offset];
    offset += 1;

    var help = SignatureHelp{
        .visible = true,
        .anchor_row = anchor_row,
        .anchor_col = anchor_col,
        .active_signature = active_signature,
        .active_parameter = active_parameter,
        .signatures = try alloc.alloc(Signature, signature_count),
    };
    @memset(help.signatures, .{});
    errdefer help.deinit(alloc);

    var index: usize = 0;
    while (index < help.signatures.len) : (index += 1) {
        help.signatures[index] = try decodeSignature(alloc, packet, &offset);
    }

    return help;
}

fn decodeSignature(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!Signature {
    const label = try readString16(packet, offset);
    const documentation = try readString16(packet, offset);
    if (packet.len < offset.* + 1) return error.Malformed;
    const parameter_count = packet[offset.*];
    offset.* += 1;

    var signature = Signature{
        .label = try alloc.dupe(u8, label),
        .documentation = try alloc.dupe(u8, documentation),
        .parameters = try alloc.alloc(SignatureParameter, parameter_count),
    };
    @memset(signature.parameters, .{});
    errdefer signature.deinit(alloc);

    var index: usize = 0;
    while (index < signature.parameters.len) : (index += 1) {
        signature.parameters[index] = try decodeSignatureParameter(alloc, packet, offset);
    }

    return signature;
}

fn decodeSignatureParameter(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!SignatureParameter {
    const label = try readString16(packet, offset);
    const documentation = try readString16(packet, offset);
    return .{
        .label = try alloc.dupe(u8, label),
        .documentation = try alloc.dupe(u8, documentation),
    };
}

/// Decodes a `gui_float_popup` packet into owned popup lines.
pub fn decodeFloatPopup(alloc: std.mem.Allocator, packet: []const u8) Error!FloatPopup {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_FLOAT_POPUP) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 8) return error.Malformed;

    var offset: usize = 2;
    const width = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const height = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    const title = try readString16(packet, &offset);
    if (packet.len < offset + 2) return error.Malformed;
    const line_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;

    var popup = FloatPopup{
        .visible = true,
        .width = width,
        .height = height,
        .title = try alloc.dupe(u8, title),
        .lines = try alloc.alloc([]u8, line_count),
    };
    @memset(popup.lines, &.{});
    errdefer popup.deinit(alloc);

    var index: usize = 0;
    while (index < popup.lines.len) : (index += 1) {
        const line = try readString16(packet, &offset);
        popup.lines[index] = try alloc.dupe(u8, line);
    }

    return popup;
}

/// Decodes a `gui_git_status` packet into owned git status state.
pub fn decodeGitStatus(alloc: std.mem.Allocator, packet: []const u8) Error!GitStatus {
    if (packet.len < 9 or packet[0] != protocol.OP_GUI_GIT_STATUS) return error.Malformed;

    var offset: usize = 1;
    var git = GitStatus{
        .repo_state = packet[offset],
        .syncing = packet[offset + 1] != 0,
        .ahead = std.mem.readInt(u16, packet[offset + 2 ..][0..2], .big),
        .behind = std.mem.readInt(u16, packet[offset + 4 ..][0..2], .big),
    };
    offset += 6;
    errdefer git.deinit(alloc);

    const branch = try readString16(packet, &offset);
    git.branch = try alloc.dupe(u8, branch);

    if (packet.len < offset + 2) return error.Malformed;
    const entry_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    git.entries = try alloc.alloc(GitStatusEntry, entry_count);
    @memset(git.entries, .{});

    var index: usize = 0;
    while (index < git.entries.len) : (index += 1) {
        git.entries[index] = try decodeGitStatusEntry(alloc, packet, &offset);
    }

    git.toast = try decodeGitToast(alloc, packet, &offset);
    const entry_base_path = try readString16(packet, &offset);
    git.entry_base_path = try alloc.dupe(u8, entry_base_path);
    const last_commit_message = try readString16(packet, &offset);
    git.last_commit_message = try alloc.dupe(u8, last_commit_message);
    if (packet.len < offset + 2) return error.Malformed;
    git.stash_count = std.mem.readInt(u16, packet[offset..][0..2], .big);

    return git;
}

fn decodeGitStatusEntry(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!GitStatusEntry {
    if (packet.len < offset.* + 6) return error.Malformed;
    const path_hash = readU32(packet[offset.* .. offset.* + 4]);
    offset.* += 4;
    const section = packet[offset.*];
    offset.* += 1;
    const status = packet[offset.*];
    offset.* += 1;
    const path = try readString16(packet, offset);

    return .{
        .path_hash = path_hash,
        .section = section,
        .status = status,
        .path = try alloc.dupe(u8, path),
    };
}

fn decodeGitToast(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!GitToast {
    if (packet.len < offset.* + 1) return error.Malformed;
    if (packet[offset.*] == 0) {
        offset.* += 1;
        return .{};
    }

    if (packet.len < offset.* + 5) return error.Malformed;
    var toast = GitToast{
        .visible = true,
        .level = packet[offset.* + 1],
        .action = packet[offset.* + 2],
    };
    offset.* += 3;
    const message = try readString16(packet, offset);
    toast.message = try alloc.dupe(u8, message);
    return toast;
}

/// Decodes a `gui_bottom_panel` packet into owned panel state.
pub fn decodeBottomPanel(alloc: std.mem.Allocator, packet: []const u8) Error!BottomPanel {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_BOTTOM_PANEL) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 6) return error.Malformed;

    var offset: usize = 2;
    var panel = BottomPanel{
        .visible = true,
        .active_tab_index = packet[offset],
        .height_percent = packet[offset + 1],
        .filter = packet[offset + 2],
    };
    offset += 3;
    errdefer panel.deinit(alloc);

    const tab_count = packet[offset];
    offset += 1;
    panel.tabs = try alloc.alloc(BottomPanelTab, tab_count);
    @memset(panel.tabs, .{});

    var tab_index: usize = 0;
    while (tab_index < panel.tabs.len) : (tab_index += 1) {
        panel.tabs[tab_index] = try decodeBottomPanelTab(alloc, packet, &offset);
    }

    if (packet.len < offset + 2) return error.Malformed;
    const entry_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    panel.entries = try alloc.alloc(BottomPanelEntry, entry_count);
    @memset(panel.entries, .{});

    var entry_index: usize = 0;
    while (entry_index < panel.entries.len) : (entry_index += 1) {
        panel.entries[entry_index] = try decodeBottomPanelEntry(alloc, packet, &offset);
    }

    return panel;
}

fn decodeBottomPanelTab(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!BottomPanelTab {
    if (packet.len < offset.* + 1) return error.Malformed;
    const tab_type = packet[offset.*];
    offset.* += 1;
    const name = try readString8(packet, offset);
    return .{
        .tab_type = tab_type,
        .name = try alloc.dupe(u8, name),
    };
}

fn decodeBottomPanelEntry(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!BottomPanelEntry {
    if (packet.len < offset.* + 10) return error.Malformed;
    const id = readU32(packet[offset.* .. offset.* + 4]);
    offset.* += 4;
    const level = packet[offset.*];
    offset.* += 1;
    const subsystem = packet[offset.*];
    offset.* += 1;
    const timestamp_secs = readU32(packet[offset.* .. offset.* + 4]);
    offset.* += 4;
    const file_path = try readString16(packet, offset);
    const text = try readString16(packet, offset);

    return .{
        .id = id,
        .level = level,
        .subsystem = subsystem,
        .timestamp_secs = timestamp_secs,
        .file_path = try alloc.dupe(u8, file_path),
        .text = try alloc.dupe(u8, text),
    };
}

/// Decodes a `gui_split_separators` packet into owned separator state.
pub fn decodeSplitSeparators(alloc: std.mem.Allocator, packet: []const u8) Error!SplitSeparators {
    if (packet.len < 5 or packet[0] != protocol.OP_GUI_SPLIT_SEPARATORS) return error.Malformed;

    var separators = SplitSeparators{
        .color = readU24(packet[1..4]),
        .verticals = try alloc.alloc(VerticalSeparator, packet[4]),
    };
    @memset(separators.verticals, .{});
    errdefer separators.deinit(alloc);

    var offset: usize = 5;
    var vertical_index: usize = 0;
    while (vertical_index < separators.verticals.len) : (vertical_index += 1) {
        separators.verticals[vertical_index] = try decodeVerticalSeparator(packet, &offset);
    }

    if (packet.len < offset + 1) return error.Malformed;
    const horizontal_count = packet[offset];
    offset += 1;
    separators.horizontals = try alloc.alloc(HorizontalSeparator, horizontal_count);
    @memset(separators.horizontals, .{});

    var horizontal_index: usize = 0;
    while (horizontal_index < separators.horizontals.len) : (horizontal_index += 1) {
        separators.horizontals[horizontal_index] = try decodeHorizontalSeparator(alloc, packet, &offset);
    }

    return separators;
}

fn decodeVerticalSeparator(packet: []const u8, offset: *usize) Error!VerticalSeparator {
    if (packet.len < offset.* + 6) return error.Malformed;
    const col = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    const start_row = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    const end_row = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    return .{
        .col = col,
        .start_row = start_row,
        .end_row = end_row,
    };
}

fn decodeHorizontalSeparator(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!HorizontalSeparator {
    if (packet.len < offset.* + 6) return error.Malformed;
    const row = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    const col = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    const width = std.mem.readInt(u16, packet[offset.*..][0..2], .big);
    offset.* += 2;
    const filename = try readString16(packet, offset);
    return .{
        .row = row,
        .col = col,
        .width = width,
        .filename = try alloc.dupe(u8, filename),
    };
}

/// Decodes a `gui_window_content` full snapshot into owned window state.
pub fn decodeWindowContent(alloc: std.mem.Allocator, packet: []const u8) Error!WindowContent {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_WINDOW_CONTENT) return error.Malformed;

    var window = WindowContent{};
    errdefer window.deinit(alloc);

    var offset: usize = 2;
    var section_index: u8 = 0;
    while (section_index < packet[1]) : (section_index += 1) {
        if (packet.len < offset + 3) return error.Malformed;
        const section_id = packet[offset];
        const section_len: usize = std.mem.readInt(u16, packet[offset + 1 ..][0..2], .big);
        offset += 3;
        if (packet.len < offset + section_len) return error.Malformed;
        const payload = packet[offset .. offset + section_len];
        offset += section_len;

        switch (section_id) {
            0x01 => decodeWindowHeader(payload, &window),
            0x02 => try decodeWindowRows(alloc, payload, &window),
            0x03 => window.selection = decodeWindowSelection(payload),
            0x04 => window.search_matches = try decodeSearchMatches(alloc, payload),
            0x05 => window.diagnostic_ranges = try decodeDiagnosticRanges(alloc, payload),
            0x06 => window.document_highlights = try decodeDocumentHighlights(alloc, payload),
            0x07 => window.annotations = try decodeLineAnnotations(alloc, payload),
            0x08 => decodeWindowGeometry(payload, &window),
            0x09 => decodeWindowCursorline(payload, &window),
            else => {},
        }
    }

    return window;
}

/// Decodes a `gui_file_tree` packet into owned sidebar state.
pub fn decodeFileTree(alloc: std.mem.Allocator, packet: []const u8) Error!FileTree {
    if (packet.len < 5 or packet[0] != protocol.OP_GUI_FILE_TREE) return error.Malformed;
    const payload_len: usize = readU32(packet[1..5]);
    if (packet.len < 5 + payload_len) return error.Malformed;
    const payload = packet[5 .. 5 + payload_len];
    if (payload.len < 3) return error.Malformed;

    var offset: usize = 0;
    offset += 1;
    const flags = payload[offset];
    offset += 1;
    const status = payload[offset];
    offset += 1;
    const selected_id = try readString16(payload, &offset);
    const root_path = try readString16(payload, &offset);
    if (payload.len < offset + 4) return error.Malformed;
    const width = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    const row_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    const error_text = try readString16(payload, &offset);

    var tree = FileTree{
        .visible = flags & 0x01 != 0,
        .focused = flags & 0x02 != 0,
        .status = status,
        .width = width,
        .selected_id = try alloc.dupe(u8, selected_id),
        .root_path = try alloc.dupe(u8, root_path),
        .error_text = try alloc.dupe(u8, error_text),
        .rows = try alloc.alloc(FileTreeRow, row_count),
    };
    @memset(tree.rows, .{});
    errdefer tree.deinit(alloc);

    var row_index: usize = 0;
    while (row_index < tree.rows.len) : (row_index += 1) {
        tree.rows[row_index] = try decodeFileTreeRow(alloc, payload, &offset);
    }

    return tree;
}

/// Decodes a `gui_file_tree_selection` packet.
pub fn decodeFileTreeSelection(alloc: std.mem.Allocator, packet: []const u8) Error!FileTreeSelection {
    if (packet.len < 3 or packet[0] != protocol.OP_GUI_FILE_TREE_SELECTION) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (packet.len < 3 + payload_len) return error.Malformed;
    const payload = packet[3 .. 3 + payload_len];
    if (payload.len < 1) return error.Malformed;

    var offset: usize = 1;
    const selected_id = try readString16(payload, &offset);
    return .{
        .focused = payload[0] & 0x01 != 0,
        .selected_id = try alloc.dupe(u8, selected_id),
    };
}

/// Decodes a `gui_sidebars` packet into owned sidebar metadata.
pub fn decodeSidebars(alloc: std.mem.Allocator, packet: []const u8) Error!Sidebars {
    if (packet.len < 5 or packet[0] != protocol.OP_GUI_SIDEBARS) return error.Malformed;
    const payload_len: usize = readU32(packet[1..5]);
    if (packet.len < 5 + payload_len) return error.Malformed;
    const payload = packet[5 .. 5 + payload_len];
    if (payload.len < 3) return error.Malformed;

    var offset: usize = 0;
    const visible = payload[offset] != 0;
    offset += 1;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    const active_id = try readString16(payload, &offset);

    var sidebars = Sidebars{
        .visible = visible,
        .active_id = try alloc.dupe(u8, active_id),
        .items = try alloc.alloc(Sidebar, count),
    };
    @memset(sidebars.items, .{});
    errdefer sidebars.deinit(alloc);

    var index: usize = 0;
    while (index < sidebars.items.len) : (index += 1) {
        sidebars.items[index] = try decodeSidebar(alloc, payload, &offset);
    }

    return sidebars;
}

fn decodeSidebar(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!Sidebar {
    const id = try readString16(payload, offset);
    const display_name = try readString16(payload, offset);
    const semantic_kind = try readString16(payload, offset);
    const icon = try readString16(payload, offset);
    if (payload.len < offset.* + 7) return error.Malformed;
    const order = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    const flags = payload[offset.* + 2];
    const preferred_width = std.mem.readInt(u16, payload[offset.* + 3 ..][0..2], .big);
    const badge_count = std.mem.readInt(u16, payload[offset.* + 5 ..][0..2], .big);
    offset.* += 7;

    return .{
        .id = try alloc.dupe(u8, id),
        .display_name = try alloc.dupe(u8, display_name),
        .semantic_kind = try alloc.dupe(u8, semantic_kind),
        .icon = try alloc.dupe(u8, icon),
        .order = order,
        .flags = flags,
        .preferred_width = preferred_width,
        .badge_count = badge_count,
        .visible = flags & 0x01 != 0,
        .focused = flags & 0x02 != 0,
    };
}

/// Decodes a `gui_gutter` packet into owned per-window gutter state.
pub fn decodeGutter(alloc: std.mem.Allocator, packet: []const u8) Error!Gutter {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_GUTTER) return error.Malformed;

    var gutter = Gutter{};
    errdefer gutter.deinit(alloc);

    var offset: usize = 2;
    var section_index: u8 = 0;
    while (section_index < packet[1]) : (section_index += 1) {
        if (packet.len < offset + 3) return error.Malformed;
        const section_id = packet[offset];
        const section_len: usize = std.mem.readInt(u16, packet[offset + 1 ..][0..2], .big);
        offset += 3;
        if (packet.len < offset + section_len) return error.Malformed;
        const payload = packet[offset .. offset + section_len];
        offset += section_len;

        switch (section_id) {
            0x01 => decodeGutterWindow(payload, &gutter),
            0x02 => decodeGutterConfig(payload, &gutter),
            0x03 => try decodeGutterEntries(alloc, payload, &gutter),
            else => {},
        }
    }

    return gutter;
}

/// Decodes `gui_indent_guides` into owned per-window guide state.
pub fn decodeIndentGuides(alloc: std.mem.Allocator, packet: []const u8) Error!IndentGuides {
    if (packet.len < 9 or packet[0] != protocol.OP_GUI_INDENT_GUIDES) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (packet.len < 3 + payload_len or payload_len < 6) return error.Malformed;

    var offset: usize = 3;
    var guides = IndentGuides{
        .window_id = std.mem.readInt(u16, packet[offset..][0..2], .big),
        .tab_width = packet[offset + 2],
        .active_guide_col = std.mem.readInt(u16, packet[offset + 3 ..][0..2], .big),
    };
    errdefer guides.deinit(alloc);
    const guide_count = packet[offset + 5];
    offset += 6;

    guides.guide_cols = try alloc.alloc(u16, guide_count);
    var guide_index: usize = 0;
    while (guide_index < guides.guide_cols.len) : (guide_index += 1) {
        if (packet.len < offset + 2) return error.Malformed;
        guides.guide_cols[guide_index] = std.mem.readInt(u16, packet[offset..][0..2], .big);
        offset += 2;
    }

    if (guide_count == 0 and payload_len == 6) {
        guides.line_indent_levels = &.{};
        return guides;
    }

    if (packet.len < offset + 2) return error.Malformed;
    const line_count = std.mem.readInt(u16, packet[offset..][0..2], .big);
    offset += 2;
    if (packet.len < offset + line_count) return error.Malformed;
    guides.line_indent_levels = try alloc.dupe(u8, packet[offset .. offset + line_count]);

    return guides;
}

/// Decodes a `gui_theme` packet into retained color slots.
pub fn decodeTheme(alloc: std.mem.Allocator, packet: []const u8) Error!Theme {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_THEME) return error.Malformed;
    const count = packet[1];
    if (packet.len < 2 + @as(usize, count) * 4) return error.Malformed;

    var theme = Theme{
        .slots = try alloc.alloc(ThemeSlot, count),
    };
    errdefer theme.deinit(alloc);

    var offset: usize = 2;
    var index: usize = 0;
    while (index < theme.slots.len) : (index += 1) {
        theme.slots[index] = .{
            .id = packet[offset],
            .rgb = readU24(packet[offset + 1 .. offset + 4]),
        };
        offset += 4;
    }

    return theme;
}

/// Decodes a `gui_workspaces` packet into retained workspace header state.
pub fn decodeWorkspaces(alloc: std.mem.Allocator, packet: []const u8) Error!Workspaces {
    if (packet.len < 9 or packet[0] != protocol.OP_GUI_WORKSPACES) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (packet.len < 3 + payload_len or payload_len < 6) return error.Malformed;
    const body = packet[3 .. 3 + payload_len];

    var offset: usize = 0;
    var workspaces = Workspaces{
        .visible = body[offset],
        .active_workspace_id = std.mem.readInt(u16, body[offset + 1 ..][0..2], .big),
        .mode = body[offset + 3],
        .flags = body[offset + 4],
        .workspace_count = body[offset + 5],
        .spaces = try alloc.alloc(Workspace, body[offset + 5]),
    };
    @memset(workspaces.spaces, .{});
    errdefer workspaces.deinit(alloc);
    offset += 6;

    var space_index: usize = 0;
    while (space_index < workspaces.spaces.len) : (space_index += 1) {
        workspaces.spaces[space_index] = try decodeWorkspace(alloc, body, &offset);
    }

    if (body.len < offset + 2) {
        workspaces.tabs = &.{};
        return workspaces;
    }

    const tab_count = std.mem.readInt(u16, body[offset..][0..2], .big);
    offset += 2;
    workspaces.tabs = try alloc.alloc(WorkspaceTab, tab_count);
    @memset(workspaces.tabs, .{});

    var tab_index: usize = 0;
    while (tab_index < workspaces.tabs.len) : (tab_index += 1) {
        workspaces.tabs[tab_index] = try decodeWorkspaceTab(alloc, body, &offset);
    }

    return workspaces;
}

fn decodeFileTreeRow(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!FileTreeRow {
    if (payload.len < offset.* + 17) return error.Malformed;
    offset.* += 4;
    const flags = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const depth = payload[offset.*];
    offset.* += 1;
    const git_status = payload[offset.*];
    offset.* += 1;
    const diagnostic_errors = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const diagnostic_warnings = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const diagnostic_info = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const diagnostic_hints = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const guide_count: usize = payload[offset.*];
    offset.* += 1;
    if (payload.len < offset.* + guide_count) return error.Malformed;
    offset.* += guide_count;

    const id = try readString16(payload, offset);
    const path = try readString16(payload, offset);
    _ = try readString16(payload, offset);
    const name = try readString16(payload, offset);
    const icon = try readString8(payload, offset);
    if (payload.len < offset.* + 1) return error.Malformed;
    offset.* += 1;
    const editing_text = try readString16(payload, offset);

    return .{
        .id = try alloc.dupe(u8, id),
        .path = try alloc.dupe(u8, path),
        .name = try alloc.dupe(u8, name),
        .icon = try alloc.dupe(u8, icon),
        .depth = depth,
        .flags = flags,
        .git_status = git_status,
        .diagnostic_errors = diagnostic_errors,
        .diagnostic_warnings = diagnostic_warnings,
        .diagnostic_info = diagnostic_info,
        .diagnostic_hints = diagnostic_hints,
        .editing_text = try alloc.dupe(u8, editing_text),
    };
}

fn decodeWorkspace(alloc: std.mem.Allocator, body: []const u8, offset: *usize) Error!Workspace {
    if (body.len < offset.* + 17) return error.Malformed;
    const id = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const kind = body[offset.*];
    offset.* += 1;
    const status = body[offset.*];
    offset.* += 1;
    const flags = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const color = readU24(body[offset.* .. offset.* + 3]);
    offset.* += 3;
    const tab_count = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const draft_count = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const conflict_count = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const background_count = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const label = try readString8(body, offset);
    const icon = try readString8(body, offset);

    return .{
        .id = id,
        .kind = kind,
        .status = status,
        .flags = flags,
        .color = color,
        .tab_count = tab_count,
        .draft_count = draft_count,
        .conflict_count = conflict_count,
        .background_count = background_count,
        .label = try alloc.dupe(u8, label),
        .icon = try alloc.dupe(u8, icon),
    };
}

fn decodeWorkspaceTab(alloc: std.mem.Allocator, body: []const u8, offset: *usize) Error!WorkspaceTab {
    if (body.len < offset.* + 13) return error.Malformed;
    const id = readU32(body[offset.* .. offset.* + 4]);
    offset.* += 4;
    const workspace_id = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const kind = body[offset.*];
    offset.* += 1;
    const flags = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;
    const path_hash = readU32(body[offset.* .. offset.* + 4]);
    offset.* += 4;
    const icon = try readString8(body, offset);
    const label = try readString16(body, offset);
    const path = try readString16(body, offset);
    if (body.len < offset.* + 4) return error.Malformed;
    const tint = readU32(body[offset.* .. offset.* + 4]);
    offset.* += 4;

    return .{
        .id = id,
        .workspace_id = workspace_id,
        .kind = kind,
        .flags = flags,
        .path_hash = path_hash,
        .icon = try alloc.dupe(u8, icon),
        .label = try alloc.dupe(u8, label),
        .path = try alloc.dupe(u8, path),
        .tint = tint,
    };
}

fn decodeGutterWindow(payload: []const u8, gutter: *Gutter) void {
    if (payload.len < 11) return;
    gutter.window_id = std.mem.readInt(u16, payload[0..][0..2], .big);
    gutter.content_row = std.mem.readInt(u16, payload[2..][0..2], .big);
    gutter.content_col = std.mem.readInt(u16, payload[4..][0..2], .big);
    gutter.content_height = std.mem.readInt(u16, payload[6..][0..2], .big);
    gutter.is_active = payload[8] != 0;
    gutter.content_width = std.mem.readInt(u16, payload[9..][0..2], .big);
}

fn decodeGutterConfig(payload: []const u8, gutter: *Gutter) void {
    if (payload.len < 7) return;
    gutter.cursor_line = readU32(payload[0..4]);
    gutter.line_number_style = payload[4];
    gutter.line_number_width = payload[5];
    gutter.sign_col_width = payload[6];
}

fn decodeGutterEntries(alloc: std.mem.Allocator, payload: []const u8, gutter: *Gutter) Error!void {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var entries = try alloc.alloc(GutterEntry, count);
    @memset(entries, .{});
    errdefer {
        for (entries) |*entry| entry.deinit(alloc);
        alloc.free(entries);
    }

    var index: usize = 0;
    while (index < entries.len) : (index += 1) {
        entries[index] = try decodeGutterEntry(alloc, payload, &offset);
    }

    for (gutter.entries) |*entry| entry.deinit(alloc);
    alloc.free(gutter.entries);
    gutter.entries = entries;
}

fn decodeGutterEntry(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!GutterEntry {
    if (payload.len < offset.* + 10) return error.Malformed;
    const buf_line = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;
    const display_type = payload[offset.*];
    offset.* += 1;
    const sign_type = payload[offset.*];
    offset.* += 1;
    const fold_end_line = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;

    var sign_fg: u24 = 0;
    var sign_text: []const u8 = &.{};
    if (sign_type == 8) {
        if (payload.len < offset.* + 4) return error.Malformed;
        sign_fg = readU24(payload[offset.* .. offset.* + 3]);
        offset.* += 3;
        const len: usize = payload[offset.*];
        offset.* += 1;
        if (payload.len < offset.* + len) return error.Malformed;
        sign_text = payload[offset.* .. offset.* + len];
        offset.* += len;
    }

    return .{
        .buf_line = buf_line,
        .display_type = display_type,
        .sign_type = sign_type,
        .fold_end_line = fold_end_line,
        .sign_fg = sign_fg,
        .sign_text = try alloc.dupe(u8, sign_text),
    };
}

/// Decodes a `gui_window_overlay_delta` cursor update.
pub fn decodeWindowOverlayDelta(packet: []const u8) Error!WindowOverlayDelta {
    if (packet.len < 13 or packet[0] != protocol.OP_GUI_WINDOW_OVERLAY_DELTA) return error.Malformed;
    const flags = packet[7];
    var delta = WindowOverlayDelta{
        .window_id = std.mem.readInt(u16, packet[1..][0..2], .big),
        .content_epoch = readU32(packet[3..7]),
        .flags = flags,
        .cursor_row = std.mem.readInt(u16, packet[8..][0..2], .big),
        .cursor_col = std.mem.readInt(u16, packet[10..][0..2], .big),
        .cursor_shape = packet[12],
    };

    if (flags & 0x02 != 0) {
        if (packet.len < 18) return error.Malformed;
        delta.cursorline_visible = true;
        delta.cursorline_row = std.mem.readInt(u16, packet[13..][0..2], .big);
        delta.cursorline_bg = readU24(packet[15..18]);
    }

    return delta;
}

/// Decodes `gui_window_rows_delta` or `gui_window_viewport_delta` into owned row delta state.
pub fn decodeWindowRowsDelta(alloc: std.mem.Allocator, packet: []const u8) Error!WindowRowsDelta {
    if (packet.len < 2 or (packet[0] != protocol.OP_GUI_WINDOW_ROWS_DELTA and packet[0] != protocol.OP_GUI_WINDOW_VIEWPORT_DELTA)) return error.Malformed;

    var delta = WindowRowsDelta{};
    errdefer delta.deinit(alloc);

    var offset: usize = 2;
    var section_index: u8 = 0;
    while (section_index < packet[1]) : (section_index += 1) {
        if (packet.len < offset + 3) return error.Malformed;
        const section_id = packet[offset];
        const section_len: usize = std.mem.readInt(u16, packet[offset + 1 ..][0..2], .big);
        offset += 3;
        if (packet.len < offset + section_len) return error.Malformed;
        const payload = packet[offset .. offset + section_len];
        offset += section_len;

        switch (section_id) {
            0x01 => decodeWindowRowsDeltaHeader(payload, &delta),
            0x02 => try decodeWindowDeltaRows(alloc, payload, &delta),
            0x03 => delta.selection = decodeWindowSelection(payload),
            0x04 => delta.search_matches = try decodeSearchMatches(alloc, payload),
            0x05 => delta.diagnostic_ranges = try decodeDiagnosticRanges(alloc, payload),
            0x06 => delta.document_highlights = try decodeDocumentHighlights(alloc, payload),
            0x07 => delta.annotations = try decodeLineAnnotations(alloc, payload),
            0x08 => decodeWindowRowsDeltaGeometry(payload, &delta),
            0x09 => decodeWindowRowsDeltaCursorline(payload, &delta),
            else => {},
        }
    }

    return delta;
}

fn decodeWindowHeader(payload: []const u8, window: *WindowContent) void {
    if (payload.len < 14) return;
    window.window_id = std.mem.readInt(u16, payload[0..][0..2], .big);
    window.flags = payload[2];
    // Full content header (0x80): bit 0 = full_refresh, bit 1 = cursor_visible.
    window.cursor_visible = (payload[2] & 0x02) != 0;
    window.cursor_row = std.mem.readInt(u16, payload[3..][0..2], .big);
    window.cursor_col = std.mem.readInt(u16, payload[5..][0..2], .big);
    window.cursor_shape = payload[7];
    window.scroll_left = std.mem.readInt(u16, payload[8..][0..2], .big);
    window.content_epoch = readU32(payload[10..14]);
}

fn decodeWindowRowsDeltaHeader(payload: []const u8, delta: *WindowRowsDelta) void {
    if (payload.len < 14) return;
    delta.window_id = std.mem.readInt(u16, payload[0..][0..2], .big);
    delta.content_epoch = readU32(payload[2..6]);
    delta.flags = payload[6];
    delta.cursor_row = std.mem.readInt(u16, payload[7..][0..2], .big);
    delta.cursor_col = std.mem.readInt(u16, payload[9..][0..2], .big);
    delta.cursor_shape = payload[11];
    delta.scroll_left = std.mem.readInt(u16, payload[12..][0..2], .big);
}

fn decodeWindowRowsDeltaCursorline(payload: []const u8, delta: *WindowRowsDelta) void {
    if (payload.len < 5) return;
    delta.cursorline_visible = true;
    delta.cursorline_row = std.mem.readInt(u16, payload[0..][0..2], .big);
    delta.cursorline_bg = readU24(payload[2..5]);
}

fn decodeWindowRowsDeltaGeometry(payload: []const u8, delta: *WindowRowsDelta) void {
    if (payload.len < 26) return;
    const text_rect_offset: usize = 2 + 8 + 8;
    delta.geometry_set = true;
    delta.origin_row = std.mem.readInt(u16, payload[text_rect_offset..][0..2], .big);
    delta.origin_col = std.mem.readInt(u16, payload[text_rect_offset + 2 ..][0..2], .big);
    delta.text_width = std.mem.readInt(u16, payload[text_rect_offset + 4 ..][0..2], .big);
    delta.text_height = std.mem.readInt(u16, payload[text_rect_offset + 6 ..][0..2], .big);
}

fn decodeWindowGeometry(payload: []const u8, window: *WindowContent) void {
    if (payload.len < 26) return;
    const text_rect_offset: usize = 2 + 8 + 8;
    window.origin_row = std.mem.readInt(u16, payload[text_rect_offset..][0..2], .big);
    window.origin_col = std.mem.readInt(u16, payload[text_rect_offset + 2 ..][0..2], .big);
    window.text_width = std.mem.readInt(u16, payload[text_rect_offset + 4 ..][0..2], .big);
    window.text_height = std.mem.readInt(u16, payload[text_rect_offset + 6 ..][0..2], .big);
}

fn decodeWindowCursorline(payload: []const u8, window: *WindowContent) void {
    if (payload.len < 5) return;
    window.cursorline_visible = true;
    window.cursorline_row = std.mem.readInt(u16, payload[0..][0..2], .big);
    window.cursorline_bg = readU24(payload[2..5]);
}

pub fn decodeWindowSelection(payload: []const u8) WindowSelection {
    if (payload.len < 1 or payload[0] == 0) return .{};
    if (payload.len < 9) return .{};
    return .{
        .selection_type = payload[0],
        .start_row = std.mem.readInt(u16, payload[1..][0..2], .big),
        .start_col = std.mem.readInt(u16, payload[3..][0..2], .big),
        .end_row = std.mem.readInt(u16, payload[5..][0..2], .big),
        .end_col = std.mem.readInt(u16, payload[7..][0..2], .big),
    };
}

pub fn decodeSearchMatches(alloc: std.mem.Allocator, payload: []const u8) Error![]SearchMatch {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    const matches = try alloc.alloc(SearchMatch, count);
    errdefer alloc.free(matches);

    for (matches) |*match| {
        if (payload.len < offset + 7) return error.Malformed;
        match.* = .{
            .row = std.mem.readInt(u16, payload[offset..][0..2], .big),
            .start_col = std.mem.readInt(u16, payload[offset + 2 ..][0..2], .big),
            .end_col = std.mem.readInt(u16, payload[offset + 4 ..][0..2], .big),
            .current = payload[offset + 6] != 0,
        };
        offset += 7;
    }

    return matches;
}

pub fn decodeDiagnosticRanges(alloc: std.mem.Allocator, payload: []const u8) Error![]DiagnosticRange {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    const ranges = try alloc.alloc(DiagnosticRange, count);
    errdefer alloc.free(ranges);

    for (ranges) |*range| {
        if (payload.len < offset + 9) return error.Malformed;
        range.* = .{
            .start_row = std.mem.readInt(u16, payload[offset..][0..2], .big),
            .start_col = std.mem.readInt(u16, payload[offset + 2 ..][0..2], .big),
            .end_row = std.mem.readInt(u16, payload[offset + 4 ..][0..2], .big),
            .end_col = std.mem.readInt(u16, payload[offset + 6 ..][0..2], .big),
            .severity = payload[offset + 8],
        };
        offset += 9;
    }

    return ranges;
}

pub fn decodeDocumentHighlights(alloc: std.mem.Allocator, payload: []const u8) Error![]DocumentHighlight {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    const highlights = try alloc.alloc(DocumentHighlight, count);
    errdefer alloc.free(highlights);

    for (highlights) |*highlight| {
        if (payload.len < offset + 9) return error.Malformed;
        highlight.* = .{
            .start_row = std.mem.readInt(u16, payload[offset..][0..2], .big),
            .start_col = std.mem.readInt(u16, payload[offset + 2 ..][0..2], .big),
            .end_row = std.mem.readInt(u16, payload[offset + 4 ..][0..2], .big),
            .end_col = std.mem.readInt(u16, payload[offset + 6 ..][0..2], .big),
            .kind = payload[offset + 8],
        };
        offset += 9;
    }

    return highlights;
}

pub fn decodeLineAnnotations(alloc: std.mem.Allocator, payload: []const u8) Error![]LineAnnotation {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var annotations = try alloc.alloc(LineAnnotation, count);
    @memset(annotations, .{});
    var index: usize = 0;
    errdefer {
        for (annotations[0..index]) |*annotation| annotation.deinit(alloc);
        alloc.free(annotations);
    }

    while (index < annotations.len) : (index += 1) {
        if (payload.len < offset + 9) return error.Malformed;
        annotations[index].row = std.mem.readInt(u16, payload[offset..][0..2], .big);
        offset += 2;
        annotations[index].kind = payload[offset];
        offset += 1;
        annotations[index].fg = readU24(payload[offset .. offset + 3]);
        offset += 3;
        annotations[index].bg = readU24(payload[offset .. offset + 3]);
        offset += 3;
        const text = try readString16(payload, &offset);
        annotations[index].text = try alloc.dupe(u8, text);
    }

    return annotations;
}

fn decodeWindowRows(alloc: std.mem.Allocator, payload: []const u8, window: *WindowContent) Error!void {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const row_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var rows = try alloc.alloc(WindowRow, row_count);
    @memset(rows, .{});
    errdefer {
        for (rows) |*row| row.deinit(alloc);
        alloc.free(rows);
    }

    var index: usize = 0;
    while (index < rows.len) : (index += 1) {
        rows[index] = try decodeWindowRow(alloc, payload, &offset);
    }

    for (window.rows) |*row| row.deinit(alloc);
    alloc.free(window.rows);
    window.rows = rows;
}

fn decodeWindowDeltaRows(alloc: std.mem.Allocator, payload: []const u8, delta: *WindowRowsDelta) Error!void {
    if (payload.len < 2) return error.Malformed;
    var offset: usize = 0;
    const row_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var rows = try alloc.alloc(WindowRow, row_count);
    @memset(rows, .{});
    errdefer {
        for (rows) |*row| row.deinit(alloc);
        alloc.free(rows);
    }

    var index: usize = 0;
    while (index < rows.len) : (index += 1) {
        if (payload.len < offset + 1) return error.Malformed;
        const entry_kind = payload[offset];
        offset += 1;
        rows[index] = switch (entry_kind) {
            0 => try decodeWindowRowRef(payload, &offset),
            1 => try decodeWindowRow(alloc, payload, &offset),
            else => return error.Malformed,
        };
    }

    for (delta.rows) |*row| row.deinit(alloc);
    alloc.free(delta.rows);
    delta.rows = rows;
}

fn decodeWindowRow(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!WindowRow {
    if (payload.len < offset.* + 21) return error.Malformed;
    const row_type = payload[offset.*];
    offset.* += 1;
    const row_id = readU64(payload[offset.* .. offset.* + 8]);
    offset.* += 8;
    const buf_line = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;
    const content_hash = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;
    const text_len: usize = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;
    if (payload.len < offset.* + text_len + 2) return error.Malformed;
    const text = payload[offset.* .. offset.* + text_len];
    offset.* += text_len;
    const span_count = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;

    var row = WindowRow{
        .row_type = row_type,
        .row_id = row_id,
        .buf_line = buf_line,
        .content_hash = content_hash,
        .text = try alloc.dupe(u8, text),
        .spans = try alloc.alloc(WindowSpan, span_count),
    };
    @memset(row.spans, .{});
    errdefer row.deinit(alloc);

    var span_index: usize = 0;
    while (span_index < row.spans.len) : (span_index += 1) {
        row.spans[span_index] = try decodeWindowSpan(payload, offset);
    }

    return row;
}

fn decodeWindowRowRef(payload: []const u8, offset: *usize) Error!WindowRow {
    if (payload.len < offset.* + 12) return error.Malformed;
    const row_id = readU64(payload[offset.* .. offset.* + 8]);
    offset.* += 8;
    const content_hash = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;

    return .{
        .ref = true,
        .row_id = row_id,
        .content_hash = content_hash,
    };
}

fn decodeWindowSpan(payload: []const u8, offset: *usize) Error!WindowSpan {
    if (payload.len < offset.* + 13) return error.Malformed;
    const start_col = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const end_col = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    const fg = readU24(payload[offset.* .. offset.* + 3]);
    offset.* += 3;
    const bg = readU24(payload[offset.* .. offset.* + 3]);
    offset.* += 3;
    const attrs = payload[offset.*];
    offset.* += 1;
    offset.* += 2;

    return .{
        .start_col = start_col,
        .end_col = end_col,
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

pub fn cloneRetainedWindowRow(alloc: std.mem.Allocator, retained_rows: []const WindowRow, delta_row: WindowRow) std.mem.Allocator.Error!?WindowRow {
    for (retained_rows) |row| {
        if (row.row_id == delta_row.row_id and row.content_hash == delta_row.content_hash) {
            return try cloneWindowRow(alloc, row);
        }
    }
    return null;
}

pub fn cloneWindowRow(alloc: std.mem.Allocator, row: WindowRow) std.mem.Allocator.Error!WindowRow {
    return .{
        .row_type = row.row_type,
        .row_id = row.row_id,
        .buf_line = row.buf_line,
        .content_hash = row.content_hash,
        .text = try alloc.dupe(u8, row.text),
        .spans = try alloc.dupe(WindowSpan, row.spans),
    };
}

pub fn applyWindowOverlaySections(alloc: std.mem.Allocator, window: *WindowContent, delta: *WindowRowsDelta) void {
    if (delta.selection) |selection| {
        window.selection = selection;
    }

    if (delta.search_matches) |items| {
        alloc.free(window.search_matches);
        window.search_matches = items;
        delta.search_matches = null;
    }

    if (delta.diagnostic_ranges) |items| {
        alloc.free(window.diagnostic_ranges);
        window.diagnostic_ranges = items;
        delta.diagnostic_ranges = null;
    }

    if (delta.document_highlights) |items| {
        alloc.free(window.document_highlights);
        window.document_highlights = items;
        delta.document_highlights = null;
    }

    if (delta.annotations) |items| {
        for (window.annotations) |*annotation| annotation.deinit(alloc);
        alloc.free(window.annotations);
        window.annotations = items;
        delta.annotations = null;
    }
}

fn decodeMinibufferCandidate(
    alloc: std.mem.Allocator,
    packet: []const u8,
    offset: *usize,
) Error!MinibufferCandidate {
    if (packet.len < offset.* + 1) return error.Malformed;
    offset.* += 1;
    const label = try readString16(packet, offset);
    const description = try readString16(packet, offset);
    const annotation = try readString16(packet, offset);
    if (packet.len < offset.* + 1) return error.Malformed;
    const match_count: usize = packet[offset.*];
    offset.* += 1;
    if (packet.len < offset.* + match_count * 2) return error.Malformed;
    offset.* += match_count * 2;

    return .{
        .label = try alloc.dupe(u8, label),
        .description = try alloc.dupe(u8, description),
        .annotation = try alloc.dupe(u8, annotation),
    };
}

/// Decodes a `gui_search_state` packet.
pub fn decodeSearchState(packet: []const u8) Error!SearchState {
    if (packet.len < 9 or packet[0] != protocol.OP_GUI_SEARCH_STATE) return error.Malformed;
    const body_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (body_len < 6 or packet.len < 3 + body_len) return error.Malformed;

    return .{
        .active = packet[3] != 0,
        .match_count = std.mem.readInt(u16, packet[4..][0..2], .big),
        .current_index = std.mem.readInt(u16, packet[6..][0..2], .big),
        .flags = packet[8],
    };
}

/// Decodes a `gui_change_summary` packet into owned state.
pub fn decodeChangeSummary(alloc: std.mem.Allocator, packet: []const u8) Error!ChangeSummary {
    if (packet.len < 6 or packet[0] != protocol.OP_GUI_CHANGE_SUMMARY) return error.Malformed;

    const count = std.mem.readInt(u16, packet[4..][0..2], .big);
    var summary = ChangeSummary{
        .visible = packet[1] != 0,
        .selected_index = std.mem.readInt(u16, packet[2..][0..2], .big),
        .entries = try alloc.alloc(ChangeSummaryEntry, count),
    };
    @memset(summary.entries, .{});
    errdefer summary.deinit(alloc);

    var offset: usize = 6;
    for (summary.entries) |*entry| {
        const path = try readString16(packet, &offset);
        if (packet.len < offset + 9) return error.Malformed;
        entry.* = .{
            .path = try alloc.dupe(u8, path),
            .action = packet[offset],
            .lines_added = readU32(packet[offset + 1 .. offset + 5]),
            .lines_removed = readU32(packet[offset + 5 .. offset + 9]),
        };
        offset += 9;
    }

    return summary;
}

/// Decodes a `gui_notifications` packet into owned notification state.
pub fn decodeNotifications(alloc: std.mem.Allocator, packet: []const u8) Error!Notifications {
    if (packet.len < 6 or packet[0] != protocol.OP_GUI_NOTIFICATIONS) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (payload_len < 3 or packet.len < 3 + payload_len) return error.Malformed;
    const payload = packet[3 .. 3 + payload_len];

    var offset: usize = 0;
    const visible = payload[offset] != 0;
    offset += 1;
    const count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    var notifications = Notifications{
        .visible = visible,
        .notification_count = count,
        .items = try alloc.alloc(NotificationItem, count),
    };
    @memset(notifications.items, .{});
    errdefer notifications.deinit(alloc);

    var index: usize = 0;
    while (index < notifications.items.len) : (index += 1) {
        notifications.items[index] = try decodeNotificationItem(alloc, payload, &offset);
    }

    return notifications;
}

fn decodeNotificationItem(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!NotificationItem {
    const id = try readString16(payload, offset);
    if (payload.len < offset.* + 22) return error.Malformed;
    const level = payload[offset.*];
    const dismissable = payload[offset.* + 1] & 0x01 != 0;
    const created_at = readU64(payload[offset.* + 2 .. offset.* + 10]);
    const updated_at = readU64(payload[offset.* + 10 .. offset.* + 18]);
    const auto_dismiss_ms = readU32(payload[offset.* + 18 .. offset.* + 22]);
    offset.* += 22;
    const title = try readString16(payload, offset);
    const body = try readString16(payload, offset);
    const source = try readString16(payload, offset);
    if (payload.len < offset.* + 1) return error.Malformed;
    const action_count = payload[offset.*];
    offset.* += 1;
    var actions = try alloc.alloc(NotificationAction, action_count);
    @memset(actions, .{});
    errdefer {
        for (actions) |*action| action.deinit(alloc);
        alloc.free(actions);
    }
    var action_index: u8 = 0;
    while (action_index < action_count) : (action_index += 1) {
        const action_id = try readString16(payload, offset);
        const action_label = try readString16(payload, offset);
        actions[action_index] = .{
            .id = try alloc.dupe(u8, action_id),
            .label = try alloc.dupe(u8, action_label),
        };
    }

    return .{
        .id = try alloc.dupe(u8, id),
        .level = level,
        .dismissable = dismissable,
        .created_at = created_at,
        .updated_at = updated_at,
        .auto_dismiss_ms = auto_dismiss_ms,
        .title = try alloc.dupe(u8, title),
        .body = try alloc.dupe(u8, body),
        .source = try alloc.dupe(u8, source),
        .actions = actions,
    };
}

/// Decodes a `gui_edit_timeline` packet into owned timeline state.
pub fn decodeEditTimeline(alloc: std.mem.Allocator, packet: []const u8) Error!EditTimeline {
    if (packet.len < 7 or packet[0] != protocol.OP_GUI_EDIT_TIMELINE) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (payload_len < 4 or packet.len < 3 + payload_len) return error.Malformed;
    const payload = packet[3 .. 3 + payload_len];

    var offset: usize = 0;
    const visible = payload[offset] != 0;
    offset += 1;
    const viewing_index = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    const count = payload[offset];
    offset += 1;

    var timeline = EditTimeline{
        .visible = visible,
        .viewing_index = viewing_index,
        .entry_count = count,
        .entries = try alloc.alloc(TimelineEntry, count),
    };
    @memset(timeline.entries, .{});
    errdefer timeline.deinit(alloc);

    var index: usize = 0;
    while (index < timeline.entries.len) : (index += 1) {
        timeline.entries[index] = try decodeTimelineEntry(alloc, payload, &offset);
    }

    return timeline;
}

fn decodeTimelineEntry(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!TimelineEntry {
    if (payload.len < offset.* + 1) return error.Malformed;
    const index = payload[offset.*];
    offset.* += 1;
    const tool_name = try readString8(payload, offset);
    if (payload.len < offset.* + 4) return error.Malformed;
    const timestamp_delta = readU32(payload[offset.* .. offset.* + 4]);
    offset.* += 4;

    return .{
        .index = index,
        .tool_name = try alloc.dupe(u8, tool_name),
        .timestamp_delta = timestamp_delta,
    };
}

/// Decodes a `gui_extension_overlay` packet count.
pub fn decodeExtensionOverlay(alloc: std.mem.Allocator, packet: []const u8) Error!ExtensionOverlay {
    if (packet.len < 4 or packet[0] != protocol.OP_GUI_EXTENSION_OVERLAY) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (payload_len < 1 or packet.len < 3 + payload_len) return error.Malformed;
    const payload = packet[3 .. 3 + payload_len];
    const count: usize = payload[0];
    var overlay = ExtensionOverlay{ .entry_count = payload[0] };
    errdefer overlay.deinit(alloc);

    var entries: std.ArrayList(ExtensionOverlayEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    var offset: usize = 1;
    var index: usize = 0;
    while (index < count and offset < payload.len) : (index += 1) {
        const extension = try readString8(payload, &offset);
        const id = try readString8(payload, &offset);
        if (payload.len < offset + 13) return error.Malformed;
        var entry = ExtensionOverlayEntry{
            .extension = try alloc.dupe(u8, extension),
            .id = &.{},
            .window_id = std.mem.readInt(u16, payload[offset..][0..2], .big),
            .row = std.mem.readInt(u16, payload[offset + 2 ..][0..2], .big),
            .col = std.mem.readInt(u16, payload[offset + 4 ..][0..2], .big),
            .shape = payload[offset + 6],
            .fg = readU24(payload[offset + 7 .. offset + 10]),
            .opacity = payload[offset + 10],
            .content = &.{},
        };
        errdefer entry.deinit(alloc);
        offset += 11;
        entry.id = try alloc.dupe(u8, id);
        const content = try readString16(payload, &offset);
        entry.content = try alloc.dupe(u8, content);
        try entries.append(alloc, entry);
    }

    overlay.entries = try entries.toOwnedSlice(alloc);
    return overlay;
}

/// Decodes a `gui_extension_panel` packet count.
pub fn decodeExtensionPanel(alloc: std.mem.Allocator, packet: []const u8) Error!ExtensionPanel {
    if (packet.len < 4 or packet[0] != protocol.OP_GUI_EXTENSION_PANEL) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (payload_len < 1 or packet.len < 3 + payload_len) return error.Malformed;
    const payload = packet[3 .. 3 + payload_len];
    const count: usize = payload[0];
    var panel = ExtensionPanel{ .panel_count = payload[0] };
    errdefer panel.deinit(alloc);

    var panels: std.ArrayList(ExtensionPanelEntry) = .empty;
    errdefer {
        for (panels.items) |*entry| entry.deinit(alloc);
        panels.deinit(alloc);
    }

    var offset: usize = 1;
    var index: usize = 0;
    while (index < count and offset < payload.len) : (index += 1) {
        var entry = try decodeExtensionPanelEntry(alloc, payload, &offset);
        errdefer entry.deinit(alloc);
        try panels.append(alloc, entry);
    }

    panel.panels = try panels.toOwnedSlice(alloc);
    return panel;
}

fn decodeExtensionPanelEntry(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!ExtensionPanelEntry {
    const extension = try readString8(payload, offset);
    const id = try readString8(payload, offset);
    const title = try readString8(payload, offset);
    if (payload.len < offset.* + 5) return error.Malformed;

    var entry = ExtensionPanelEntry{
        .extension = try alloc.dupe(u8, extension),
        .id = &.{},
        .title = &.{},
        .position = payload[offset.*],
        .size_type = payload[offset.* + 1],
        .size_value = payload[offset.* + 2],
        .visible = payload[offset.* + 3] != 0,
        .blocks = &.{},
    };
    errdefer entry.deinit(alloc);
    const block_count: usize = payload[offset.* + 4];
    offset.* += 5;

    entry.id = try alloc.dupe(u8, id);
    entry.title = try alloc.dupe(u8, title);

    var blocks: std.ArrayList([]u8) = .empty;
    errdefer {
        for (blocks.items) |block| alloc.free(block);
        blocks.deinit(alloc);
    }

    var index: usize = 0;
    while (index < block_count and offset.* < payload.len) : (index += 1) {
        const block = try decodeExtensionPanelBlock(alloc, payload, offset);
        if (block.len > 0) {
            try blocks.append(alloc, block);
        } else {
            alloc.free(block);
        }
    }

    entry.blocks = try blocks.toOwnedSlice(alloc);
    return entry;
}

fn decodeExtensionPanelBlock(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error![]u8 {
    if (payload.len < offset.* + 1) return error.Malformed;
    const kind = payload[offset.*];
    offset.* += 1;

    return switch (kind) {
        0 => try alloc.dupe(u8, try readString16(payload, offset)),
        1 => try decodeExtensionPanelStyledText(alloc, payload, offset),
        2 => try decodeExtensionPanelTable(alloc, payload, offset),
        3 => try decodeExtensionPanelKeyValue(alloc, payload, offset),
        4 => try alloc.dupe(u8, "-----"),
        5 => try decodeExtensionPanelProgress(alloc, payload, offset),
        6 => try decodeExtensionPanelTree(alloc, payload, offset),
        255 => try alloc.dupe(u8, ""),
        else => try alloc.dupe(u8, ""),
    };
}

fn decodeExtensionPanelStyledText(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error![]u8 {
    if (payload.len < offset.* + 1) return error.Malformed;
    const count: usize = payload[offset.*];
    offset.* += 1;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const run = try readString16(payload, offset);
        try text.appendSlice(alloc, run);
        if (payload.len < offset.* + 5) return error.Malformed;
        offset.* += 5;
    }
    return try text.toOwnedSlice(alloc);
}

fn decodeExtensionPanelTable(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error![]u8 {
    if (payload.len < offset.* + 5) return error.Malformed;
    const cols: usize = payload[offset.*];
    const rows: usize = std.mem.readInt(u16, payload[offset.* + 1 ..][0..2], .big);
    offset.* += 5;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var col_index: usize = 0;
    while (col_index < cols) : (col_index += 1) {
        if (col_index > 0) try text.appendSlice(alloc, "  ");
        try text.appendSlice(alloc, try readString16(payload, offset));
    }

    var cell_index: usize = 0;
    while (cell_index < rows * cols) : (cell_index += 1) {
        _ = try readString16(payload, offset);
    }

    return try text.toOwnedSlice(alloc);
}

fn decodeExtensionPanelKeyValue(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error![]u8 {
    if (payload.len < offset.* + 1) return error.Malformed;
    const count: usize = payload[offset.*];
    offset.* += 1;

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index > 0) try text.appendSlice(alloc, "  ");
        const key = try readString16(payload, offset);
        const value = try readString16(payload, offset);
        try text.appendSlice(alloc, key);
        try text.appendSlice(alloc, ": ");
        try text.appendSlice(alloc, value);
    }
    return try text.toOwnedSlice(alloc);
}

fn decodeExtensionPanelProgress(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error![]u8 {
    const label = try readString16(payload, offset);
    if (payload.len < offset.* + 2) return error.Malformed;
    const percent = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    return try std.fmt.allocPrint(alloc, "{s} {d}%", .{ label, percent });
}

fn decodeExtensionPanelTree(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error![]u8 {
    if (payload.len < offset.* + 2) return error.Malformed;
    const size: usize = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    if (payload.len < offset.* + size) return error.Malformed;
    offset.* += size;
    return try alloc.dupe(u8, "tree");
}

/// Decodes a `gui_observatory` packet into owned observatory rows.
pub fn decodeObservatory(alloc: std.mem.Allocator, packet: []const u8) Error!Observatory {
    if (packet.len < 5 or packet[0] != protocol.OP_GUI_OBSERVATORY) return error.Malformed;
    const payload_len: usize = readU32(packet[1..5]);
    if (packet.len < 5 + payload_len) return error.Malformed;
    const payload = packet[5 .. 5 + payload_len];

    var observatory = Observatory{};
    errdefer observatory.deinit(alloc);
    var offset: usize = 0;
    while (offset < payload.len) {
        if (payload.len < offset + 3) return error.Malformed;
        const section_id = payload[offset];
        const section_len: usize = std.mem.readInt(u16, payload[offset + 1 ..][0..2], .big);
        offset += 3;
        if (payload.len < offset + section_len) return error.Malformed;
        const section = payload[offset .. offset + section_len];
        offset += section_len;
        switch (section_id) {
            0x01 => {
                if (section.len < 3) return error.Malformed;
                observatory.visible = section[0] != 0;
                observatory.count = std.mem.readInt(u16, section[1..][0..2], .big);
            },
            0x02 => {
                try decodeObservatoryNodes(alloc, section, &observatory);
            },
            else => {},
        }
    }

    return observatory;
}

fn decodeObservatoryNodes(alloc: std.mem.Allocator, section: []const u8, observatory: *Observatory) Error!void {
    var nodes: std.ArrayList(ObservatoryNode) = .empty;
    errdefer {
        for (nodes.items) |*node| node.deinit(alloc);
        nodes.deinit(alloc);
    }

    var offset: usize = 0;
    while (offset < section.len) {
        const pid = try readString8(section, &offset);
        _ = try readString8(section, &offset);
        const name = try readString16(section, &offset);
        if (section.len < offset + 12) return error.Malformed;
        const process_class = section[offset];
        const depth = section[offset + 1];
        const memory = readU32(section[offset + 2 .. offset + 6]);
        const message_queue_len = std.mem.readInt(u16, section[offset + 6 ..][0..2], .big);
        const reductions = readU32(section[offset + 8 .. offset + 12]);
        offset += 12;

        var node = ObservatoryNode{
            .pid = try alloc.dupe(u8, pid),
            .name = &.{},
            .process_class = process_class,
            .depth = depth,
            .memory = memory,
            .message_queue_len = message_queue_len,
            .reductions = reductions,
        };
        errdefer node.deinit(alloc);
        node.name = try alloc.dupe(u8, name);
        try nodes.append(alloc, node);
    }

    for (observatory.nodes) |*node| node.deinit(alloc);
    alloc.free(observatory.nodes);
    observatory.nodes = try nodes.toOwnedSlice(alloc);
}

/// Decodes a `gui_agent_context` packet into owned footer state.
pub fn decodeAgentContext(alloc: std.mem.Allocator, packet: []const u8) Error!AgentContext {
    if (packet.len < 14 or packet[0] != protocol.OP_GUI_AGENT_CONTEXT) return error.Malformed;
    const task_len: usize = std.mem.readInt(u16, packet[2..][0..2], .big);
    const body_offset = 4 + task_len;
    if (packet.len < body_offset + 10) return error.Malformed;
    const task = packet[4..body_offset];

    return .{
        .visible = packet[1] != 0,
        .task = try alloc.dupe(u8, task),
        .timestamp = readU64(packet[body_offset .. body_offset + 8]),
        .status = packet[body_offset + 8],
        .can_approve = packet[body_offset + 9] != 0,
    };
}

/// Decodes a `gui_tool_manager` packet into owned footer state.
pub fn decodeToolManager(alloc: std.mem.Allocator, packet: []const u8) Error!ToolManager {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_TOOL_MANAGER) return error.Malformed;
    if (packet[1] == 0) return .{};
    if (packet.len < 7) return error.Malformed;

    const count = std.mem.readInt(u16, packet[5..][0..2], .big);
    var manager = ToolManager{
        .visible = true,
        .filter = packet[2],
        .selected = std.mem.readInt(u16, packet[3..][0..2], .big),
        .tools = try alloc.alloc(ToolSummary, count),
    };
    @memset(manager.tools, .{});
    errdefer manager.deinit(alloc);

    var offset: usize = 7;
    var index: usize = 0;
    while (index < manager.tools.len) : (index += 1) {
        manager.tools[index] = try decodeToolSummary(alloc, packet, &offset);
    }

    return manager;
}

fn decodeToolSummary(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!ToolSummary {
    const name = try readString8(packet, offset);
    const label = try readString8(packet, offset);
    _ = try readString16(packet, offset);
    if (packet.len < offset.* + 4) return error.Malformed;
    const status = packet[offset.* + 1];
    const language_count = packet[offset.* + 3];
    offset.* += 4;

    var language_index: u8 = 0;
    while (language_index < language_count) : (language_index += 1) {
        _ = try readString8(packet, offset);
    }
    _ = try readString8(packet, offset);
    _ = try readString16(packet, offset);
    if (packet.len < offset.* + 1) return error.Malformed;
    const provides_count = packet[offset.*];
    offset.* += 1;
    var provides_index: u8 = 0;
    while (provides_index < provides_count) : (provides_index += 1) {
        _ = try readString8(packet, offset);
    }
    _ = try readString16(packet, offset);

    return .{
        .name = try alloc.dupe(u8, name),
        .label = try alloc.dupe(u8, label),
        .status = status,
    };
}

/// Decodes a legacy `gui_cursorline` packet.
pub fn decodeCursorline(packet: []const u8) Error!Cursorline {
    if (packet.len < 6 or packet[0] != protocol.OP_GUI_CURSORLINE) return error.Malformed;
    return .{
        .row = std.mem.readInt(u16, packet[1..][0..2], .big),
        .bg = readU24(packet[3..6]),
    };
}

/// Decodes a legacy `gui_gutter_sep` packet.
pub fn decodeGutterSeparator(packet: []const u8) Error!GutterSeparator {
    if (packet.len < 6 or packet[0] != protocol.OP_GUI_GUTTER_SEP) return error.Malformed;
    return .{
        .col = std.mem.readInt(u16, packet[1..][0..2], .big),
        .color = readU24(packet[3..6]),
    };
}

/// Decodes a `gui_line_spacing` packet.
pub fn decodeLineSpacing(packet: []const u8) Error!LineSpacing {
    if (packet.len < 5 or packet[0] != protocol.OP_GUI_LINE_SPACING) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (payload_len < 2 or packet.len < 3 + payload_len) return error.Malformed;
    return .{ .value = std.mem.readInt(u16, packet[3..][0..2], .big) };
}

/// Decodes a `gui_cursor_animation` packet.
pub fn decodeCursorAnimation(packet: []const u8) Error!CursorAnimation {
    if (packet.len < 4 or packet[0] != protocol.OP_GUI_CURSOR_ANIMATION) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (payload_len < 1 or packet.len < 3 + payload_len) return error.Malformed;
    return .{ .enabled = packet[3] != 0 };
}

/// Decodes a `gui_config_state` packet into owned payload bytes.
pub fn decodeConfigState(alloc: std.mem.Allocator, packet: []const u8) Error!ConfigState {
    if (packet.len < 3 or packet[0] != protocol.OP_GUI_CONFIG_STATE) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (packet.len < 3 + payload_len) return error.Malformed;
    return .{ .payload = try alloc.dupe(u8, packet[3 .. 3 + payload_len]) };
}

/// Decodes a `gui_hover_action` packet into owned payload bytes.
pub fn decodeHoverAction(alloc: std.mem.Allocator, packet: []const u8) Error!HoverAction {
    if (packet.len < 3 or packet[0] != protocol.OP_GUI_HOVER_ACTION) return error.Malformed;
    const payload_len: usize = std.mem.readInt(u16, packet[1..][0..2], .big);
    if (packet.len < 3 + payload_len) return error.Malformed;
    const payload = packet[3 .. 3 + payload_len];
    var action = HoverAction{
        .payload = try alloc.dupe(u8, payload),
    };
    errdefer action.deinit(alloc);
    if (payload.len > 0 and payload[0] != 0) {
        action.visible = true;
        if (payload.len > 2) {
            var offset: usize = 1;
            const name = readString16(payload, &offset) catch &.{};
            action.name = try alloc.dupe(u8, name);
        }
    }
    return action;
}

/// Decodes a `gui_board` packet into owned board summary state.
pub fn decodeBoard(alloc: std.mem.Allocator, packet: []const u8) Error!Board {
    if (packet.len < 11 or packet[0] != protocol.OP_GUI_BOARD) return error.Malformed;

    const count = std.mem.readInt(u16, packet[6..][0..2], .big);
    var offset: usize = 9;
    const filter_text = try readString16(packet, &offset);

    var board = Board{
        .visible = packet[1] != 0,
        .focused_card_id = readU32(packet[2..6]),
        .card_count = count,
        .filter_mode = packet[8],
        .filter_text = try alloc.dupe(u8, filter_text),
        .cards = try alloc.alloc(BoardCard, count),
    };
    @memset(board.cards, .{});
    errdefer board.deinit(alloc);

    var index: usize = 0;
    while (index < board.cards.len) : (index += 1) {
        board.cards[index] = try decodeBoardCard(alloc, packet, &offset);
    }

    return board;
}

fn decodeBoardCard(alloc: std.mem.Allocator, packet: []const u8, offset: *usize) Error!BoardCard {
    if (packet.len < offset.* + 6) return error.Malformed;
    const id = readU32(packet[offset.* .. offset.* + 4]);
    const status = packet[offset.* + 4];
    const flags = packet[offset.* + 5];
    offset.* += 6;
    const task = try readString16(packet, offset);
    const model = try readString8(packet, offset);
    if (packet.len < offset.* + 5) return error.Malformed;
    const timestamp = readU32(packet[offset.* .. offset.* + 4]);
    offset.* += 4;
    const recent_count = packet[offset.*];
    offset.* += 1;
    var recent_files = try alloc.alloc([]u8, recent_count);
    @memset(recent_files, &.{});
    errdefer {
        for (recent_files) |file| alloc.free(file);
        alloc.free(recent_files);
    }
    var recent_index: u8 = 0;
    while (recent_index < recent_count) : (recent_index += 1) {
        const file = try readString16(packet, offset);
        recent_files[recent_index] = try alloc.dupe(u8, file);
    }
    if (packet.len < offset.* + 1) return error.Malformed;
    const sparkline_count = packet[offset.*];
    offset.* += 1;
    if (packet.len < offset.* + @as(usize, sparkline_count) * 2) return error.Malformed;
    offset.* += @as(usize, sparkline_count) * 2;

    return .{
        .id = id,
        .status = status,
        .flags = flags,
        .task = try alloc.dupe(u8, task),
        .model = try alloc.dupe(u8, model),
        .timestamp = timestamp,
        .recent_files = recent_files,
    };
}

/// Decodes a `gui_agent_chat` packet into owned chat summary state.
pub fn decodeAgentChat(alloc: std.mem.Allocator, packet: []const u8) Error!AgentChat {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_AGENT_CHAT) return error.Malformed;

    var chat = AgentChat{};
    errdefer chat.deinit(alloc);

    var offset: usize = 2;
    var section_index: u8 = 0;
    while (section_index < packet[1]) : (section_index += 1) {
        if (packet.len < offset + 3) return error.Malformed;
        const section_id = packet[offset];
        const section_len: usize = std.mem.readInt(u16, packet[offset + 1 ..][0..2], .big);
        offset += 3;
        if (packet.len < offset + section_len) return error.Malformed;
        const payload = packet[offset .. offset + section_len];
        offset += section_len;

        switch (section_id) {
            0x01 => {
                if (payload.len < 2) return error.Malformed;
                chat.visible = payload[0] != 0;
                chat.status = payload[1];
            },
            0x02 => try replaceString16(alloc, payload, 0, &chat.model_name),
            0x03 => try decodeAgentChatPrompt(alloc, payload, &chat),
            0x04 => try decodeAgentChatPending(alloc, payload, &chat),
            0x06 => try decodeAgentChatMessages(alloc, payload, &chat),
            0x07 => try decodeAgentChatCompletion(alloc, payload, &chat),
            0x08 => try replaceString16(alloc, payload, 0, &chat.thinking_level),
            else => {},
        }
    }

    return chat;
}

fn decodeAgentChatPending(alloc: std.mem.Allocator, payload: []const u8, chat: *AgentChat) Error!void {
    if (payload.len == 0 or payload[0] == 0) return;
    var offset: usize = 1;
    const name = try readString16(payload, &offset);
    const summary = try readString16(payload, &offset);
    const pending = try std.fmt.allocPrint(alloc, "{s} {s}", .{ name, summary });
    alloc.free(chat.pending);
    chat.pending = pending;
}

fn decodeAgentChatPrompt(alloc: std.mem.Allocator, payload: []const u8, chat: *AgentChat) Error!void {
    var offset: usize = 0;
    const prompt = try readString16(payload, &offset);
    const owned_prompt = try alloc.dupe(u8, prompt);
    alloc.free(chat.prompt);
    chat.prompt = owned_prompt;
    if (payload.len >= offset + 7) {
        chat.prompt_line_count = payload[offset];
        chat.prompt_cursor_line = std.mem.readInt(u16, payload[offset + 1 ..][0..2], .big);
        chat.prompt_cursor_col = std.mem.readInt(u16, payload[offset + 3 ..][0..2], .big);
        chat.prompt_vim_mode = payload[offset + 5];
        chat.prompt_visible_rows = payload[offset + 6];
    }
}

fn decodeAgentChatCompletion(alloc: std.mem.Allocator, payload: []const u8, chat: *AgentChat) Error!void {
    if (payload.len < 8 or payload[0] == 0) return;
    const count: usize = payload[7];
    var offset: usize = 8;

    var items = try alloc.alloc([]u8, count);
    @memset(items, &.{});
    errdefer {
        for (items) |item| alloc.free(item);
        alloc.free(items);
    }

    var index: usize = 0;
    while (index < items.len and offset < payload.len) : (index += 1) {
        const name = try readString16(payload, &offset);
        const desc = try readString16(payload, &offset);
        items[index] = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ name, if (name.len > 0 and desc.len > 0) " " else "", desc });
    }

    for (chat.completion) |item| alloc.free(item);
    alloc.free(chat.completion);
    chat.completion = items;
}

fn decodeAgentChatMessages(alloc: std.mem.Allocator, payload: []const u8, chat: *AgentChat) Error!void {
    if (payload.len >= 4 and payload[0] == 0xFF) {
        chat.message_count = std.mem.readInt(u16, payload[2..][0..2], .big);
    }
    if (payload.len < 4 or payload[0] != 0xFF) return;

    var messages: std.ArrayList(AgentChatMessage) = .empty;
    errdefer {
        for (messages.items) |*message| message.deinit(alloc);
        messages.deinit(alloc);
    }

    const count: usize = std.mem.readInt(u16, payload[2..][0..2], .big);
    var offset: usize = 4;
    var index: usize = 0;
    while (index < count and offset < payload.len) : (index += 1) {
        if (payload.len < offset + 4) return error.Malformed;
        const message_len: usize = readU32(payload[offset .. offset + 4]);
        offset += 4;
        if (payload.len < offset + message_len) return error.Malformed;
        var message = try decodeAgentChatMessage(alloc, payload[offset .. offset + message_len]);
        errdefer message.deinit(alloc);
        try messages.append(alloc, message);
        offset += message_len;
    }

    for (chat.messages) |*message| message.deinit(alloc);
    alloc.free(chat.messages);
    chat.messages = try messages.toOwnedSlice(alloc);
}

pub fn decodeAgentChatMessage(alloc: std.mem.Allocator, body: []const u8) Error!AgentChatMessage {
    if (body.len < 5) return error.Malformed;

    var message = AgentChatMessage{
        .id = readU32(body[0..4]),
        .kind = body[4],
    };
    errdefer message.deinit(alloc);

    var offset: usize = 5;
    switch (message.kind) {
        0x01, 0x02 => {
            message.text = try decodeAgentChatTextBytes(alloc, body, &offset);
        },
        0x03 => {
            if (body.len < offset + 5) return error.Malformed;
            message.collapsed = body[offset] != 0;
            offset += 1;
            message.text = try decodeAgentChatTextBytes(alloc, body, &offset);
        },
        0x04, 0x08 => {
            if (body.len < offset + 7) return error.Malformed;
            message.status = body[offset];
            message.is_error = body[offset + 1] != 0;
            message.collapsed = body[offset + 2] != 0;
            message.duration_ms = readU32(body[offset + 3 .. offset + 7]);
            offset += 7;
            try decodeAgentChatNameSummary(alloc, body, &offset, &message);
            if (message.kind == 0x04) {
                message.result = try decodeAgentChatTextBytes(alloc, body, &offset);
                if (body.len > offset) message.auto_approved_scope = body[offset];
            } else {
                message.result = try decodeAgentChatStyledPlainText(alloc, body, &offset);
                if (body.len > offset) message.auto_approved_scope = body[offset];
            }
        },
        0x05 => {
            if (body.len < offset + 5) return error.Malformed;
            message.status = body[offset];
            offset += 1;
            message.text = try decodeAgentChatTextBytes(alloc, body, &offset);
        },
        0x06 => {
            if (body.len < offset + 20) return error.Malformed;
            const input = readU32(body[offset .. offset + 4]);
            const output = readU32(body[offset + 4 .. offset + 8]);
            message.usage_input = input;
            message.usage_output = output;
            message.usage_cache_read = readU32(body[offset + 8 .. offset + 12]);
            message.usage_cache_write = readU32(body[offset + 12 .. offset + 16]);
            message.usage_cost_micros = readU32(body[offset + 16 .. offset + 20]);
            message.text = try std.fmt.allocPrint(alloc, "usage in:{d} out:{d}", .{ input, output });
        },
        0x07 => {
            message.text = try decodeAgentChatStyledPlainText(alloc, body, &offset);
        },
        0x09 => {
            if (body.len < offset + 1) return error.Malformed;
            message.status = body[offset];
            offset += 1;
            try decodeAgentChatNameSummary(alloc, body, &offset, &message);
            if (body.len >= offset + 2) {
                const tool_call_id = try readString16(body, &offset);
                if (tool_call_id.len > 0) message.result = try alloc.dupe(u8, tool_call_id);
            }
            if (body.len >= offset + 3) {
                message.preview_kind = body[offset];
                const line_count = std.mem.readInt(u16, body[offset + 1 ..][0..2], .big);
                offset += 3;
                message.preview_lines = try alloc.alloc([]u8, line_count);
                @memset(message.preview_lines, &.{});
                errdefer {
                    for (message.preview_lines) |line| alloc.free(line);
                    alloc.free(message.preview_lines);
                    message.preview_lines = &.{};
                }
                var line_index: usize = 0;
                while (line_index < message.preview_lines.len and body.len >= offset + 2) : (line_index += 1) {
                    const line = try readString16(body, &offset);
                    message.preview_lines[line_index] = try alloc.dupe(u8, line);
                }
            }
        },
        else => {},
    }

    return message;
}

fn decodeAgentChatTextBytes(alloc: std.mem.Allocator, body: []const u8, offset: *usize) Error![]u8 {
    if (body.len < offset.* + 4) return error.Malformed;
    const len: usize = readU32(body[offset.* .. offset.* + 4]);
    offset.* += 4;
    if (body.len < offset.* + len) return error.Malformed;
    const text = try alloc.dupe(u8, body[offset.* .. offset.* + len]);
    offset.* += len;
    return text;
}

fn decodeAgentChatStyledPlainText(alloc: std.mem.Allocator, body: []const u8, offset: *usize) Error![]u8 {
    if (body.len < offset.* + 2) return error.Malformed;
    const line_count = std.mem.readInt(u16, body[offset.*..][0..2], .big);
    offset.* += 2;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var line_index: usize = 0;
    while (line_index < line_count) : (line_index += 1) {
        if (body.len < offset.* + 2) return error.Malformed;
        const run_count = std.mem.readInt(u16, body[offset.*..][0..2], .big);
        offset.* += 2;
        if (line_index > 0) try out.append(alloc, ' ');

        var run_index: usize = 0;
        while (run_index < run_count) : (run_index += 1) {
            const text = try readString16(body, offset);
            if (body.len < offset.* + 7) return error.Malformed;
            offset.* += 7;
            if (body[offset.* - 1] & 0x08 != 0) {
                _ = try readString16(body, offset);
            }
            try out.appendSlice(alloc, text);
        }
    }

    return out.toOwnedSlice(alloc);
}

fn decodeAgentChatNameSummary(alloc: std.mem.Allocator, body: []const u8, offset: *usize, message: *AgentChatMessage) Error!void {
    const name = try readString16(body, offset);
    const summary = try readString16(body, offset);
    message.name = try alloc.dupe(u8, name);
    errdefer {
        alloc.free(message.name);
        message.name = &.{};
    }
    message.summary = try alloc.dupe(u8, summary);
    errdefer {
        alloc.free(message.summary);
        message.summary = &.{};
    }
    message.text = try std.fmt.allocPrint(alloc, "{s} {s}", .{ message.name, message.summary });
}

/// Decodes a `gui_status_bar` packet into owned status state.
pub fn decodeStatusBar(alloc: std.mem.Allocator, packet: []const u8) Error!StatusBar {
    if (packet.len < 2 or packet[0] != protocol.OP_GUI_STATUS_BAR) return error.Malformed;

    var status = StatusBar{};
    errdefer status.deinit(alloc);

    var offset: usize = 2;
    var section_index: u8 = 0;
    while (section_index < packet[1]) : (section_index += 1) {
        if (packet.len < offset + 3) return error.Malformed;
        const section_id = packet[offset];
        const section_len: usize = std.mem.readInt(u16, packet[offset + 1 ..][0..2], .big);
        offset += 3;
        if (packet.len < offset + section_len) return error.Malformed;
        const payload = packet[offset .. offset + section_len];
        offset += section_len;

        switch (section_id) {
            0x01 => decodeStatusIdentity(payload, &status),
            0x02 => decodeStatusCursor(payload, &status),
            0x05 => try decodeStatusGit(alloc, payload, &status),
            0x06 => try decodeStatusFile(alloc, payload, &status),
            0x07 => try replaceString16(alloc, payload, 0, &status.message),
            0x0B => try decodeStatusModeline(alloc, payload, &status),
            else => {},
        }
    }

    return status;
}

fn decodeStatusIdentity(payload: []const u8, status: *StatusBar) void {
    if (payload.len < 3) return;
    status.content_kind = payload[0];
    status.mode = payload[1];
    status.flags = payload[2];
}

fn decodeStatusCursor(payload: []const u8, status: *StatusBar) void {
    if (payload.len < 12) return;
    status.line = std.mem.readInt(u32, payload[0..][0..4], .big);
    status.col = std.mem.readInt(u32, payload[4..][0..4], .big);
    status.line_count = std.mem.readInt(u32, payload[8..][0..4], .big);
}

fn decodeStatusGit(alloc: std.mem.Allocator, payload: []const u8, status: *StatusBar) Error!void {
    var offset: usize = 0;
    const branch = try readString8(payload, &offset);
    try replaceOwned(alloc, branch, &status.branch);
}

fn decodeStatusFile(alloc: std.mem.Allocator, payload: []const u8, status: *StatusBar) Error!void {
    var offset: usize = 0;
    const icon = try readString8(payload, &offset);
    if (payload.len < offset + 3) return error.Malformed;
    offset += 3;
    const filename = try readString16(payload, &offset);
    const filetype = try readString8(payload, &offset);
    try replaceOwned(alloc, icon, &status.icon);
    try replaceOwned(alloc, filename, &status.filename);
    try replaceOwned(alloc, filetype, &status.filetype);
}

fn decodeStatusModeline(alloc: std.mem.Allocator, payload: []const u8, status: *StatusBar) Error!void {
    if (payload.len < 5) return error.Malformed;
    var offset: usize = 1;
    const left_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;
    const right_count = std.mem.readInt(u16, payload[offset..][0..2], .big);
    offset += 2;

    const left = try decodeStatusSegmentList(alloc, payload, &offset, left_count);
    errdefer deinitSegments(alloc, left);
    const right = try decodeStatusSegmentList(alloc, payload, &offset, right_count);
    errdefer deinitSegments(alloc, right);

    for (status.left_segments) |*segment| segment.deinit(alloc);
    for (status.right_segments) |*segment| segment.deinit(alloc);
    alloc.free(status.left_segments);
    alloc.free(status.right_segments);
    status.left_segments = left;
    status.right_segments = right;
}

fn decodeStatusSegmentList(
    alloc: std.mem.Allocator,
    payload: []const u8,
    offset: *usize,
    count: u16,
) Error![]StatusSegment {
    const segments = try alloc.alloc(StatusSegment, count);
    errdefer alloc.free(segments);

    var index: usize = 0;
    errdefer {
        for (segments[0..index]) |*segment| segment.deinit(alloc);
    }

    while (index < count) : (index += 1) {
        segments[index] = try decodeStatusSegment(alloc, payload, offset);
    }

    return segments;
}

fn decodeStatusSegment(alloc: std.mem.Allocator, payload: []const u8, offset: *usize) Error!StatusSegment {
    const name = try readString8(payload, offset);
    if (payload.len < offset.* + 7) return error.Malformed;
    const fg = readU24(payload[offset.* .. offset.* + 3]);
    offset.* += 3;
    const bg = readU24(payload[offset.* .. offset.* + 3]);
    offset.* += 3;
    const attrs = payload[offset.*];
    offset.* += 1;
    const text = try readString16(payload, offset);
    const command = try readString16(payload, offset);

    return .{
        .name = try alloc.dupe(u8, name),
        .text = try alloc.dupe(u8, text),
        .command = try alloc.dupe(u8, command),
        .fg = fg,
        .bg = bg,
        .attrs = attrs,
    };
}

fn deinitSegments(alloc: std.mem.Allocator, segments: []StatusSegment) void {
    for (segments) |*segment| segment.deinit(alloc);
    alloc.free(segments);
}

fn replaceString16(alloc: std.mem.Allocator, payload: []const u8, start: usize, dest: *[]u8) Error!void {
    var offset = start;
    const value = try readString16(payload, &offset);
    try replaceOwned(alloc, value, dest);
}

pub fn replaceOwned(alloc: std.mem.Allocator, value: []const u8, dest: *[]u8) std.mem.Allocator.Error!void {
    const owned = try alloc.dupe(u8, value);
    alloc.free(dest.*);
    dest.* = owned;
}

fn readString8(payload: []const u8, offset: *usize) Error![]const u8 {
    if (payload.len < offset.* + 1) return error.Malformed;
    const len: usize = payload[offset.*];
    offset.* += 1;
    if (payload.len < offset.* + len) return error.Malformed;
    const value = payload[offset.* .. offset.* + len];
    offset.* += len;
    return value;
}

fn readString16(payload: []const u8, offset: *usize) Error![]const u8 {
    if (payload.len < offset.* + 2) return error.Malformed;
    const len: usize = std.mem.readInt(u16, payload[offset.*..][0..2], .big);
    offset.* += 2;
    if (payload.len < offset.* + len) return error.Malformed;
    const value = payload[offset.* .. offset.* + len];
    offset.* += len;
    return value;
}

fn readU24(bytes: []const u8) u24 {
    return (@as(u24, @intCast(bytes[0])) << 16) |
        (@as(u24, @intCast(bytes[1])) << 8) |
        @as(u24, @intCast(bytes[2]));
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..][0..4], .big);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..][0..8], .big);
}
