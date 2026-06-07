/// Semantic TUI state and rendering.
///
/// This module is the Zig counterpart to the Go/Rust semantic TUI state loops.
/// It decodes retained GUI semantic commands into owned state, then renders
/// terminal cells from that state through the existing libvaxis surface path.
const std = @import("std");
const vaxis = @import("vaxis");
const protocol = @import("protocol.zig");
const surface_mod = @import("surface.zig");

const types = @import("semantic/types.zig");
const charm = @import("semantic/charm.zig");
const theme_mod = @import("semantic/theme.zig");
const decode = @import("semantic/decode.zig");

pub const Error = types.Error;
pub const StatusSegment = types.StatusSegment;
pub const Tab = types.Tab;
pub const TabBar = types.TabBar;
pub const MinibufferCandidate = types.MinibufferCandidate;
pub const Minibuffer = types.Minibuffer;
pub const WhichKeyBinding = types.WhichKeyBinding;
pub const WhichKey = types.WhichKey;
pub const CompletionItem = types.CompletionItem;
pub const Completion = types.Completion;
pub const Breadcrumb = types.Breadcrumb;
pub const PickerItem = types.PickerItem;
pub const Picker = types.Picker;
pub const PreviewSegment = types.PreviewSegment;
pub const PreviewLine = types.PreviewLine;
pub const PickerPreview = types.PickerPreview;
pub const HoverSegment = types.HoverSegment;
pub const HoverLine = types.HoverLine;
pub const HoverPopup = types.HoverPopup;
pub const SignatureParameter = types.SignatureParameter;
pub const Signature = types.Signature;
pub const SignatureHelp = types.SignatureHelp;
pub const FloatPopup = types.FloatPopup;
pub const GitStatusEntry = types.GitStatusEntry;
pub const GitToast = types.GitToast;
pub const GitStatus = types.GitStatus;
pub const BottomPanelTab = types.BottomPanelTab;
pub const BottomPanelEntry = types.BottomPanelEntry;
pub const BottomPanel = types.BottomPanel;
pub const VerticalSeparator = types.VerticalSeparator;
pub const HorizontalSeparator = types.HorizontalSeparator;
pub const SplitSeparators = types.SplitSeparators;
pub const WindowSpan = types.WindowSpan;
pub const RenderStyle = types.RenderStyle;
pub const WindowRow = types.WindowRow;
pub const WindowRowsDelta = types.WindowRowsDelta;
pub const WindowSelection = types.WindowSelection;
pub const SearchMatch = types.SearchMatch;
pub const DiagnosticRange = types.DiagnosticRange;
pub const DocumentHighlight = types.DocumentHighlight;
pub const LineAnnotation = types.LineAnnotation;
pub const WindowOverlayDelta = types.WindowOverlayDelta;
pub const FileTreeRow = types.FileTreeRow;
pub const FileTree = types.FileTree;
pub const FileTreeSelection = types.FileTreeSelection;
pub const Sidebar = types.Sidebar;
pub const Sidebars = types.Sidebars;
pub const GutterEntry = types.GutterEntry;
pub const Gutter = types.Gutter;
pub const IndentGuides = types.IndentGuides;
pub const ThemeSlot = types.ThemeSlot;
pub const Theme = types.Theme;
pub const Workspace = types.Workspace;
pub const WorkspaceTab = types.WorkspaceTab;
pub const Workspaces = types.Workspaces;
pub const SearchState = types.SearchState;
pub const ChangeSummaryEntry = types.ChangeSummaryEntry;
pub const ChangeSummary = types.ChangeSummary;
pub const NotificationAction = types.NotificationAction;
pub const NotificationItem = types.NotificationItem;
pub const Notifications = types.Notifications;
pub const TimelineEntry = types.TimelineEntry;
pub const EditTimeline = types.EditTimeline;
pub const ExtensionOverlay = types.ExtensionOverlay;
pub const ExtensionOverlayEntry = types.ExtensionOverlayEntry;
pub const ExtensionPanel = types.ExtensionPanel;
pub const ExtensionPanelEntry = types.ExtensionPanelEntry;
pub const Observatory = types.Observatory;
pub const ObservatoryNode = types.ObservatoryNode;
pub const AgentContext = types.AgentContext;
pub const ToolSummary = types.ToolSummary;
pub const ToolManager = types.ToolManager;
pub const Cursorline = types.Cursorline;
pub const GutterSeparator = types.GutterSeparator;
pub const LineSpacing = types.LineSpacing;
pub const CursorAnimation = types.CursorAnimation;
pub const ConfigState = types.ConfigState;
pub const HoverAction = types.HoverAction;
pub const BoardCard = types.BoardCard;
pub const Board = types.Board;
pub const AgentChat = types.AgentChat;
pub const AgentChatMessage = types.AgentChatMessage;
pub const WindowContent = types.WindowContent;
pub const StatusBar = types.StatusBar;

const clearRow = charm.clearRow;
const clearRowRange = charm.clearRowRange;
const fillRowRangeWith = charm.fillRowRangeWith;
const textWidth = charm.textWidth;
const writeAsciiStableText = charm.writeAsciiStableText;
const writeAsciiText = charm.writeAsciiText;
const writeText = charm.writeText;

pub const HitAction = union(enum) {
    no_payload: u8,
    u16_payload: struct { action: u8, value: u16 },
    u32_payload: struct { action: u8, value: u32 },
    fold_toggle: struct { window_id: u16, buffer_line: u32 },
};

const theme_editor_bg = theme_mod.theme_editor_bg;
const theme_editor_fg = theme_mod.theme_editor_fg;
const theme_tree_bg = theme_mod.theme_tree_bg;
const theme_tree_fg = theme_mod.theme_tree_fg;
const theme_tree_selection_bg = theme_mod.theme_tree_selection_bg;
const theme_tree_dir_fg = theme_mod.theme_tree_dir_fg;
const theme_tree_selection_fg = theme_mod.theme_tree_selection_fg;
const theme_tab_bg = theme_mod.theme_tab_bg;
const theme_tab_active_bg = theme_mod.theme_tab_active_bg;
const theme_tab_active_fg = theme_mod.theme_tab_active_fg;
const theme_tab_inactive_fg = theme_mod.theme_tab_inactive_fg;
const theme_tab_modified_fg = theme_mod.theme_tab_modified_fg;
const theme_tab_attention_fg = theme_mod.theme_tab_attention_fg;
const theme_popup_bg = theme_mod.theme_popup_bg;
const theme_popup_fg = theme_mod.theme_popup_fg;
const theme_popup_selection_bg = theme_mod.theme_popup_selection_bg;
const theme_breadcrumb_bg = theme_mod.theme_breadcrumb_bg;
const theme_popup_selection_fg = theme_mod.theme_popup_selection_fg;
const theme_modeline_bar_bg = theme_mod.theme_modeline_bar_bg;
const theme_modeline_bar_fg = theme_mod.theme_modeline_bar_fg;
const theme_accent = theme_mod.theme_accent;
const theme_popup_desc_fg = theme_mod.theme_popup_desc_fg;
const theme_gutter_fg = theme_mod.theme_gutter_fg;
const theme_gutter_current_fg = theme_mod.theme_gutter_current_fg;
const theme_gutter_error_fg = theme_mod.theme_gutter_error_fg;
const theme_gutter_warning_fg = theme_mod.theme_gutter_warning_fg;
const theme_gutter_info_fg = theme_mod.theme_gutter_info_fg;
const theme_gutter_hint_fg = theme_mod.theme_gutter_hint_fg;
const theme_highlight_read_bg = theme_mod.theme_highlight_read_bg;
const theme_highlight_write_bg = theme_mod.theme_highlight_write_bg;
const theme_selection_bg = theme_mod.theme_selection_bg;
const themeColor = theme_mod.themeColor;
const tabBg = theme_mod.tabBg;
const editorBg = theme_mod.editorBg;
const editorFg = theme_mod.editorFg;
const mutedFg = theme_mod.mutedFg;
const treeBg = theme_mod.treeBg;
const treeFg = theme_mod.treeFg;
const treeDirFg = theme_mod.treeDirFg;
const treeSelectionBg = theme_mod.treeSelectionBg;
const treeSelectionFg = theme_mod.treeSelectionFg;
const gutterFg = theme_mod.gutterFg;
const gutterCurrentFg = theme_mod.gutterCurrentFg;
const popupBg = theme_mod.popupBg;
const popupFg = theme_mod.popupFg;
const popupSelectionBg = theme_mod.popupSelectionBg;
const popupSelectionFg = theme_mod.popupSelectionFg;
const accentFg = theme_mod.accentFg;
const tabActiveBg = theme_mod.tabActiveBg;
const tabActiveFg = theme_mod.tabActiveFg;
const tabInactiveFg = theme_mod.tabInactiveFg;
const tabDirtyFg = theme_mod.tabDirtyFg;
const tabAttentionFg = theme_mod.tabAttentionFg;
const modelineBg = theme_mod.modelineBg;
const modelineFg = theme_mod.modelineFg;
const themedSegmentFg = theme_mod.themedSegmentFg;
const themedSegmentBg = theme_mod.themedSegmentBg;
const selectionBg = theme_mod.selectionBg;
const documentHighlightBg = theme_mod.documentHighlightBg;
const searchMatchBg = theme_mod.searchMatchBg;
const diagnosticColor = theme_mod.diagnosticColor;
const default_selection_bg = theme_mod.default_selection_bg;
const default_editor_bg = theme_mod.default_editor_bg;
const default_accent_fg = theme_mod.default_accent_fg;
const default_document_highlight_read_bg = theme_mod.default_document_highlight_read_bg;
const default_current_search_match_bg = theme_mod.default_current_search_match_bg;
const default_diagnostic_info_fg = theme_mod.default_diagnostic_info_fg;

pub const decodeTabBar = decode.decodeTabBar;
pub const decodeMinibuffer = decode.decodeMinibuffer;
pub const decodeWhichKey = decode.decodeWhichKey;
pub const decodeCompletion = decode.decodeCompletion;
pub const decodeBreadcrumb = decode.decodeBreadcrumb;
pub const decodePicker = decode.decodePicker;
pub const decodePickerPreview = decode.decodePickerPreview;
pub const decodeHoverPopup = decode.decodeHoverPopup;
pub const decodeSignatureHelp = decode.decodeSignatureHelp;
pub const decodeFloatPopup = decode.decodeFloatPopup;
pub const decodeGitStatus = decode.decodeGitStatus;
pub const decodeBottomPanel = decode.decodeBottomPanel;
pub const decodeSplitSeparators = decode.decodeSplitSeparators;
pub const decodeWindowContent = decode.decodeWindowContent;
pub const decodeFileTree = decode.decodeFileTree;
pub const decodeFileTreeSelection = decode.decodeFileTreeSelection;
pub const decodeSidebars = decode.decodeSidebars;
pub const decodeGutter = decode.decodeGutter;
pub const decodeIndentGuides = decode.decodeIndentGuides;
pub const decodeTheme = decode.decodeTheme;
pub const decodeWorkspaces = decode.decodeWorkspaces;
pub const decodeWindowOverlayDelta = decode.decodeWindowOverlayDelta;
pub const decodeWindowRowsDelta = decode.decodeWindowRowsDelta;
pub const decodeSearchState = decode.decodeSearchState;
pub const decodeChangeSummary = decode.decodeChangeSummary;
pub const decodeNotifications = decode.decodeNotifications;
pub const decodeEditTimeline = decode.decodeEditTimeline;
pub const decodeExtensionOverlay = decode.decodeExtensionOverlay;
pub const decodeExtensionPanel = decode.decodeExtensionPanel;
pub const decodeObservatory = decode.decodeObservatory;
pub const decodeAgentContext = decode.decodeAgentContext;
pub const decodeToolManager = decode.decodeToolManager;
pub const decodeCursorline = decode.decodeCursorline;
pub const decodeGutterSeparator = decode.decodeGutterSeparator;
pub const decodeLineSpacing = decode.decodeLineSpacing;
pub const decodeCursorAnimation = decode.decodeCursorAnimation;
pub const decodeConfigState = decode.decodeConfigState;
pub const decodeHoverAction = decode.decodeHoverAction;
pub const decodeBoard = decode.decodeBoard;
pub const decodeAgentChat = decode.decodeAgentChat;
pub const decodeStatusBar = decode.decodeStatusBar;
const applyWindowOverlaySections = decode.applyWindowOverlaySections;
const cloneRetainedWindowRow = decode.cloneRetainedWindowRow;
const cloneWindowRow = decode.cloneWindowRow;
const decodeAgentChatMessage = decode.decodeAgentChatMessage;
const decodeDiagnosticRanges = decode.decodeDiagnosticRanges;
const decodeDocumentHighlights = decode.decodeDocumentHighlights;
const decodeLineAnnotations = decode.decodeLineAnnotations;
const decodeSearchMatches = decode.decodeSearchMatches;
const decodeWindowSelection = decode.decodeWindowSelection;
const replaceOwned = decode.replaceOwned;

/// Retained semantic frontend state for the Zig TUI.
pub const State = struct {
    alloc: std.mem.Allocator,
    windows: []WindowContent = &.{},
    gutters: []Gutter = &.{},
    indent_guides: []IndentGuides = &.{},
    theme: ?Theme = null,
    workspaces: ?Workspaces = null,
    file_tree: ?FileTree = null,
    sidebars: ?Sidebars = null,
    tab_bar: ?TabBar = null,
    minibuffer: ?Minibuffer = null,
    which_key: ?WhichKey = null,
    completion: ?Completion = null,
    breadcrumb: ?Breadcrumb = null,
    picker: ?Picker = null,
    picker_preview: ?PickerPreview = null,
    hover_popup: ?HoverPopup = null,
    signature_help: ?SignatureHelp = null,
    float_popup: ?FloatPopup = null,
    git_status: ?GitStatus = null,
    bottom_panel: ?BottomPanel = null,
    split_separators: ?SplitSeparators = null,
    search_state: ?SearchState = null,
    change_summary: ?ChangeSummary = null,
    notifications: ?Notifications = null,
    edit_timeline: ?EditTimeline = null,
    extension_overlay: ?ExtensionOverlay = null,
    extension_panel: ?ExtensionPanel = null,
    observatory: ?Observatory = null,
    agent_context: ?AgentContext = null,
    tool_manager: ?ToolManager = null,
    cursorline: ?Cursorline = null,
    gutter_separator: ?GutterSeparator = null,
    line_spacing: ?LineSpacing = null,
    cursor_animation: ?CursorAnimation = null,
    config_state: ?ConfigState = null,
    hover_action: ?HoverAction = null,
    board: ?Board = null,
    agent_chat: ?AgentChat = null,
    status_bar: ?StatusBar = null,
    cursor_window_id: ?u16 = null,

    /// Creates empty semantic state.
    pub fn init(alloc: std.mem.Allocator) State {
        return .{ .alloc = alloc };
    }

    /// Releases all retained semantic state.
    pub fn deinit(self: *State) void {
        self.clear();
    }

    /// Clears retained semantic state, matching clear-frame behavior in Go/Rust.
    pub fn clear(self: *State) void {
        for (self.windows) |*window| window.deinit(self.alloc);
        self.alloc.free(self.windows);
        for (self.gutters) |*gutter| gutter.deinit(self.alloc);
        self.alloc.free(self.gutters);
        for (self.indent_guides) |*guides| guides.deinit(self.alloc);
        self.alloc.free(self.indent_guides);
        if (self.theme) |*theme| theme.deinit(self.alloc);
        if (self.workspaces) |*workspaces| workspaces.deinit(self.alloc);
        if (self.file_tree) |*tree| tree.deinit(self.alloc);
        if (self.sidebars) |*sidebars| sidebars.deinit(self.alloc);
        if (self.tab_bar) |*tabs| tabs.deinit(self.alloc);
        if (self.minibuffer) |*minibuffer| minibuffer.deinit(self.alloc);
        if (self.which_key) |*which_key| which_key.deinit(self.alloc);
        if (self.completion) |*completion| completion.deinit(self.alloc);
        if (self.breadcrumb) |*breadcrumb| breadcrumb.deinit(self.alloc);
        if (self.picker) |*picker| picker.deinit(self.alloc);
        if (self.picker_preview) |*preview| preview.deinit(self.alloc);
        if (self.hover_popup) |*hover| hover.deinit(self.alloc);
        if (self.signature_help) |*help| help.deinit(self.alloc);
        if (self.float_popup) |*popup| popup.deinit(self.alloc);
        if (self.git_status) |*git| git.deinit(self.alloc);
        if (self.bottom_panel) |*panel| panel.deinit(self.alloc);
        if (self.split_separators) |*separators| separators.deinit(self.alloc);
        if (self.change_summary) |*summary| summary.deinit(self.alloc);
        if (self.notifications) |*notifications| notifications.deinit(self.alloc);
        if (self.edit_timeline) |*timeline| timeline.deinit(self.alloc);
        if (self.extension_overlay) |*overlay| overlay.deinit(self.alloc);
        if (self.extension_panel) |*panel| panel.deinit(self.alloc);
        if (self.observatory) |*observatory| observatory.deinit(self.alloc);
        if (self.agent_context) |*context| context.deinit(self.alloc);
        if (self.tool_manager) |*manager| manager.deinit(self.alloc);
        if (self.config_state) |*config| config.deinit(self.alloc);
        if (self.hover_action) |*action| action.deinit(self.alloc);
        if (self.board) |*board| board.deinit(self.alloc);
        if (self.agent_chat) |*chat| chat.deinit(self.alloc);
        if (self.status_bar) |*status| status.deinit(self.alloc);
        self.windows = &.{};
        self.gutters = &.{};
        self.indent_guides = &.{};
        self.theme = null;
        self.workspaces = null;
        self.file_tree = null;
        self.sidebars = null;
        self.tab_bar = null;
        self.minibuffer = null;
        self.which_key = null;
        self.completion = null;
        self.breadcrumb = null;
        self.picker = null;
        self.picker_preview = null;
        self.hover_popup = null;
        self.signature_help = null;
        self.float_popup = null;
        self.git_status = null;
        self.bottom_panel = null;
        self.split_separators = null;
        self.search_state = null;
        self.change_summary = null;
        self.notifications = null;
        self.edit_timeline = null;
        self.extension_overlay = null;
        self.extension_panel = null;
        self.observatory = null;
        self.agent_context = null;
        self.tool_manager = null;
        self.cursorline = null;
        self.gutter_separator = null;
        self.line_spacing = null;
        self.cursor_animation = null;
        self.config_state = null;
        self.hover_action = null;
        self.board = null;
        self.agent_chat = null;
        self.status_bar = null;
        self.cursor_window_id = null;
    }

    /// Decodes and retains a `gui_theme` packet.
    pub fn applyThemePacket(self: *State, packet: []const u8) Error!void {
        var theme = try decodeTheme(self.alloc, packet);
        errdefer theme.deinit(self.alloc);

        if (self.theme) |*old| old.deinit(self.alloc);
        self.theme = theme;
    }

    /// Decodes and retains a `gui_workspaces` packet.
    pub fn applyWorkspacesPacket(self: *State, packet: []const u8) Error!void {
        var workspaces = try decodeWorkspaces(self.alloc, packet);
        errdefer workspaces.deinit(self.alloc);

        if (self.workspaces) |*old| old.deinit(self.alloc);
        self.workspaces = workspaces;
    }

    /// Decodes and retains a `gui_gutter` packet keyed by window id.
    pub fn applyGutterPacket(self: *State, packet: []const u8) Error!void {
        var gutter = try decodeGutter(self.alloc, packet);
        errdefer gutter.deinit(self.alloc);

        try self.replaceGutter(gutter);
    }

    /// Decodes and retains `gui_indent_guides` keyed by window id.
    pub fn applyIndentGuidesPacket(self: *State, packet: []const u8) Error!void {
        var guides = try decodeIndentGuides(self.alloc, packet);
        errdefer guides.deinit(self.alloc);

        try self.replaceIndentGuides(guides);
    }

    /// Decodes and retains a `gui_file_tree` packet.
    pub fn applyFileTreePacket(self: *State, packet: []const u8) Error!void {
        var tree = try decodeFileTree(self.alloc, packet);
        errdefer tree.deinit(self.alloc);

        if (self.file_tree) |*old| old.deinit(self.alloc);
        self.file_tree = tree;
    }

    /// Decodes and applies a `gui_file_tree_selection` packet.
    pub fn applyFileTreeSelectionPacket(self: *State, packet: []const u8) Error!void {
        var selection = try decodeFileTreeSelection(self.alloc, packet);
        defer selection.deinit(self.alloc);

        if (self.file_tree) |*tree| {
            tree.focused = selection.focused;
            try replaceOwned(self.alloc, selection.selected_id, &tree.selected_id);
        }
    }

    /// Decodes and retains a `gui_sidebars` packet.
    pub fn applySidebarsPacket(self: *State, packet: []const u8) Error!void {
        var sidebars = try decodeSidebars(self.alloc, packet);
        errdefer sidebars.deinit(self.alloc);

        if (self.sidebars) |*old| old.deinit(self.alloc);
        self.sidebars = sidebars;
    }

    /// Decodes and retains a `gui_window_content` packet.
    pub fn applyWindowContentPacket(self: *State, packet: []const u8) Error!void {
        var window = try decodeWindowContent(self.alloc, packet);
        errdefer window.deinit(self.alloc);

        try self.replaceWindow(window);
    }

    /// Decodes and applies a retained window rows or viewport delta.
    pub fn applyWindowRowsDeltaPacket(self: *State, packet: []const u8) Error!void {
        var delta = try decodeWindowRowsDelta(self.alloc, packet);
        defer delta.deinit(self.alloc);

        for (self.windows) |*window| {
            if (window.window_id == delta.window_id) {
                try self.applyWindowRowsDelta(window, &delta);
                return;
            }
        }
    }

    /// Decodes and applies a retained window overlay delta.
    pub fn applyWindowOverlayDeltaPacket(self: *State, packet: []const u8) Error!void {
        const delta = try decodeWindowOverlayDelta(packet);

        for (self.windows) |*window| {
            if (window.window_id == delta.window_id) {
                applyWindowOverlayDelta(window, delta);
                self.cursor_window_id = window.window_id;
                return;
            }
        }
    }

    fn applyWindowOverlayDelta(window: *WindowContent, delta: WindowOverlayDelta) void {
        if (window.content_epoch != delta.content_epoch) return;
        window.flags = delta.flags;
        // Overlay delta header: bit 0 = cursor_visible, bit 1 = cursorline.
        window.cursor_visible = (delta.flags & 0x01) != 0;
        window.cursor_row = delta.cursor_row;
        window.cursor_col = delta.cursor_col;
        window.cursor_shape = delta.cursor_shape;
        window.cursorline_visible = delta.cursorline_visible;
        window.cursorline_row = delta.cursorline_row;
        window.cursorline_bg = delta.cursorline_bg;
    }

    fn applyWindowRowsDelta(self: *State, window: *WindowContent, delta: *WindowRowsDelta) std.mem.Allocator.Error!void {
        if (window.content_epoch != delta.content_epoch) return;

        var rows = try self.alloc.alloc(WindowRow, delta.rows.len);
        @memset(rows, .{});
        var row_index: usize = 0;
        errdefer {
            for (rows[0..row_index]) |*row| row.deinit(self.alloc);
            self.alloc.free(rows);
        }

        while (row_index < delta.rows.len) : (row_index += 1) {
            const delta_row = delta.rows[row_index];
            rows[row_index] = if (delta_row.ref)
                (try cloneRetainedWindowRow(self.alloc, window.rows, delta_row)) orelse return
            else
                try cloneWindowRow(self.alloc, delta_row);
        }

        for (window.rows) |*row| row.deinit(self.alloc);
        self.alloc.free(window.rows);
        window.rows = rows;
        window.flags = delta.flags;
        // Rows/viewport delta header: bit 0 = cursor_visible.
        window.cursor_visible = (delta.flags & 0x01) != 0;
        window.cursor_row = delta.cursor_row;
        window.cursor_col = delta.cursor_col;
        window.cursor_shape = delta.cursor_shape;
        window.scroll_left = delta.scroll_left;
        if (delta.geometry_set) {
            window.origin_row = delta.origin_row;
            window.origin_col = delta.origin_col;
            window.text_width = delta.text_width;
            window.text_height = delta.text_height;
        }
        self.cursor_window_id = window.window_id;
        if (delta.cursorline_visible) {
            window.cursorline_visible = true;
            window.cursorline_row = delta.cursorline_row;
            window.cursorline_bg = delta.cursorline_bg;
        } else {
            window.cursorline_visible = false;
            window.cursorline_row = 0;
            window.cursorline_bg = 0;
        }
        applyWindowOverlaySections(self.alloc, window, delta);
    }

    fn replaceWindow(self: *State, window: WindowContent) std.mem.Allocator.Error!void {
        for (self.windows, 0..) |*existing, index| {
            if (existing.window_id == window.window_id) {
                self.cursor_window_id = window.window_id;
                existing.deinit(self.alloc);
                self.windows[index] = window;
                return;
            }
        }

        const old = self.windows;
        const replacement = try self.alloc.alloc(WindowContent, old.len + 1);
        @memcpy(replacement[0..old.len], old);
        replacement[old.len] = window;
        self.alloc.free(old);
        self.windows = replacement;
        self.cursor_window_id = window.window_id;
    }

    fn replaceGutter(self: *State, gutter: Gutter) std.mem.Allocator.Error!void {
        for (self.gutters, 0..) |*existing, index| {
            if (existing.window_id == gutter.window_id) {
                existing.deinit(self.alloc);
                self.gutters[index] = gutter;
                return;
            }
        }

        const old = self.gutters;
        const replacement = try self.alloc.alloc(Gutter, old.len + 1);
        @memcpy(replacement[0..old.len], old);
        replacement[old.len] = gutter;
        self.alloc.free(old);
        self.gutters = replacement;
    }

    fn replaceIndentGuides(self: *State, guides: IndentGuides) std.mem.Allocator.Error!void {
        for (self.indent_guides, 0..) |*existing, index| {
            if (existing.window_id == guides.window_id) {
                existing.deinit(self.alloc);
                self.indent_guides[index] = guides;
                return;
            }
        }

        const old = self.indent_guides;
        const replacement = try self.alloc.alloc(IndentGuides, old.len + 1);
        @memcpy(replacement[0..old.len], old);
        replacement[old.len] = guides;
        self.alloc.free(old);
        self.indent_guides = replacement;
    }

    /// Decodes and retains a `gui_tab_bar` packet.
    pub fn applyTabBarPacket(self: *State, packet: []const u8) Error!void {
        var tabs = try decodeTabBar(self.alloc, packet);
        errdefer tabs.deinit(self.alloc);

        if (self.tab_bar) |*old| old.deinit(self.alloc);
        self.tab_bar = tabs;
    }

    /// Decodes and retains a `gui_minibuffer` packet.
    pub fn applyMinibufferPacket(self: *State, packet: []const u8) Error!void {
        var minibuffer = try decodeMinibuffer(self.alloc, packet);
        errdefer minibuffer.deinit(self.alloc);

        if (self.minibuffer) |*old| old.deinit(self.alloc);
        self.minibuffer = minibuffer;
    }

    /// Decodes and retains a `gui_which_key` packet.
    pub fn applyWhichKeyPacket(self: *State, packet: []const u8) Error!void {
        var which_key = try decodeWhichKey(self.alloc, packet);
        errdefer which_key.deinit(self.alloc);

        if (self.which_key) |*old| old.deinit(self.alloc);
        self.which_key = which_key;
    }

    /// Decodes and retains a `gui_completion` packet.
    pub fn applyCompletionPacket(self: *State, packet: []const u8) Error!void {
        var completion = try decodeCompletion(self.alloc, packet);
        errdefer completion.deinit(self.alloc);

        if (self.completion) |*old| old.deinit(self.alloc);
        self.completion = completion;
    }

    /// Decodes and retains a `gui_breadcrumb` packet.
    pub fn applyBreadcrumbPacket(self: *State, packet: []const u8) Error!void {
        var breadcrumb = try decodeBreadcrumb(self.alloc, packet);
        errdefer breadcrumb.deinit(self.alloc);

        if (self.breadcrumb) |*old| old.deinit(self.alloc);
        self.breadcrumb = breadcrumb;
    }

    /// Decodes and retains a `gui_picker` packet.
    pub fn applyPickerPacket(self: *State, packet: []const u8) Error!void {
        var picker = try decodePicker(self.alloc, packet);
        errdefer picker.deinit(self.alloc);

        if (self.picker) |*old| old.deinit(self.alloc);
        self.picker = picker;
    }

    /// Decodes and retains a `gui_picker_preview` packet.
    pub fn applyPickerPreviewPacket(self: *State, packet: []const u8) Error!void {
        var preview = try decodePickerPreview(self.alloc, packet);
        errdefer preview.deinit(self.alloc);

        if (self.picker_preview) |*old| old.deinit(self.alloc);
        self.picker_preview = preview;
    }

    /// Decodes and retains a `gui_hover_popup` packet.
    pub fn applyHoverPopupPacket(self: *State, packet: []const u8) Error!void {
        var hover = try decodeHoverPopup(self.alloc, packet);
        errdefer hover.deinit(self.alloc);

        if (self.hover_popup) |*old| old.deinit(self.alloc);
        self.hover_popup = hover;
    }

    /// Decodes and retains a `gui_signature_help` packet.
    pub fn applySignatureHelpPacket(self: *State, packet: []const u8) Error!void {
        var help = try decodeSignatureHelp(self.alloc, packet);
        errdefer help.deinit(self.alloc);

        if (self.signature_help) |*old| old.deinit(self.alloc);
        self.signature_help = help;
    }

    /// Decodes and retains a `gui_float_popup` packet.
    pub fn applyFloatPopupPacket(self: *State, packet: []const u8) Error!void {
        var popup = try decodeFloatPopup(self.alloc, packet);
        errdefer popup.deinit(self.alloc);

        if (self.float_popup) |*old| old.deinit(self.alloc);
        self.float_popup = popup;
    }

    /// Decodes and retains a `gui_git_status` packet.
    pub fn applyGitStatusPacket(self: *State, packet: []const u8) Error!void {
        var git = try decodeGitStatus(self.alloc, packet);
        errdefer git.deinit(self.alloc);

        if (self.git_status) |*old| old.deinit(self.alloc);
        self.git_status = git;
    }

    /// Decodes and retains a `gui_bottom_panel` packet.
    pub fn applyBottomPanelPacket(self: *State, packet: []const u8) Error!void {
        var panel = try decodeBottomPanel(self.alloc, packet);
        errdefer panel.deinit(self.alloc);

        if (self.bottom_panel) |*old| old.deinit(self.alloc);
        self.bottom_panel = panel;
    }

    /// Decodes and retains a `gui_split_separators` packet.
    pub fn applySplitSeparatorsPacket(self: *State, packet: []const u8) Error!void {
        var separators = try decodeSplitSeparators(self.alloc, packet);
        errdefer separators.deinit(self.alloc);

        if (self.split_separators) |*old| old.deinit(self.alloc);
        self.split_separators = separators;
    }

    /// Decodes and retains a `gui_search_state` packet.
    pub fn applySearchStatePacket(self: *State, packet: []const u8) Error!void {
        self.search_state = try decodeSearchState(packet);
    }

    /// Decodes and retains a `gui_change_summary` packet.
    pub fn applyChangeSummaryPacket(self: *State, packet: []const u8) Error!void {
        var summary = try decodeChangeSummary(self.alloc, packet);
        errdefer summary.deinit(self.alloc);

        if (self.change_summary) |*old| old.deinit(self.alloc);
        self.change_summary = summary;
    }

    /// Decodes and retains a `gui_notifications` packet.
    pub fn applyNotificationsPacket(self: *State, packet: []const u8) Error!void {
        var notifications = try decodeNotifications(self.alloc, packet);
        errdefer notifications.deinit(self.alloc);

        if (self.notifications) |*old| old.deinit(self.alloc);
        self.notifications = notifications;
    }

    /// Decodes and retains a `gui_edit_timeline` packet.
    pub fn applyEditTimelinePacket(self: *State, packet: []const u8) Error!void {
        var timeline = try decodeEditTimeline(self.alloc, packet);
        errdefer timeline.deinit(self.alloc);

        if (self.edit_timeline) |*old| old.deinit(self.alloc);
        self.edit_timeline = timeline;
    }

    /// Decodes and retains a `gui_extension_overlay` packet.
    pub fn applyExtensionOverlayPacket(self: *State, packet: []const u8) Error!void {
        var overlay = try decodeExtensionOverlay(self.alloc, packet);
        errdefer overlay.deinit(self.alloc);

        if (self.extension_overlay) |*old| old.deinit(self.alloc);
        self.extension_overlay = overlay;
    }

    /// Decodes and retains a `gui_extension_panel` packet.
    pub fn applyExtensionPanelPacket(self: *State, packet: []const u8) Error!void {
        var panel = try decodeExtensionPanel(self.alloc, packet);
        errdefer panel.deinit(self.alloc);

        if (self.extension_panel) |*old| old.deinit(self.alloc);
        self.extension_panel = panel;
    }

    /// Decodes and retains a `gui_observatory` packet summary.
    pub fn applyObservatoryPacket(self: *State, packet: []const u8) Error!void {
        const observatory = try decodeObservatory(self.alloc, packet);
        if (self.observatory) |*old| old.deinit(self.alloc);
        self.observatory = observatory;
    }

    /// Decodes and retains a `gui_agent_context` packet.
    pub fn applyAgentContextPacket(self: *State, packet: []const u8) Error!void {
        var context = try decodeAgentContext(self.alloc, packet);
        errdefer context.deinit(self.alloc);

        if (self.agent_context) |*old| old.deinit(self.alloc);
        self.agent_context = context;
    }

    /// Decodes and retains a `gui_tool_manager` packet.
    pub fn applyToolManagerPacket(self: *State, packet: []const u8) Error!void {
        var manager = try decodeToolManager(self.alloc, packet);
        errdefer manager.deinit(self.alloc);

        if (self.tool_manager) |*old| old.deinit(self.alloc);
        self.tool_manager = manager;
    }

    /// Decodes and applies legacy `gui_cursorline` chrome.
    pub fn applyCursorlinePacket(self: *State, packet: []const u8) Error!void {
        const cursorline = try decodeCursorline(packet);
        self.cursorline = cursorline;
        for (self.windows) |*window| {
            window.cursorline_visible = true;
            window.cursorline_row = cursorline.row;
            window.cursorline_bg = cursorline.bg;
        }
    }

    /// Decodes and retains legacy `gui_gutter_sep` chrome.
    pub fn applyGutterSeparatorPacket(self: *State, packet: []const u8) Error!void {
        self.gutter_separator = try decodeGutterSeparator(packet);
    }

    /// Decodes and retains `gui_line_spacing` state.
    pub fn applyLineSpacingPacket(self: *State, packet: []const u8) Error!void {
        self.line_spacing = try decodeLineSpacing(packet);
    }

    /// Decodes and retains `gui_cursor_animation` state.
    pub fn applyCursorAnimationPacket(self: *State, packet: []const u8) Error!void {
        self.cursor_animation = try decodeCursorAnimation(packet);
    }

    /// Decodes and retains `gui_config_state` payload.
    pub fn applyConfigStatePacket(self: *State, packet: []const u8) Error!void {
        var config = try decodeConfigState(self.alloc, packet);
        errdefer config.deinit(self.alloc);

        if (self.config_state) |*old| old.deinit(self.alloc);
        self.config_state = config;
    }

    /// Decodes and retains `gui_hover_action` payload.
    pub fn applyHoverActionPacket(self: *State, packet: []const u8) Error!void {
        var action = try decodeHoverAction(self.alloc, packet);
        errdefer action.deinit(self.alloc);

        if (self.hover_action) |*old| old.deinit(self.alloc);
        self.hover_action = action;
    }

    /// Decodes and retains a `gui_board` packet.
    pub fn applyBoardPacket(self: *State, packet: []const u8) Error!void {
        var board = try decodeBoard(self.alloc, packet);
        errdefer board.deinit(self.alloc);

        if (self.board) |*old| old.deinit(self.alloc);
        self.board = board;
    }

    /// Decodes and retains a `gui_agent_chat` packet.
    pub fn applyAgentChatPacket(self: *State, packet: []const u8) Error!void {
        var chat = try decodeAgentChat(self.alloc, packet);
        errdefer chat.deinit(self.alloc);

        if (self.agent_chat) |*old| old.deinit(self.alloc);
        self.agent_chat = chat;
    }

    /// Decodes and retains a `gui_status_bar` packet.
    pub fn applyStatusBarPacket(self: *State, packet: []const u8) Error!void {
        var status = try decodeStatusBar(self.alloc, packet);
        errdefer status.deinit(self.alloc);

        if (self.status_bar) |*old| old.deinit(self.alloc);
        self.status_bar = status;
    }

    /// Renders retained semantic chrome through a surface.
    pub fn render(self: *State, comptime SurfaceT: type, surface: *SurfaceT) void {
        const header_rows = self.headerRowCount();
        const file_tree_visible = if (self.file_tree) |tree| fileTreeVisibleForWidth(tree, surface.width()) else false;
        if (file_tree_visible) renderFileTree(surface, self.file_tree.?, header_rows, self.status_bar != null, self.theme);
        if (self.sidebars) |sidebars| renderSidebars(surface, sidebars, header_rows, self.status_bar != null, !file_tree_visible, self.theme);
        for (self.windows) |window| {
            renderGutter(surface, self.gutterForWindow(window.window_id), self.theme);
            renderWindowContent(surface, window, self.indentGuidesForWindow(window.window_id), self.theme);
        }
        if (self.workspaces) |workspaces| renderWorkspaces(surface, workspaces, self.theme);
        if (self.tab_bar) |tabs| renderTabBar(surface, tabs, self.workspaces != null, self.theme);
        if (self.breadcrumb) |breadcrumb| renderBreadcrumb(surface, breadcrumb, header_rows, self.git_status, self.theme);
        const picker_visible = if (self.picker) |picker| picker.visible else false;
        const which_key_visible = if (self.which_key) |which_key| which_key.visible else false;
        if (self.picker) |picker| {
            renderPicker(surface, picker, self.picker_preview, self.minibuffer != null, self.status_bar != null, self.theme);
        } else if (self.picker_preview) |preview| {
            renderPickerPreview(surface, preview, false, self.minibuffer != null, self.status_bar != null, self.theme);
        }
        if (self.split_separators) |separators| renderSplitSeparators(surface, separators, self.theme);
        if (self.gutter_separator) |separator| renderGutterSeparator(surface, separator, self.theme);
        if (!picker_visible and !which_key_visible) self.renderGenericOverlay(SurfaceT, surface);
        if (self.which_key) |which_key| renderWhichKey(surface, which_key, self.minibuffer != null, self.status_bar != null, self.theme);
        if (self.minibuffer) |minibuffer| renderMinibuffer(surface, minibuffer, self.theme);
        if (self.status_bar) |status| {
            renderStatusBar(surface, status, self.search_state, self.change_summary, self.notifications, self.edit_timeline, self.extension_overlay, self.extension_panel, self.observatory, self.agent_context, self.tool_manager, self.board, self.agent_chat, self.theme);
        } else {
            renderStandaloneFooter(surface, self.search_state, self.change_summary, self.notifications, self.edit_timeline, self.extension_overlay, self.extension_panel, self.observatory, self.agent_context, self.tool_manager, self.board, self.agent_chat, self.minibuffer != null, self.theme);
        }
        self.renderCursor(surface);
    }

    /// Maps a terminal mouse position to a semantic UI action when the click lands on retained chrome.
    pub fn hitTest(self: *State, row: u16, col: u16, width: u16, height: u16) ?HitAction {
        if (width == 0 or height == 0 or row >= height or col >= width) return null;

        const has_minibuffer = self.minibuffer != null;
        const has_status_bar = self.status_bar != null;
        if (self.hover_popup) |hover| {
            if (self.hitHoverAction(hover, row, col, width, height, has_minibuffer, has_status_bar)) |action| return action;
        }

        for (self.gutters) |gutter| {
            if (hitGutter(gutter, row, col, width, height)) |action| return action;
        }

        if (self.file_tree) |tree| {
            if (hitFileTree(tree, row, col, width, height, self.headerRowCount(), has_status_bar)) |action| return action;
        }

        if (self.tab_bar) |tabs| {
            if (hitTabBar(tabs, row, col, width, height, self.workspaces != null)) |action| return action;
        }

        return null;
    }

    fn headerRowCount(self: *State) u16 {
        return @as(u16, if (self.workspaces != null) 1 else 0) + @as(u16, if (self.tab_bar != null) 1 else 0);
    }

    fn hitHoverAction(self: *State, hover: HoverPopup, row: u16, col: u16, width: u16, height: u16, has_minibuffer: bool, has_status_bar: bool) ?HitAction {
        const action = self.hover_action orelse return null;
        if (!hover.visible or hover.lines.len == 0 or !action.visible or action.name.len == 0) return null;

        const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
        const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
        if (max_rows == 0) return null;

        const popup_width: u16 = @min(width, 52);
        const popup_height: u16 = @min(max_rows, @as(u16, @intCast(@min(hover.lines.len + 3, 8))));
        const rect = anchoredOverlayRect(width, max_rows, hover.anchor_col, hover.anchor_row +| 1, popup_width, popup_height) orelse return null;
        const action_row = rect.row +| 1 +| @as(u16, @intCast(@min(hover.lines.len, @as(usize, rect.end_row - rect.row - 1))));
        const content_col: u16 = @min(rect.col + 1, rect.end_col);
        const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
        if (action_row < rect.end_row and row == action_row and col >= content_col and col < content_end_col) {
            return .{ .no_payload = protocol.GUI_ACTION_HOVER_OPEN_ACTION };
        }
        return null;
    }

    fn renderGenericOverlay(self: *State, comptime SurfaceT: type, surface: *SurfaceT) void {
        const has_minibuffer = self.minibuffer != null;
        const has_status_bar = self.status_bar != null;
        if (self.completion) |completion| {
            if (completion.visible and completion.items.len > 0) {
                renderCompletion(surface, completion, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.hover_popup) |hover| {
            if (hover.visible and hover.lines.len > 0) {
                renderHoverPopup(surface, hover, self.hover_action, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.signature_help) |help| {
            if (help.visible and help.signatures.len > 0) {
                renderSignatureHelp(surface, help, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.float_popup) |popup| {
            if (popup.visible) {
                renderFloatPopup(surface, popup, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.agent_context) |context| {
            if (context.visible) {
                renderAgentContext(surface, context, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.agent_chat) |chat| {
            if (chat.visible) {
                renderAgentChat(surface, chat, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.tool_manager) |manager| {
            if (manager.visible) {
                renderToolManager(surface, manager, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.board) |board| {
            if (board.visible) {
                renderBoard(surface, board, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.bottom_panel) |panel| {
            if (panel.visible) {
                renderBottomPanel(surface, panel, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.extension_panel) |panel| {
            if (panel.panels.len > 0) {
                renderExtensionPanel(surface, panel, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.observatory) |observatory| {
            if (observatory.visible) {
                renderObservatory(surface, observatory, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.edit_timeline) |timeline| {
            if (timeline.visible) {
                renderEditTimeline(surface, timeline, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.notifications) |notifications| {
            if (notifications.visible and notifications.items.len > 0) {
                renderNotifications(surface, notifications, has_minibuffer, has_status_bar, self.theme);
                return;
            }
        }
        if (self.extension_overlay) |overlay| {
            if (overlay.entries.len > 0) renderExtensionOverlay(surface, overlay, has_minibuffer, has_status_bar, self.theme);
        }
    }

    fn gutterForWindow(self: *State, window_id: u16) ?Gutter {
        for (self.gutters) |gutter| {
            if (gutter.window_id == window_id) return gutter;
        }
        return null;
    }

    fn indentGuidesForWindow(self: *State, window_id: u16) ?IndentGuides {
        for (self.indent_guides) |guides| {
            if (guides.window_id == window_id) return guides;
        }
        return null;
    }

    fn renderCursor(self: *State, surface: anytype) void {
        // An active minibuffer owns the terminal cursor. The BEAM hides the
        // editor window cursor in this case, so place the cursor on the same
        // row `renderMinibuffer` draws on, at the prompt width plus the input
        // cursor offset.
        if (self.minibuffer) |minibuffer| {
            if (minibufferCursorPosition(surface, minibuffer)) |cursor| {
                surface.setCursorShape(cursor.shape);
                surface.showCursor(cursor.col, cursor.row);
                return;
            }
        }

        const cursor_window_id = self.cursor_window_id orelse return;
        for (self.windows) |window| {
            if (window.window_id != cursor_window_id) continue;
            if (windowCursorPosition(surface, window, self.gutterForWindow(window.window_id))) |cursor| {
                surface.setCursorShape(cursor.shape);
                surface.showCursor(cursor.col, cursor.row);
            }
            return;
        }
    }
};

const RenderedCursor = struct {
    row: u16,
    col: u16,
    shape: surface_mod.CursorShape,
};

fn windowCursorPosition(surface: anytype, window: WindowContent, maybe_gutter: ?Gutter) ?RenderedCursor {
    // A window whose cursor is hidden (e.g. while a minibuffer input mode owns
    // the cursor) must not position the terminal cursor.
    if (!window.cursor_visible) return null;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return null;

    const text_width = if (window.text_width == 0) width else window.text_width;
    const text_height = if (window.text_height == 0) @as(u16, @intCast(@min(window.rows.len, height))) else window.text_height;
    if (window.origin_row >= height or window.origin_col >= width or text_width == 0 or text_height == 0) return null;
    if (window.cursor_row >= text_height) return null;

    const gutter_width = if (maybe_gutter) |gutter| gutterWidth(gutter) else 0;
    const visible_col = window.cursor_col -| window.scroll_left;
    const rendered_col = gutter_width +| visible_col;
    if (rendered_col >= text_width) return null;

    const row = window.origin_row +| window.cursor_row;
    const col = window.origin_col +| rendered_col;
    if (row >= height or col >= width) return null;

    return .{
        .row = row,
        .col = col,
        .shape = semanticCursorShape(window.cursor_shape),
    };
}

fn minibufferCursorPosition(surface: anytype, minibuffer: Minibuffer) ?RenderedCursor {
    if (!minibuffer.visible) return null;
    // 0xFFFF is the sentinel for "no minibuffer cursor" (confirmation prompts).
    if (minibuffer.cursor_pos == 0xFFFF) return null;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return null;

    // Same bottom row `renderMinibuffer` draws the prompt and input on.
    const row: u16 = height - 1;

    const prompt = if (minibuffer.prompt.len > 0) minibuffer.prompt else "> ";
    const prompt_width = charm.textWidth(prompt);
    // `cursor_pos` is a grapheme offset into the input. Advance by the display
    // width of the input prefix so wide graphemes map to the right column.
    const input_offset = textPrefixWidth(minibuffer.input, minibuffer.cursor_pos);
    const col = prompt_width +| input_offset;
    if (col >= width) return null;

    return .{ .row = row, .col = col, .shape = .beam };
}

/// Display width of the first `grapheme_count` graphemes of `text`.
fn textPrefixWidth(text: []const u8, grapheme_count: u16) u16 {
    var total: u16 = 0;
    var seen: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        if (seen >= grapheme_count) break;
        const raw = grapheme.bytes(text);
        const w: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
        total +|= if (w == 0) 1 else w;
        seen += 1;
    }
    return total;
}

fn semanticCursorShape(shape: u8) surface_mod.CursorShape {
    return switch (shape) {
        1 => .beam,
        2 => .underline,
        else => .block,
    };
}

fn renderFileTree(surface: anytype, file_tree: FileTree, header_rows: u16, has_status_bar: bool, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (!fileTreeVisibleForWidth(file_tree, width) or height == 0) return;

    const tree_width: u16 = @min(file_tree.width, if (width > 0) width - 1 else 0);
    if (tree_width == 0) return;

    const start_row: u16 = @min(header_rows, height - 1);
    const footer_rows: u16 = if (has_status_bar) 1 else 0;
    const end_row: u16 = if (height > footer_rows) height - footer_rows else height;
    if (start_row >= end_row) return;

    var row = start_row;
    while (row < end_row) : (row += 1) {
        fillRowRangeWith(surface, row, 0, tree_width, treeBg(maybe_theme));
    }

    row = start_row;
    var col: u16 = 0;
    col = writeText(surface, row, 0, tree_width, "Files", treeFg(maybe_theme), treeBg(maybe_theme), protocol.ATTR_BOLD);
    if (file_tree.root_path.len > 0) {
        col = writeText(surface, row, col, tree_width, "  ", mutedFg(maybe_theme), treeBg(maybe_theme), 0);
        _ = writeText(surface, row, col, tree_width, file_tree.root_path, mutedFg(maybe_theme), treeBg(maybe_theme), 0);
    }
    row += 1;
    if (row >= end_row) return;

    if (file_tree.status == 4 and file_tree.error_text.len > 0) {
        _ = writeText(surface, row, 0, tree_width, file_tree.error_text, mutedFg(maybe_theme), treeBg(maybe_theme), 0);
        return;
    }

    if (file_tree.rows.len == 0) {
        const status_text = fileTreeStatusText(file_tree);
        if (status_text.len > 0) _ = writeText(surface, row, 0, tree_width, status_text, mutedFg(maybe_theme), treeBg(maybe_theme), 0);
        return;
    }

    var index: usize = 0;
    while (row < end_row and index < file_tree.rows.len) : ({
        row += 1;
        index += 1;
    }) {
        renderFileTreeRow(surface, file_tree, file_tree.rows[index], row, tree_width, maybe_theme);
    }
}

fn renderFileTreeRow(surface: anytype, file_tree: FileTree, row: FileTreeRow, screen_row: u16, tree_width: u16, maybe_theme: ?Theme) void {
    const selected = row.selected() or std.mem.eql(u8, row.id, file_tree.selected_id);
    const focused = row.focused() or (selected and file_tree.focused);
    const active = row.active();
    const attrs: u8 = if (selected or active) protocol.ATTR_BOLD else 0;
    const fg = if (focused) treeSelectionFg(maybe_theme) else if (selected) treeSelectionFg(maybe_theme) else if (active) accentFg(maybe_theme) else if (row.directory()) treeDirFg(maybe_theme) else treeFg(maybe_theme);
    const bg = if (selected) treeSelectionBg(maybe_theme) else treeBg(maybe_theme);
    fillRowRangeWith(surface, screen_row, 0, tree_width, bg);

    var col: u16 = 0;
    var depth: u8 = 0;
    while (depth < row.depth and col < tree_width) : (depth += 1) {
        col = writeText(surface, screen_row, col, tree_width, "  ", fg, bg, attrs);
    }

    const marker = if (row.directory()) (if (row.expanded()) "v" else ">") else " ";
    col = writeText(surface, screen_row, col, tree_width, marker, fg, bg, attrs);
    col = writeText(surface, screen_row, col, tree_width, " ", fg, bg, attrs);
    if (row.icon.len > 0) {
        col = writeText(surface, screen_row, col, tree_width, row.icon, fg, bg, attrs);
        col = writeText(surface, screen_row, col, tree_width, " ", fg, bg, attrs);
    }
    const label = if (row.editing_text.len > 0) row.editing_text else row.name;
    col = writeText(surface, screen_row, col, tree_width, label, fg, bg, attrs);
    const git_marker = fileTreeGitMarker(row.git_status);
    if (git_marker.len > 0) {
        _ = writeText(surface, screen_row, col, tree_width, git_marker, fg, bg, attrs);
    } else if (row.dirty()) {
        col = writeText(surface, screen_row, col, tree_width, " *", fg, bg, attrs);
    }
    const diagnostic_count = row.visibleDiagnostics();
    if (diagnostic_count > 0) {
        const diagnostic_fg = if (row.diagnostic_errors > 0) diagnosticColor(maybe_theme, 0) else diagnosticColor(maybe_theme, 1);
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, " {d}", .{diagnostic_count}) catch "";
        _ = writeAsciiStableText(surface, screen_row, col, tree_width, text, diagnostic_fg, bg, 0);
    }
}

fn fileTreeGitMarker(status: u8) []const u8 {
    return switch (status) {
        1 => " M",
        2 => " A",
        3 => " D",
        4 => " R",
        5 => " ?",
        else => "",
    };
}

fn fileTreeVisibleForWidth(file_tree: FileTree, width: u16) bool {
    return file_tree.visible and file_tree.width > 0 and width >= 50;
}

fn fileTreeStatusText(file_tree: FileTree) []const u8 {
    return switch (file_tree.status) {
        1 => "Loading files...",
        2 => "No files",
        4 => if (file_tree.error_text.len > 0) file_tree.error_text else "File tree error",
        else => "",
    };
}

fn hitFileTree(file_tree: FileTree, row: u16, col: u16, width: u16, height: u16, header_rows: u16, has_status_bar: bool) ?HitAction {
    if (!fileTreeVisibleForWidth(file_tree, width) or height == 0) return null;
    const tree_width: u16 = @min(file_tree.width, if (width > 0) width - 1 else 0);
    if (tree_width == 0 or col >= tree_width) return null;

    const start_row: u16 = @min(header_rows, height - 1);
    const footer_rows: u16 = if (has_status_bar) 1 else 0;
    const end_row: u16 = if (height > footer_rows) height - footer_rows else height;
    if (row <= start_row or row >= end_row) return null;
    if (file_tree.status == 4 or file_tree.rows.len == 0) return null;

    const index: usize = row - start_row - 1;
    if (index >= file_tree.rows.len or index > std.math.maxInt(u16)) return null;

    const tree_row = file_tree.rows[index];
    if (tree_row.directory()) {
        const marker_col: u16 = @as(u16, tree_row.depth) * 2;
        if (col >= marker_col and col <= marker_col +| 1) {
            return .{ .u16_payload = .{ .action = protocol.GUI_ACTION_FILE_TREE_TOGGLE, .value = @intCast(index) } };
        }
    }

    return .{ .u16_payload = .{ .action = protocol.GUI_ACTION_FILE_TREE_CLICK, .value = @intCast(index) } };
}

fn renderSidebars(surface: anytype, sidebars: Sidebars, header_rows: u16, has_status_bar: bool, left_chrome_available: bool, maybe_theme: ?Theme) void {
    if (!left_chrome_available or sidebars.visibleCount() == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width < 60 or height == 0) return;

    const sidebar_width: u16 = @min(sidebars.preferredWidth(), @max(width / 4, 18));
    if (sidebar_width == 0) return;

    const start_row: u16 = @min(header_rows, height - 1);
    const footer_rows: u16 = if (has_status_bar) 1 else 0;
    const end_row: u16 = if (height > footer_rows) height - footer_rows else height;
    if (start_row >= end_row) return;

    var row = start_row;
    while (row < end_row) : (row += 1) {
        fillRowRangeWith(surface, row, 0, sidebar_width, treeBg(maybe_theme));
    }

    row = start_row;
    _ = writeText(surface, row, 0, sidebar_width, "Sidebars", mutedFg(maybe_theme), treeBg(maybe_theme), 0);
    row += 1;

    for (sidebars.items) |sidebar| {
        if (row >= end_row) break;
        if (!sidebar.visible) continue;
        renderSidebarRow(surface, sidebars, sidebar, row, sidebar_width, maybe_theme);
        row += 1;
    }
}

fn renderSidebarRow(surface: anytype, sidebars: Sidebars, sidebar: Sidebar, row: u16, width: u16, maybe_theme: ?Theme) void {
    const selected = sidebar.focused or std.mem.eql(u8, sidebar.id, sidebars.active_id);
    const attrs: u8 = if (selected) protocol.ATTR_BOLD else 0;
    const fg = if (selected) popupSelectionFg(maybe_theme) else mutedFg(maybe_theme);
    const bg = if (selected) popupSelectionBg(maybe_theme) else treeBg(maybe_theme);
    fillRowRangeWith(surface, row, 0, width, bg);

    var col: u16 = 0;
    col = writeText(surface, row, col, width, " ", fg, bg, attrs);
    if (sidebar.icon.len > 0) {
        col = writeText(surface, row, col, width, sidebar.icon, fg, bg, attrs);
        col = writeText(surface, row, col, width, " ", fg, bg, attrs);
    }
    col = writeText(surface, row, col, width, sidebar.display_name, fg, bg, attrs);
    if (sidebar.badge_count != std.math.maxInt(u16) and sidebar.badge_count > 0) {
        var buf: [16]u8 = undefined;
        const badge = std.fmt.bufPrint(&buf, " {d}", .{sidebar.badge_count}) catch "";
        _ = writeAsciiStableText(surface, row, col, width, badge, fg, bg, attrs);
    }
}

fn renderGutter(surface: anytype, maybe_gutter: ?Gutter, maybe_theme: ?Theme) void {
    const gutter = maybe_gutter orelse return;
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const gutter_width: u16 = @min(width, gutterWidth(gutter));
    if (gutter_width == 0 or gutter.content_col >= width or gutter.content_row >= height) return;

    const end_row: u16 = @min(height, gutter.content_row +| gutter.content_height);
    const end_col: u16 = @min(width, gutter.content_col +| gutter_width);

    var row = gutter.content_row;
    var index: usize = 0;
    while (row < end_row) : ({
        row += 1;
        index += 1;
    }) {
        clearRowRange(surface, row, gutter.content_col, end_col);
        var buf: [64]u8 = undefined;
        const text = gutterText(gutter, index, &buf);
        const current = index < gutter.entries.len and gutter.entries[index].buf_line == gutter.cursor_line and gutter.line_number_style != 2;
        writeAsciiText(surface, row, gutter.content_col, end_col, text, if (current) gutterCurrentFg(maybe_theme) else gutterFg(maybe_theme), editorBg(maybe_theme), if (current) protocol.ATTR_BOLD else 0);
    }
}

fn gutterWidth(gutter: Gutter) u16 {
    const sign_width: u16 = gutter.sign_col_width;
    const line_width: u16 = if (gutter.line_number_width == 0) 1 else gutter.line_number_width;
    // The separator before the text is the last column of the line-number field,
    // so the total width is sign + line_number_width (no extra column). This must
    // match the BEAM `GutterMetrics.total_width` used to place the window content.
    return sign_width +| line_width;
}

fn gutterText(gutter: Gutter, row_index: usize, buf: []u8) []const u8 {
    const entry = if (row_index < gutter.entries.len) gutter.entries[row_index] else null;
    const sign_width: usize = gutter.sign_col_width;
    const line_number_width: usize = if (gutter.line_number_width == 0) 1 else gutter.line_number_width;

    var offset: usize = 0;
    if (entry) |gutter_entry| {
        const sign = gutterSign(gutter_entry);
        appendBounded(buf, &offset, sign);
        var sign_len = textWidth(sign);
        while (sign_len < sign_width) : (sign_len += 1) {
            appendBounded(buf, &offset, " ");
        }

        const number = gutterLineNumber(gutter, gutter_entry);
        var number_buf: [32]u8 = undefined;
        const number_text = if (number == null) "" else std.fmt.bufPrint(&number_buf, "{d}", .{number.?}) catch "";
        const number_width = textWidth(number_text);
        // Reserve the last column of the line-number field as the separator
        // before the text, so the number is right-aligned within the remaining
        // `line_number_width - 1` columns and one trailing space is appended.
        const number_field = if (line_number_width > 0) line_number_width - 1 else 0;
        var pad = if (number_field > number_width) number_field - number_width else 0;
        while (pad > 0) : (pad -= 1) {
            appendBounded(buf, &offset, " ");
        }
        appendBounded(buf, &offset, number_text);
        appendBounded(buf, &offset, " ");
    } else {
        var remaining: usize = sign_width + line_number_width;
        while (remaining > 0) : (remaining -= 1) {
            appendBounded(buf, &offset, " ");
        }
    }

    return buf[0..offset];
}

fn appendBounded(buf: []u8, offset: *usize, text: []const u8) void {
    if (offset.* >= buf.len) return;
    const writable = @min(text.len, buf.len - offset.*);
    @memcpy(buf[offset.* .. offset.* + writable], text[0..writable]);
    offset.* += writable;
}

fn gutterSign(entry: GutterEntry) []const u8 {
    if (entry.sign_type == 8 and entry.sign_text.len > 0) return entry.sign_text;
    if (entry.sign_type == 9) return "-";
    if (entry.sign_type != 0) return "!";
    return "";
}

fn gutterLineNumber(gutter: Gutter, entry: GutterEntry) ?u32 {
    if (gutter.line_number_width <= 1 or gutter.line_number_style == 3 or entry.display_type == 3 or entry.display_type == 5) return null;
    if (gutter.line_number_style == 2 or (gutter.line_number_style == 0 and entry.buf_line != gutter.cursor_line)) {
        return if (entry.buf_line > gutter.cursor_line) entry.buf_line - gutter.cursor_line else gutter.cursor_line - entry.buf_line;
    }
    return entry.buf_line + 1;
}

fn hitGutter(gutter: Gutter, row: u16, col: u16, width: u16, height: u16) ?HitAction {
    if (width == 0 or height == 0 or gutter.sign_col_width == 0) return null;
    if (gutter.content_col >= width or gutter.content_row >= height) return null;

    const end_row: u16 = @min(height, gutter.content_row +| gutter.content_height);
    if (row < gutter.content_row or row >= end_row) return null;

    const sign_start = gutter.content_col;
    const sign_end: u16 = @min(width, gutter.content_col +| @as(u16, gutter.sign_col_width));
    if (col < sign_start or col >= sign_end) return null;

    const index: usize = row - gutter.content_row;
    if (index >= gutter.entries.len) return null;

    const entry = gutter.entries[index];
    if (entry.fold_end_line == std.math.maxInt(u32) or entry.fold_end_line <= entry.buf_line) return null;
    return .{ .fold_toggle = .{ .window_id = gutter.window_id, .buffer_line = entry.buf_line } };
}

fn renderWindowContent(surface: anytype, window: WindowContent, indent_guides: ?IndentGuides, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const start_row = window.origin_row;
    const start_col = window.origin_col;
    const text_width = if (window.text_width == 0) width else window.text_width;
    const text_height = if (window.text_height == 0) @as(u16, @intCast(@min(window.rows.len, height))) else window.text_height;
    if (start_row >= height or start_col >= width or text_height == 0 or text_width == 0) return;

    const end_row: u16 = @min(height, start_row +| text_height);
    const end_col: u16 = @min(width, start_col +| text_width);
    var clear_row = start_row;
    while (clear_row < end_row) : (clear_row += 1) {
        clearRowRange(surface, clear_row, start_col, end_col);
    }

    var row_index: usize = 0;
    while (row_index < window.rows.len and start_row + row_index < end_row) : (row_index += 1) {
        const row_bg = if (window.cursorline_visible and row_index == window.cursorline_row) window.cursorline_bg else 0;
        renderWindowRow(surface, window, window.rows[row_index], @intCast(start_row + row_index), start_col, end_col, row_bg, indent_guides, maybe_theme, @intCast(row_index));
    }

    while (start_row + row_index < end_row) : (row_index += 1) {
        const row_bg = if (window.cursorline_visible and row_index == window.cursorline_row) window.cursorline_bg else 0;
        renderTildeRow(surface, @intCast(start_row + row_index), start_col, end_col, row_bg);
    }
}

fn renderWindowRow(surface: anytype, window: WindowContent, row: WindowRow, screen_row: u16, start_col: u16, end_col: u16, row_bg: u24, indent_guides: ?IndentGuides, maybe_theme: ?Theme, row_index: usize) void {
    var screen_col = start_col;
    var display_col: u16 = 0;
    var iter = vaxis.unicode.graphemeIterator(row.text);
    while (iter.next()) |grapheme| {
        const raw = grapheme.bytes(row.text);
        const width: u16 = vaxis.gwidth.gwidth(raw, .wcwidth);
        const cell_width: u16 = if (width == 0) 1 else width;
        const next_display_col = display_col +| cell_width;
        defer display_col = next_display_col;

        if (next_display_col <= window.scroll_left) continue;
        if (screen_col >= end_col) break;

        const span = windowSpanAt(row.spans, display_col);
        const style = windowOverlayStyle(window, span, @intCast(row_index), display_col, row_bg, maybe_theme);
        const rendered = indentGuideGrapheme(raw, indent_guides, row_index, display_col);
        surface.writeCell(screen_col, screen_row, .{
            .grapheme = rendered,
            .width = @intCast(cell_width),
            .fg = style.fg,
            .bg = style.bg,
            .attrs = style.attrs,
            .strikethrough = style.strikethrough,
            .ul_style = style.ul_style,
        });
        screen_col +|= cell_width;
    }

    screen_col = renderRowAnnotations(surface, window.annotations, @intCast(row_index), screen_row, screen_col, end_col, maybe_theme);
    fillRowRemainder(surface, screen_row, screen_col, end_col, row_bg);
}

fn windowOverlayStyle(window: WindowContent, span: WindowSpan, row: u16, col: u16, row_bg: u24, maybe_theme: ?Theme) RenderStyle {
    var style = RenderStyle{
        .fg = span.fg,
        .bg = if (span.bg != 0) span.bg else row_bg,
        .attrs = semanticSurfaceAttrs(span.attrs),
        .strikethrough = span.attrs & 0x08 != 0,
        .ul_style = if (span.attrs & 0x10 != 0) 1 else 0,
    };

    if (selectionContains(window.selection, row, col)) {
        style.bg = selectionBg(maybe_theme);
    }

    for (window.document_highlights) |highlight| {
        if (rangeContains(highlight.start_row, highlight.start_col, highlight.end_row, highlight.end_col, row, col)) {
            style.bg = documentHighlightBg(maybe_theme, highlight.kind);
            break;
        }
    }

    for (window.search_matches) |match| {
        if (match.row == row and col >= match.start_col and col < match.end_col) {
            style.bg = searchMatchBg(maybe_theme, match.current);
            break;
        }
    }

    for (window.diagnostic_ranges) |diagnostic| {
        if (rangeContains(diagnostic.start_row, diagnostic.start_col, diagnostic.end_row, diagnostic.end_col, row, col)) {
            style.fg = diagnosticColor(maybe_theme, diagnostic.severity);
            style.attrs |= protocol.ATTR_UNDERLINE;
            break;
        }
    }

    return style;
}

fn semanticSurfaceAttrs(attrs: u8) u8 {
    var surface_attrs: u8 = 0;
    if (attrs & 0x01 != 0) surface_attrs |= protocol.ATTR_BOLD;
    if (attrs & 0x02 != 0) surface_attrs |= protocol.ATTR_ITALIC;
    if (attrs & 0x04 != 0) surface_attrs |= protocol.ATTR_UNDERLINE;
    if (attrs & 0x10 != 0) surface_attrs |= protocol.ATTR_UNDERLINE;
    return surface_attrs;
}

fn selectionContains(selection: WindowSelection, row: u16, col: u16) bool {
    if (selection.selection_type == 0) return false;
    return rangeContains(selection.start_row, selection.start_col, selection.end_row, selection.end_col, row, col);
}

fn rangeContains(start_row: u16, start_col: u16, end_row: u16, end_col: u16, row: u16, col: u16) bool {
    if (row < start_row or row > end_row) return false;
    if (start_row == end_row) return col >= start_col and col < end_col;
    if (row == start_row) return col >= start_col;
    if (row == end_row) return col < end_col;
    return true;
}

fn renderRowAnnotations(surface: anytype, annotations: []const LineAnnotation, row_index: u16, screen_row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) u16 {
    var col = start_col;
    for (annotations) |annotation| {
        if (annotation.row != row_index or annotation.kind == 2 or annotation.text.len == 0 or col >= end_col) continue;
        const fg = if (annotation.fg != 0) annotation.fg else accentFg(maybe_theme);
        const bg = if (annotation.bg != 0) annotation.bg else editorBg(maybe_theme);
        col = writeText(surface, screen_row, col, end_col, " ", fg, bg, 0);
        col = writeText(surface, screen_row, col, end_col, annotation.text, fg, bg, 0);
    }
    return col;
}

fn renderTildeRow(surface: anytype, screen_row: u16, start_col: u16, end_col: u16, row_bg: u24) void {
    if (start_col >= end_col) return;
    surface.writeCell(start_col, screen_row, .{
        .grapheme = "~",
        .width = 1,
        .fg = 0,
        .bg = row_bg,
        .attrs = 0,
    });
    fillRowRemainder(surface, screen_row, start_col + 1, end_col, row_bg);
}

fn fillRowRemainder(surface: anytype, screen_row: u16, start_col: u16, end_col: u16, row_bg: u24) void {
    if (row_bg == 0) return;
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

fn indentGuideGrapheme(grapheme: []const u8, maybe_guides: ?IndentGuides, row_index: usize, display_col: u16) []const u8 {
    const guides = maybe_guides orelse return grapheme;
    if (!std.mem.eql(u8, grapheme, " ")) return grapheme;
    if (!guideColumnVisible(guides, display_col)) return grapheme;
    if (!guideEnabledOnRow(guides, row_index, display_col)) return grapheme;
    return "│";
}

fn guideColumnVisible(guides: IndentGuides, display_col: u16) bool {
    for (guides.guide_cols) |col| {
        if (col == display_col) return true;
    }
    return false;
}

fn guideEnabledOnRow(guides: IndentGuides, row_index: usize, display_col: u16) bool {
    if (row_index >= guides.line_indent_levels.len) return false;
    const tab_width: u16 = @max(@as(u16, guides.tab_width), 1);
    return display_col / tab_width <= @as(u16, guides.line_indent_levels[row_index]);
}

fn windowSpanAt(spans: []const WindowSpan, col: u16) WindowSpan {
    for (spans) |span| {
        if (col >= span.start_col and col < span.end_col) return span;
    }
    return .{};
}

fn renderWorkspaces(surface: anytype, workspaces: Workspaces, maybe_theme: ?Theme) void {
    if (workspaces.visible == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    clearRow(surface, 0, width);
    fillRowRemainder(surface, 0, 0, width, editorBg(maybe_theme));

    var col: u16 = 0;
    col = writeText(surface, 0, col, width, "Spaces", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    if (workspaces.spaces.len == 0) {
        col = writeText(surface, 0, col, width, " · ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        var buf: [32]u8 = undefined;
        const fallback = std.fmt.bufPrint(&buf, "{d}/{d}", .{ workspaces.active_workspace_id, workspaces.workspace_count }) catch "";
        _ = writeAsciiStableText(surface, 0, col, width, fallback, popupFg(maybe_theme), editorBg(maybe_theme), 0);
        return;
    }

    for (workspaces.spaces) |space| {
        col = writeText(surface, 0, col, width, " · ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        const active = space.id == workspaces.active_workspace_id;
        const primary_fg = if (active) accentFg(maybe_theme) else tabInactiveFg(maybe_theme);
        const primary_attrs: u8 = if (active) protocol.ATTR_BOLD else 0;
        if (active) {
            col = writeText(surface, 0, col, width, "▎", accentFg(maybe_theme), editorBg(maybe_theme), protocol.ATTR_BOLD);
        }
        if (space.icon.len > 0) {
            const icon_fg: u24 = if (space.color != 0 and active) space.color else primary_fg;
            col = writeText(surface, 0, col, width, space.icon, icon_fg, editorBg(maybe_theme), primary_attrs);
            col = writeText(surface, 0, col, width, " ", primary_fg, editorBg(maybe_theme), primary_attrs);
        }
        col = writeText(surface, 0, col, width, space.label, primary_fg, editorBg(maybe_theme), primary_attrs);
        col = renderWorkspaceMetadata(surface, 0, col, width, space, maybe_theme);
        if (space.attention()) col = writeText(surface, 0, col, width, " !", diagnosticColor(maybe_theme, 1), editorBg(maybe_theme), protocol.ATTR_BOLD);
    }
}

fn renderWorkspaceMetadata(surface: anytype, row: u16, start_col: u16, end_col: u16, space: Workspace, maybe_theme: ?Theme) u16 {
    var col = start_col;
    var first = true;
    if (space.tab_count > 0) col = renderWorkspaceMetadataPart(surface, row, col, end_col, space.tab_count, "tab", &first, maybe_theme);
    if (space.draft_count > 0) col = renderWorkspaceMetadataPart(surface, row, col, end_col, space.draft_count, "draft", &first, maybe_theme);
    if (space.conflict_count > 0) col = renderWorkspaceMetadataPart(surface, row, col, end_col, space.conflict_count, "conflict", &first, maybe_theme);
    if (space.background_count > 0) {
        if (first) {
            col = writeText(surface, row, col, end_col, " (", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
            first = false;
        } else {
            col = writeText(surface, row, col, end_col, ", ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        }
        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{space.background_count}) catch "";
        col = writeAsciiStableText(surface, row, col, end_col, count, mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        col = writeText(surface, row, col, end_col, " running", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    }
    if (!first) col = writeText(surface, row, col, end_col, ")", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    return col;
}

fn renderWorkspaceMetadataPart(surface: anytype, row: u16, start_col: u16, end_col: u16, count: u16, comptime label: []const u8, first: *bool, maybe_theme: ?Theme) u16 {
    var col = start_col;
    if (first.*) {
        col = writeText(surface, row, col, end_col, " (", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        first.* = false;
    } else {
        col = writeText(surface, row, col, end_col, ", ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    }
    var count_buf: [16]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d}", .{count}) catch "";
    col = writeAsciiStableText(surface, row, col, end_col, count_text, mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    col = writeText(surface, row, col, end_col, " ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    col = writeText(surface, row, col, end_col, label, mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    if (count != 1) col = writeText(surface, row, col, end_col, "s", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    return col;
}

fn renderTabBar(surface: anytype, tab_bar: TabBar, has_workspaces: bool, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const row: u16 = if (has_workspaces and height > 1) 1 else 0;
    clearRow(surface, row, width);
    fillRowRemainder(surface, row, 0, width, tabBg(maybe_theme));

    var col: u16 = 0;
    for (tab_bar.tabs, 0..) |tab, index| {
        if (col >= width) break;
        const active = tab.active() or index == tab_bar.active_index;
        const tab_fg = if (active) tabActiveFg(maybe_theme) else tabInactiveFg(maybe_theme);
        const tab_bg = if (active) tabActiveBg(maybe_theme) else tabBg(maybe_theme);
        const attrs: u8 = if (active) protocol.ATTR_BOLD else 0;
        if (index > 0) col = writeText(surface, row, col, width, " ", tab_fg, tabBg(maybe_theme), 0);

        if (active) {
            col = writeText(surface, row, col, width, "▌ ", tabActiveFg(maybe_theme), tabActiveBg(maybe_theme), protocol.ATTR_BOLD);
        }

        if (tab.icon.len > 0) {
            const icon_fg: u24 = if (tab.tint != 0) @intCast(tab.tint & 0x00FF_FFFF) else tab_fg;
            col = writeText(surface, row, col, width, tab.icon, icon_fg, tab_bg, attrs);
            col = writeText(surface, row, col, width, " ", tab_fg, tab_bg, attrs);
        }

        col = writeText(surface, row, col, width, tab.label, tab_fg, tab_bg, attrs);

        if (tab.dirty()) {
            col = writeText(surface, row, col, width, " *", tabDirtyFg(maybe_theme), tab_bg, 0);
        }

        if (tab.attention()) {
            col = writeText(surface, row, col, width, " !", tabAttentionFg(maybe_theme), tabBg(maybe_theme), protocol.ATTR_BOLD);
        }
    }
}

fn hitTabBar(tab_bar: TabBar, row: u16, col: u16, width: u16, height: u16, has_workspaces: bool) ?HitAction {
    if (width == 0 or height == 0) return null;
    const tab_row: u16 = if (has_workspaces and height > 1) 1 else 0;
    if (row != tab_row) return null;

    var cursor: u16 = 0;
    for (tab_bar.tabs, 0..) |tab, index| {
        if (cursor >= width) break;
        if (index > 0) cursor +|= 1;

        const start_col = cursor;
        if (tab.active() or index == tab_bar.active_index) cursor +|= 2;
        if (tab.icon.len > 0) cursor +|= textWidth(tab.icon) +| 1;
        cursor +|= textWidth(tab.label);
        if (tab.dirty()) cursor +|= 2;
        if (tab.attention()) cursor +|= 2;

        const end_col = @min(cursor, width);
        if (col >= start_col and col < end_col) {
            return .{ .u32_payload = .{ .action = protocol.GUI_ACTION_SELECT_TAB, .value = tab.id } };
        }
    }
    return null;
}

fn renderBreadcrumb(surface: anytype, breadcrumb: Breadcrumb, header_rows: u16, maybe_git: ?GitStatus, maybe_theme: ?Theme) void {
    if (breadcrumb.segments.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const row: u16 = @min(header_rows, height - 1);
    clearRow(surface, row, width);
    fillRowRemainder(surface, row, 0, width, editorBg(maybe_theme));

    var col: u16 = 0;
    col = writeText(surface, row, col, width, "  ", editorFg(maybe_theme), editorBg(maybe_theme), 0);
    for (breadcrumb.segments, 0..) |segment, index| {
        if (index > 0) col = writeText(surface, row, col, width, " › ", gutterFg(maybe_theme), editorBg(maybe_theme), 0);
        const attrs: u8 = if (index == breadcrumb.segments.len - 1) protocol.ATTR_BOLD else 0;
        const fg = if (index == breadcrumb.segments.len - 1) editorFg(maybe_theme) else mutedFg(maybe_theme);
        col = writeText(surface, row, col, width, segment, fg, editorBg(maybe_theme), attrs);
    }

    if (maybe_git) |git| {
        if (git.branch.len > 0 and col < width) {
            var buf: [128]u8 = undefined;
            const summary = gitSummary(&buf, git);
            if (summary.len > 0 and col +| textWidth("  .  ") +| textWidth(summary) <= width) {
                col = writeText(surface, row, col, width, "  .  ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
                _ = renderBreadcrumbGitSummary(surface, row, col, width, git, maybe_theme);
            }
        }
    }
}

fn renderBreadcrumbGitSummary(surface: anytype, row: u16, start_col: u16, width: u16, git: GitStatus, maybe_theme: ?Theme) u16 {
    var col = start_col;
    const fg = mutedFg(maybe_theme);
    const bg = editorBg(maybe_theme);
    col = writeText(surface, row, col, width, "git ", fg, bg, 0);
    col = writeText(surface, row, col, width, git.branch, fg, bg, 0);
    if (git.syncing) col = writeText(surface, row, col, width, "  syncing", fg, bg, 0);
    if (git.ahead > 0) {
        col = writeText(surface, row, col, width, "  ahead ", fg, bg, 0);
        var ahead_buf: [32]u8 = undefined;
        col = writeAsciiStableText(surface, row, col, width, std.fmt.bufPrint(&ahead_buf, "{d}", .{git.ahead}) catch "", fg, bg, 0);
    }
    if (git.behind > 0) {
        col = writeText(surface, row, col, width, "  behind ", fg, bg, 0);
        var behind_buf: [32]u8 = undefined;
        col = writeAsciiStableText(surface, row, col, width, std.fmt.bufPrint(&behind_buf, "{d}", .{git.behind}) catch "", fg, bg, 0);
    }
    if (git.entries.len > 0) {
        col = writeText(surface, row, col, width, "  ", fg, bg, 0);
        var files_buf: [32]u8 = undefined;
        col = writeAsciiStableText(surface, row, col, width, std.fmt.bufPrint(&files_buf, "{d}", .{git.entries.len}) catch "", fg, bg, 0);
        col = writeText(surface, row, col, width, " files", fg, bg, 0);
    }
    if (git.toast.visible and git.toast.message.len > 0) {
        col = writeText(surface, row, col, width, "  ", fg, bg, 0);
        col = writeText(surface, row, col, width, git.toast.message, fg, bg, 0);
    }
    return col;
}

fn gitSummary(buf: []u8, git: GitStatus) []const u8 {
    if (git.branch.len == 0) return "";
    var offset: usize = 0;
    appendBounded(buf, &offset, "git ");
    appendBounded(buf, &offset, git.branch);
    if (git.syncing) appendBounded(buf, &offset, "  syncing");
    if (git.ahead > 0) {
        var ahead_buf: [32]u8 = undefined;
        appendBounded(buf, &offset, std.fmt.bufPrint(&ahead_buf, "  ahead {d}", .{git.ahead}) catch "");
    }
    if (git.behind > 0) {
        var behind_buf: [32]u8 = undefined;
        appendBounded(buf, &offset, std.fmt.bufPrint(&behind_buf, "  behind {d}", .{git.behind}) catch "");
    }
    if (git.entries.len > 0) {
        var files_buf: [32]u8 = undefined;
        appendBounded(buf, &offset, std.fmt.bufPrint(&files_buf, "  {d} files", .{git.entries.len}) catch "");
    }
    if (git.toast.visible and git.toast.message.len > 0) {
        appendBounded(buf, &offset, "  ");
        appendBounded(buf, &offset, git.toast.message);
    }
    return buf[0..offset];
}

fn renderMinibuffer(surface: anytype, minibuffer: Minibuffer, maybe_theme: ?Theme) void {
    if (!minibuffer.visible) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    // The TUI layout places the minibuffer on the bottom row; the status bar
    // (when present) sits one row above it (see `Shell.Traditional.Layout.TUI`).
    const row: u16 = height - 1;
    clearRow(surface, row, width);
    fillRowRemainder(surface, row, 0, width, popupBg(maybe_theme));

    var col: u16 = 0;
    const prompt = if (minibuffer.prompt.len > 0) minibuffer.prompt else "> ";
    col = writeText(surface, row, col, width, prompt, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, width, minibuffer.input, popupFg(maybe_theme), popupBg(maybe_theme), 0);

    if (minibuffer.context.len > 0) {
        col = writeText(surface, row, col, width, "  ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, row, col, width, minibuffer.context, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    }

    if (minibuffer.total_candidates > 0) {
        var count_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&count_buf, "  {d}/{d}", .{ minibuffer.selected_index +| 1, minibuffer.total_candidates }) catch "";
        _ = writeAsciiStableText(surface, row, col, width, text, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    }
}

fn renderWhichKey(surface: anytype, which_key: WhichKey, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!which_key.visible or which_key.bindings.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const popup_width: u16 = width;
    const rows: usize = which_key.bindings.len;
    const popup_height: u16 = @min(max_rows, @as(u16, @intCast(@min(rows + 1, std.math.maxInt(u16)))));
    if (popup_height == 0) return;

    const start_col: u16 = 0;
    const start_row: u16 = max_rows - popup_height;
    const end_col: u16 = @min(width, start_col + popup_width);
    const end_row: u16 = @min(max_rows, start_row + popup_height);
    fillOverlay(surface, .{ .row = start_row, .col = start_col, .end_row = end_row, .end_col = end_col }, popupBg(maybe_theme));

    const content_col: u16 = @min(start_col + 1, end_col);
    const content_end_col: u16 = if (end_col > content_col) end_col - 1 else end_col;
    if (content_col >= content_end_col) return;

    var row = start_row;

    var col: u16 = content_col;
    col = writeText(surface, row, col, content_end_col, "Keys", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    if (which_key.prefix.len > 0) {
        col = writeText(surface, row, col, content_end_col, " ", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        col = writeText(surface, row, col, content_end_col, which_key.prefix, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    }
    if (which_key.page_count > 1) {
        var page_buf: [32]u8 = undefined;
        const page_text = std.fmt.bufPrint(&page_buf, "  {d}/{d}", .{ which_key.page +| 1, @max(which_key.page_count, 1) }) catch "";
        _ = writeAsciiStableText(surface, row, col, content_end_col, page_text, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    }

    row += 1;
    var index: usize = 0;
    while (row < end_row and index < which_key.bindings.len) : ({
        row += 1;
        index += 1;
    }) {
        _ = renderWhichKeyBinding(surface, row, content_col, content_end_col, which_key.bindings[index], maybe_theme);
    }
}

fn renderWhichKeyBinding(surface: anytype, row: u16, start_col: u16, end_col: u16, binding: WhichKeyBinding, maybe_theme: ?Theme) u16 {
    var col = start_col;
    col = writeText(surface, row, col, end_col, " ", popupSelectionFg(maybe_theme), popupSelectionBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, end_col, std.mem.trim(u8, binding.key, " \t\r\n"), popupSelectionFg(maybe_theme), popupSelectionBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, end_col, " ", popupSelectionFg(maybe_theme), popupSelectionBg(maybe_theme), protocol.ATTR_BOLD);
    if (col < end_col) col = writeText(surface, row, col, end_col, " ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
    if (binding.icon.len > 0 and col < end_col) {
        col = writeText(surface, row, col, end_col, binding.icon, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, row, col, end_col, " ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    if (col < end_col) col = writeText(surface, row, col, end_col, binding.description, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    return col;
}

fn renderCompletion(surface: anytype, completion: Completion, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!completion.visible or completion.items.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const popup_width = completionPopupWidth(completion, width);
    const popup_height: u16 = @min(@min(max_rows, 10), @as(u16, @intCast(@min(completion.items.len + 2, std.math.maxInt(u16)))));
    const rect = anchoredOverlayRect(width, max_rows, completion.cursor_col, completion.cursor_row +| 1, popup_width, popup_height) orelse return;
    fillOverlay(surface, rect, popupBg(maybe_theme));

    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col) return;

    var row = rect.row;
    _ = writeText(surface, row, content_col, content_end_col, "Completion", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);

    row += 1;
    var index: usize = 0;
    while (row < rect.end_row and index < completion.items.len) : ({
        row += 1;
        index += 1;
    }) {
        const item = completion.items[index];
        const selected = index == completion.selected_index;
        const fg = if (selected) popupSelectionFg(maybe_theme) else popupFg(maybe_theme);
        const bg = if (selected) popupSelectionBg(maybe_theme) else popupBg(maybe_theme);
        fillRowRangeWith(surface, row, content_col, content_end_col, bg);
        var col: u16 = content_col;
        col = writeText(surface, row, col, content_end_col, item.label, fg, bg, 0);
        if (item.detail.len > 0) {
            col = writeText(surface, row, col, content_end_col, "  ", fg, bg, 0);
            _ = writeText(surface, row, col, content_end_col, item.detail, fg, bg, 0);
        }
    }
}

fn completionPopupWidth(completion: Completion, area_width: u16) u16 {
    if (area_width == 0) return 0;
    var max_width: u16 = @min(area_width, 20);
    for (completion.items) |item| {
        const item_width = textWidth(item.label) +| textWidth(item.detail) +| 3;
        max_width = @max(max_width, @min(item_width, area_width));
    }
    return max_width;
}

fn renderPicker(surface: anytype, picker: Picker, maybe_preview: ?PickerPreview, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!picker.visible) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const popup_width = pickerPopupWidth(width);
    const popup_height = @min(max_rows, @max(@as(u16, 8), (max_rows * 3) / 4));
    const rect = centeredOverlayRect(surface, popup_width, popup_height, has_minibuffer, has_status_bar) orelse return;
    fillOverlay(surface, rect, popupBg(maybe_theme));

    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col) return;

    const preview = if (maybe_preview) |preview| if (preview.visible and preview.lines.len > 0 and width >= 100) preview else null else null;
    if (preview) |visible_preview| {
        const content_width = content_end_col - content_col;
        const left_width: u16 = @min(@max((content_width * 45) / 100, 36), @max(content_width -| 20, 1));
        const split_col = @min(content_end_col, content_col + left_width);
        renderPickerList(surface, picker, rect.row, rect.end_row -| 1, content_col, split_col, maybe_theme);
        renderPickerPreviewContent(surface, visible_preview, rect.row, rect.end_row -| 1, split_col, content_end_col, maybe_theme);
    } else {
        renderPickerList(surface, picker, rect.row, rect.end_row -| 1, content_col, content_end_col, maybe_theme);
    }
    if (rect.end_row > rect.row) renderPickerHelp(surface, picker, rect.end_row - 1, content_col, content_end_col, maybe_theme);
}

fn pickerPopupWidth(area_width: u16) u16 {
    if (area_width <= 24) return @max(area_width, 1);
    if (area_width >= 120) return @min(area_width - 8, 120);
    return @min(area_width - 4, @max(@as(u16, 48), @as(u16, @intCast((@as(u32, area_width) * 9) / 10))));
}

fn renderPickerList(surface: anytype, picker: Picker, start_row: u16, end_row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) void {
    if (start_col >= end_col or start_row >= end_row) return;

    var row = start_row;
    renderPickerTitle(surface, picker, row, start_col, end_col, maybe_theme);
    row += 1;

    const row_budget: usize = @intCast(end_row - row);
    const selected: usize = if (picker.items.len == 0) 0 else @min(@as(usize, picker.selected_index), picker.items.len - 1);
    const start_index: usize = if (selected >= row_budget and row_budget > 0) selected - row_budget + 1 else 0;
    const end_index: usize = @min(start_index + row_budget, picker.items.len);
    var index = start_index;
    while (row < end_row and index < end_index) : ({
        row += 1;
        index += 1;
    }) {
        renderPickerItem(surface, picker.items[index], index == selected, row, start_col, end_col, maybe_theme);
    }
}

fn renderPickerTitle(surface: anytype, picker: Picker, row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) void {
    fillRowRangeWith(surface, row, start_col, end_col, popupBg(maybe_theme));
    var col = start_col;
    const title = if (picker.title.len > 0) picker.title else "Picker";
    col = writeText(surface, row, col, end_col, title, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    if (picker.query.len > 0) {
        col = writeText(surface, row, col, end_col, "  ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, row, col, end_col, picker.query, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    if (picker.marked_count > 0) {
        col = writeText(surface, row, col, end_col, "  marked ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        var marked_buf: [12]u8 = undefined;
        const marked_text = std.fmt.bufPrint(&marked_buf, "{d}", .{picker.marked_count}) catch "";
        col = writeAsciiStableText(surface, row, col, end_col, marked_text, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    if (picker.load_status == 1) {
        _ = writeText(surface, row, col, end_col, "  loading", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    } else if (picker.load_status == 2 and picker.load_error.len > 0) {
        col = writeText(surface, row, col, end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, row, col, end_col, picker.load_error, diagnosticColor(maybe_theme, 1), popupBg(maybe_theme), protocol.ATTR_BOLD);
    }
}

fn renderPickerItem(surface: anytype, item: PickerItem, selected: bool, row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) void {
    const bg = popupBg(maybe_theme);
    fillRowRangeWith(surface, row, start_col, end_col, bg);
    var col = start_col;
    const marker = if (selected) "▌" else if (item.marked()) "*" else " ";
    const marker_fg = if (selected) accentFg(maybe_theme) else if (item.marked()) diagnosticColor(maybe_theme, 1) else mutedFg(maybe_theme);
    col = writeText(surface, row, col, end_col, marker, marker_fg, bg, if (selected) protocol.ATTR_BOLD else 0);
    col = writeText(surface, row, col, end_col, " ", popupFg(maybe_theme), bg, 0);
    const label_fg = if (selected) popupSelectionFg(maybe_theme) else popupFg(maybe_theme);
    col = writeText(surface, row, col, end_col, item.label, label_fg, bg, if (selected) protocol.ATTR_BOLD else 0);
    const detail = if (item.description.len > 0) item.description else item.annotation;
    if (detail.len > 0) {
        col = writeText(surface, row, col, end_col, "  ", mutedFg(maybe_theme), bg, 0);
        _ = writeText(surface, row, col, end_col, detail, mutedFg(maybe_theme), bg, 0);
    }
}

fn renderPickerHelp(surface: anytype, picker: Picker, row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) void {
    if (start_col >= end_col) return;
    fillRowRangeWith(surface, row, start_col, end_col, popupBg(maybe_theme));
    var col = start_col;
    var count_buf: [32]u8 = undefined;
    const selected_display: usize = if (picker.items.len == 0) 0 else @min(@as(usize, picker.selected_index) + 1, picker.items.len);
    const left = std.fmt.bufPrint(&count_buf, " {d}/{d}", .{ selected_display, picker.items.len }) catch "";
    col = writeAsciiStableText(surface, row, col, end_col, left, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    if (end_col > start_col + 31) {
        const right = "↑↓ move  Enter choose  Esc close";
        const right_width: u16 = textWidth(right);
        const right_col: u16 = if (end_col > right_width) end_col - right_width else col;
        _ = writeText(surface, row, right_col, end_col, right, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
}

fn renderPickerPreview(surface: anytype, preview: PickerPreview, has_picker: bool, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!preview.visible) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const split_preview = has_picker and width >= 40;
    const start_col: u16 = if (split_preview) width / 2 else 0;
    const max_col: u16 = width;
    const row_count: u16 = @min(max_rows, @as(u16, @intCast(@min(preview.lines.len + 1, 8))));
    const start_row: u16 = max_rows - row_count;
    const rect = OverlayRect{ .row = start_row, .col = start_col, .end_row = start_row + row_count, .end_col = max_col };
    fillOverlay(surface, rect, popupBg(maybe_theme));
    renderPickerPreviewContent(surface, preview, rect.row, rect.end_row, rect.col, rect.end_col, maybe_theme);
}

fn renderPickerPreviewContent(surface: anytype, preview: PickerPreview, start_row: u16, end_row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) void {
    if (start_col >= end_col or start_row >= end_row) return;

    var row = start_row;
    fillRowRangeWith(surface, row, start_col, end_col, popupBg(maybe_theme));
    _ = writeText(surface, row, start_col, end_col, "Preview", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;
    var index: usize = 0;
    while (row < end_row and index < preview.lines.len) : ({
        row += 1;
        index += 1;
    }) {
        const line = preview.lines[index];
        fillRowRangeWith(surface, row, start_col, end_col, popupBg(maybe_theme));
        var col = start_col;
        for (line.segments) |segment| {
            const attrs: u8 = if (segment.bold) protocol.ATTR_BOLD else 0;
            col = writeText(surface, row, col, end_col, segment.text, if (segment.fg != 0) segment.fg else popupFg(maybe_theme), popupBg(maybe_theme), attrs);
        }
    }
}

fn renderHoverPopup(surface: anytype, hover: HoverPopup, maybe_action: ?HoverAction, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!hover.visible or hover.lines.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const popup_width: u16 = @min(width, 52);
    const action_rows: usize = if (maybe_action) |action| if (action.visible and action.name.len > 0) 1 else 0 else 0;
    const popup_height: u16 = @min(max_rows, @as(u16, @intCast(@min(hover.lines.len + action_rows + 2, 8))));
    const rect = anchoredOverlayRect(width, max_rows, hover.anchor_col, hover.anchor_row +| 1, popup_width, popup_height) orelse return;
    fillOverlay(surface, rect, popupBg(maybe_theme));

    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col) return;

    var row = rect.row;
    var title_buf: [48]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Hover {d}:{d}", .{ hover.anchor_row +| 1, hover.anchor_col +| 1 }) catch "Hover";
    _ = writeAsciiStableText(surface, row, content_col, content_end_col, title, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;
    var index: usize = 0;
    while (row < rect.end_row and index < hover.lines.len) : ({
        row += 1;
        index += 1;
    }) {
        const line = hover.lines[index];
        var col = content_col;
        for (line.segments) |segment| {
            const attrs: u8 = hoverSegmentAttrs(segment);
            col = writeText(surface, row, col, content_end_col, segment.text, if (segment.fg != 0) segment.fg else popupFg(maybe_theme), popupBg(maybe_theme), attrs);
        }
    }
    if (row < rect.end_row) {
        if (maybe_action) |action| {
            if (action.visible and action.name.len > 0) {
                _ = writeText(surface, row, content_col, content_end_col, action.name, accentFg(maybe_theme), popupBg(maybe_theme), 0);
            }
        }
    }
}

fn hoverSegmentAttrs(segment: HoverSegment) u8 {
    if (segment.style == 13) return segment.flags & (protocol.ATTR_BOLD | protocol.ATTR_UNDERLINE | protocol.ATTR_ITALIC);
    return switch (segment.style) {
        1, 3, 7, 8, 9 => protocol.ATTR_BOLD,
        2 => protocol.ATTR_ITALIC,
        else => 0,
    };
}

fn renderSignatureHelp(surface: anytype, help: SignatureHelp, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!help.visible or help.signatures.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const active_index: usize = @min(@as(usize, help.active_signature), help.signatures.len - 1);
    const signature = help.signatures[active_index];
    const popup_width: u16 = @min(width, 48);
    const content_count = 1 + @as(usize, if (signature.documentation.len > 0) 1 else 0) + signature.parameters.len;
    const popup_height: u16 = @min(max_rows, @as(u16, @intCast(@min(content_count + 2, 8))));
    const rect = anchoredOverlayRect(width, max_rows, help.anchor_col, help.anchor_row +| 2, popup_width, popup_height) orelse return;
    fillOverlay(surface, rect, popupBg(maybe_theme));

    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col) return;

    var row = rect.row;
    _ = writeText(surface, row, content_col, content_end_col, signature.label, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    if (row < rect.end_row and signature.documentation.len > 0) {
        _ = writeText(surface, row, content_col, content_end_col, signature.documentation, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        row += 1;
    }

    var param_index: usize = 0;
    while (row < rect.end_row and param_index < signature.parameters.len) : ({
        row += 1;
        param_index += 1;
    }) {
        const parameter = signature.parameters[param_index];
        const active = param_index == help.active_parameter;
        const fg = popupFg(maybe_theme);
        const bg = popupBg(maybe_theme);
        var col = content_col;
        if (active) col = writeText(surface, row, col, content_end_col, "> ", fg, bg, 0);
        col = writeText(surface, row, col, content_end_col, parameter.label, fg, bg, 0);
        if (parameter.documentation.len > 0) {
            col = writeText(surface, row, col, content_end_col, "  ", fg, bg, 0);
            _ = writeText(surface, row, col, content_end_col, parameter.documentation, fg, bg, 0);
        }
    }
}

fn renderFloatPopup(surface: anytype, popup: FloatPopup, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!popup.visible) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const max_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (max_rows == 0) return;

    const popup_width = boundedDimension(popup.width, 20, width);
    const popup_height = boundedDimension(popup.height, 3, max_rows);
    const rect = centeredOverlayRect(surface, popup_width, popup_height, has_minibuffer, has_status_bar) orelse return;
    fillOverlay(surface, rect, popupBg(maybe_theme));

    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col) return;

    var row = rect.row;
    const title = if (popup.title.len > 0) popup.title else "Popup";
    _ = writeText(surface, row, content_col, content_end_col, title, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);

    row += 1;
    var index: usize = 0;
    while (row < rect.end_row and index < popup.lines.len) : ({
        row += 1;
        index += 1;
    }) {
        _ = writeText(surface, row, content_col, content_end_col, popup.lines[index], popupFg(maybe_theme), popupBg(maybe_theme), 0);
    }
}

fn renderAgentContext(surface: anytype, context: AgentContext, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!context.visible) return;

    const rect = centeredOverlayRect(surface, 60, if (context.can_approve) 5 else 3, has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    _ = writeText(surface, row, content.col, content.end_col, "Agent context", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;
    row = renderPopupListItem(surface, row, content.end_row, content.col, content.end_col, agentContextStatusLabel(context.status), context.task, true, maybe_theme);
    if (context.can_approve) _ = renderPopupListItem(surface, row, content.end_row, content.col, content.end_col, "approval", "approve or request changes", false, maybe_theme);
}

fn renderToolManager(surface: anytype, manager: ToolManager, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!manager.visible) return;

    const item_count = @max(manager.tools.len, 1);
    const row_count: u16 = @as(u16, @intCast(@min(item_count * 2, 9))) + 1;
    const rect = centeredOverlayRect(surface, 60, @max(@as(u16, 3), row_count), has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    _ = writeText(surface, row, content.col, content.end_col, "Tool manager", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    if (manager.tools.len == 0 and row < content.end_row) {
        _ = renderPopupListItem(surface, row, content.end_row, content.col, content.end_col, "No tools", "No matching tools", true, maybe_theme);
        return;
    }

    const selected_index: usize = @min(@as(usize, manager.selected), manager.tools.len - 1);
    var index: usize = 0;
    while (row < content.end_row and index < manager.tools.len) : (index += 1) {
        const tool = manager.tools[index];
        const selected = index == selected_index;
        var detail_buf: [96]u8 = undefined;
        const description = std.fmt.bufPrint(&detail_buf, "{s} {s}", .{ tool.name, toolStatusLabel(tool.status) }) catch tool.name;
        row = renderPopupListItem(surface, row, content.end_row, content.col, content.end_col, tool.label, std.mem.trim(u8, description, " "), selected, maybe_theme);
    }
}

fn renderBoard(surface: anytype, board: Board, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!board.visible or board.cards.len == 0) return;

    const row_count: u16 = @as(u16, @intCast(@min(board.cards.len * 2, 9))) + 1;
    const rect = centeredOverlayRect(surface, 70, @max(@as(u16, 3), row_count), has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    var col = content.col;
    col = writeText(surface, row, col, content.end_col, "Board  ", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    var count_buf: [16]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{d}", .{board.cards.len}) catch "";
    col = writeAsciiStableText(surface, row, col, content.end_col, count, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    _ = writeText(surface, row, col, content.end_col, " cards", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    var selected_index: usize = 0;
    for (board.cards, 0..) |card, card_index| {
        if (card.id == board.focused_card_id or card.flags & 0x02 != 0) {
            selected_index = card_index;
            break;
        }
    }

    var index: usize = 0;
    while (row < content.end_row and index < board.cards.len) : (index += 1) {
        const card = board.cards[index];
        const focused = index == selected_index;
        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} {s}", .{ if (focused) ">" else " ", boardStatusLabel(card.status) }) catch boardStatusLabel(card.status);
        row = renderPopupListItem(surface, row, content.end_row, content.col, content.end_col, title, card.task, focused, maybe_theme);
    }
}

fn renderPopupListItem(surface: anytype, row: u16, end_row: u16, start_col: u16, end_col: u16, title: []const u8, description: []const u8, selected: bool, maybe_theme: ?Theme) u16 {
    if (row >= end_row or start_col >= end_col) return row;

    const bg = if (selected) popupSelectionBg(maybe_theme) else popupBg(maybe_theme);
    const title_fg = if (selected) popupSelectionFg(maybe_theme) else popupFg(maybe_theme);
    const desc_fg = if (selected) popupSelectionFg(maybe_theme) else mutedFg(maybe_theme);
    const attrs: u8 = if (selected) protocol.ATTR_BOLD else 0;

    fillRowRangeWith(surface, row, start_col, end_col, bg);
    var col = start_col;
    if (selected) col = writeText(surface, row, col, end_col, " ", title_fg, bg, 0);
    col = writeText(surface, row, col, end_col, title, title_fg, bg, attrs);
    if (selected) _ = writeText(surface, row, col, end_col, " ", title_fg, bg, 0);

    var next_row = row + 1;
    if (description.len > 0 and next_row < end_row) {
        fillRowRangeWith(surface, next_row, start_col, end_col, bg);
        col = start_col;
        if (selected) col = writeText(surface, next_row, col, end_col, " ", desc_fg, bg, 0);
        _ = writeText(surface, next_row, col, end_col, description, desc_fg, bg, 0);
        next_row += 1;
    }

    return next_row;
}

fn renderAgentChat(surface: anytype, chat: AgentChat, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!chat.visible) return;

    const surface_width = surface.width();
    const surface_height = surface.height();
    if (surface_width == 0 or surface_height == 0) return;
    const preferred_width = @min(surface_width, @max(@as(u16, 40), @as(u16, @intCast((@as(u32, surface_width) * 3) / 4))));
    const preferred_height = @min(surface_height, @max(@as(u16, 8), @as(u16, @intCast((@as(u32, surface_height) * 3) / 4))));
    const rect = centeredOverlayRect(surface, preferred_width, preferred_height, has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    const details_visible = content.end_col - content.col >= 104 and content.end_row > content.row + 5;
    const details_width: u16 = if (details_visible) @min(@max((content.end_col - content.col) / 5, @as(u16, 24)), @as(u16, 30)) else 0;
    const details_col: u16 = if (details_visible) content.end_col - details_width else content.end_col;
    const main_end_col: u16 = if (details_visible and details_col > content.col + 3) details_col - 3 else content.end_col;

    var row = content.row;
    var col = content.col;
    col = writeText(surface, row, col, main_end_col, "Agent", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, main_end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    if (chat.model_name.len > 0) {
        col = writeText(surface, row, col, main_end_col, chat.model_name, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, row, col, main_end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    _ = writeText(surface, row, col, main_end_col, agentChatStatusLabel(chat.status), mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    if (details_visible) renderAgentDetailsRail(surface, chat, content.row, content.end_row, details_col, content.end_col, maybe_theme);
    row += 1;

    if (chat.pending.len > 0 and row < content.end_row) {
        col = content.col;
        col = writeText(surface, row, col, main_end_col, "approval  ", mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        _ = writeText(surface, row, col, main_end_col, chat.pending, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        row += 1;
    }
    if (chat.thinking_level.len > 0 and row < content.end_row) {
        col = content.col;
        col = writeText(surface, row, col, main_end_col, "thinking: ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, row, col, main_end_col, chat.thinking_level, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        row += 1;
    }
    var main_content = content;
    main_content.end_col = main_end_col;
    if (row < content.end_row) {
        _ = writeText(surface, row, content.col, main_end_col, "Transcript", mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        row += 1;
    }
    if (chat.messages.len > 0) {
        row = renderAgentChatMessages(surface, chat, row, main_content, maybe_theme, chat.prompt.len > 0);
    } else if (chat.pending.len == 0 and chat.prompt.len == 0 and row < content.end_row) {
        _ = writeText(surface, row, content.col, main_end_col, "Minga is ready", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        row += 1;
        if (row < content.end_row) {
            _ = writeText(surface, row, content.col, main_end_col, "Ask in plain language, or start with a slash command.", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
            row += 1;
        }
        row = renderAgentLandingSuggestions(surface, row, main_content, maybe_theme);
    }
    if (row < content.end_row) {
        row = renderAgentChatStatusLine(surface, chat, row, main_content, maybe_theme);
    }
    if (chat.prompt.len > 0 and row < content.end_row) {
        _ = renderAgentComposer(surface, chat, row, main_content, maybe_theme);
    }
}

fn renderAgentComposer(surface: anytype, chat: AgentChat, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (rect.end_col <= rect.col + 4 or next_row >= rect.end_row) return next_row;
    _ = writeText(surface, next_row, rect.col, rect.end_col, "Prompt", mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    next_row += 1;
    if (next_row < rect.end_row) {
        var col = rect.col;
        col = writeText(surface, next_row, col, rect.end_col, "> ", if (chat.status == 1 or chat.status == 2) diagnosticColor(maybe_theme, 1) else accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        col = writeText(surface, next_row, col, rect.end_col, agentPromptModeName(chat.prompt_vim_mode), accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        col = writeText(surface, next_row, col, rect.end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, col, rect.end_col, if (chat.prompt.len > 0) chat.prompt else "Ask Minga to edit, explain, search, or run tools", if (chat.prompt.len > 0) popupFg(maybe_theme) else mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    if (next_row < rect.end_row) {
        var cursor_buf: [64]u8 = undefined;
        const cursor = std.fmt.bufPrint(&cursor_buf, "Enter send · Esc normal · / commands · {d}:{d}", .{ chat.prompt_cursor_line + 1, chat.prompt_cursor_col + 1 }) catch "";
        _ = writeText(surface, next_row, rect.col, rect.end_col, cursor, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    return next_row;
}

fn agentPromptModeName(mode: u8) []const u8 {
    return switch (mode) {
        1 => "INSERT",
        2 => "VISUAL",
        3 => "COMMAND",
        4 => "OP",
        5 => "SEARCH",
        6 => "REPLACE",
        else => "NORMAL",
    };
}

fn renderAgentDetailsRail(surface: anytype, chat: AgentChat, start_row: u16, end_row: u16, start_col: u16, end_col: u16, maybe_theme: ?Theme) void {
    var row = start_row;
    row = renderAgentDetailTitle(surface, row, end_row, start_col, end_col, "Session", maybe_theme);
    const model_parts = splitAgentModelName(chat.model_name);
    row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Provider", if (model_parts.provider.len > 0) model_parts.provider else "unknown", maybe_theme);
    row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Model", if (model_parts.model.len > 0) model_parts.model else "not selected", maybe_theme);
    row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "State", agentChatStatusLabel(chat.status), maybe_theme);
    if (chat.thinking_level.len > 0) row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Thinking", chat.thinking_level, maybe_theme);
    var count_buf: [16]u8 = undefined;
    const messages = std.fmt.bufPrint(&count_buf, "{d}", .{chat.messages.len}) catch "";
    row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Messages", messages, maybe_theme);
    const tool_counts = agentToolCounts(chat.messages);
    if (tool_counts.total > 0) {
        var tool_buf: [64]u8 = undefined;
        const tool_text = if (tool_counts.running > 0 or tool_counts.errors > 0)
            std.fmt.bufPrint(&tool_buf, "{d} · {d} running · {d} errors", .{ tool_counts.total, tool_counts.running, tool_counts.errors }) catch ""
        else
            std.fmt.bufPrint(&tool_buf, "{d}", .{tool_counts.total}) catch "";
        row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Tools", tool_text, maybe_theme);
    }
    if (chat.pending.len > 0) row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Approval", "waiting", maybe_theme);
    if (lastAgentError(chat.messages).len > 0) {
        row = renderAgentDetailSection(surface, row, end_row, start_col, end_col, "Needs attention", maybe_theme);
        row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Auth", "run /auth or check API key", maybe_theme);
    }
    if (lastAgentUsage(chat.messages)) |usage| {
        var usage_buf: [64]u8 = undefined;
        const context = formatAgentUsage(&usage_buf, usage.usage_input, usage.usage_output);
        row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Context", context, maybe_theme);
        if (usage.usage_cost_micros > 0) {
            var cost_buf: [32]u8 = undefined;
            const dollars = usage.usage_cost_micros / 1000000;
            const cents = (usage.usage_cost_micros % 1000000) / 10000;
            const cost = if (cents < 10)
                std.fmt.bufPrint(&cost_buf, "${d}.0{d}", .{ dollars, cents }) catch ""
            else
                std.fmt.bufPrint(&cost_buf, "${d}.{d}", .{ dollars, cents }) catch "";
            row = renderAgentDetailRow(surface, row, end_row, start_col, end_col, "Cost", cost, maybe_theme);
        }
    }
    row = renderAgentDetailSection(surface, row, end_row, start_col, end_col, "Hints", maybe_theme);
    row = renderAgentDetailHint(surface, row, end_row, start_col, end_col, "Enter", "send prompt", maybe_theme);
    row = renderAgentDetailHint(surface, row, end_row, start_col, end_col, "Tab", "complete", maybe_theme);
    _ = renderAgentDetailHint(surface, row, end_row, start_col, end_col, "?", "agent help", maybe_theme);
}

const AgentModelParts = struct {
    provider: []const u8,
    model: []const u8,
};

const AgentToolCounts = struct {
    total: u16,
    running: u16,
    errors: u16,
};

fn splitAgentModelName(value: []const u8) AgentModelParts {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |index| {
        return .{
            .provider = std.mem.trim(u8, trimmed[0..index], " \t\r\n"),
            .model = std.mem.trim(u8, trimmed[index + 1 ..], " \t\r\n"),
        };
    }
    return .{ .provider = "", .model = trimmed };
}

fn agentToolCounts(messages: []const AgentChatMessage) AgentToolCounts {
    var counts = AgentToolCounts{ .total = 0, .running = 0, .errors = 0 };
    for (messages) |message| {
        if (message.kind != 0x04 and message.kind != 0x08 and message.kind != 0x09) continue;
        counts.total += 1;
        if (message.status == 0) counts.running += 1;
        if (message.status == 2 or message.is_error) counts.errors += 1;
    }
    return counts;
}

fn lastAgentError(messages: []const AgentChatMessage) []const u8 {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const message = messages[index];
        if (message.kind == 0x05 and message.status == 1 and message.text.len > 0) return message.text;
        if (message.is_error and message.text.len > 0) return message.text;
    }
    return "";
}

fn lastAgentUsage(messages: []const AgentChatMessage) ?AgentChatMessage {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        if (messages[index].kind == 0x06) return messages[index];
    }
    return null;
}

fn formatAgentUsage(buf: []u8, input: u32, output: u32) []const u8 {
    var input_buf: [16]u8 = undefined;
    var output_buf: [16]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} in · {s} out", .{ formatAgentTokens(&input_buf, input), formatAgentTokens(&output_buf, output) }) catch "";
}

fn formatAgentCost(buf: []u8, cost_micros: u32) []const u8 {
    const dollars = cost_micros / 1000000;
    const cents = (cost_micros % 1000000) / 10000;
    return if (cents < 10)
        std.fmt.bufPrint(buf, "${d}.0{d}", .{ dollars, cents }) catch ""
    else
        std.fmt.bufPrint(buf, "${d}.{d}", .{ dollars, cents }) catch "";
}

fn formatAgentTokens(buf: []u8, value: u32) []const u8 {
    if (value >= 1000000) return std.fmt.bufPrint(buf, "{d}.{d}M", .{ value / 1000000, (value % 1000000) / 100000 }) catch "";
    if (value >= 1000) return std.fmt.bufPrint(buf, "{d}.{d}K", .{ value / 1000, (value % 1000) / 100 }) catch "";
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
}

const AgentToolPresentation = struct {
    title: []const u8,
    summary_label: []const u8,
    result_label: []const u8,
};

fn agentToolPresentation(name: []const u8) AgentToolPresentation {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "shell") or std.mem.eql(u8, trimmed, "bash")) return .{ .title = "Shell", .summary_label = "cmd", .result_label = "output" };
    if (std.mem.eql(u8, trimmed, "read_file")) return .{ .title = "Read", .summary_label = "path", .result_label = "content" };
    if (std.mem.eql(u8, trimmed, "write_file")) return .{ .title = "Write", .summary_label = "path", .result_label = "content" };
    if (std.mem.eql(u8, trimmed, "edit_file") or std.mem.eql(u8, trimmed, "multi_edit_file")) return .{ .title = "Edit", .summary_label = "path", .result_label = "diff" };
    if (std.mem.eql(u8, trimmed, "apply_diff")) return .{ .title = "Diff", .summary_label = "patch", .result_label = "diff" };
    if (std.mem.eql(u8, trimmed, "todo")) return .{ .title = "Todo", .summary_label = "task", .result_label = "state" };
    if (std.mem.eql(u8, trimmed, "subagent")) return .{ .title = "Subagent", .summary_label = "task", .result_label = "report" };
    if (std.mem.startsWith(u8, trimmed, "lsp_")) return .{ .title = "LSP", .summary_label = "query", .result_label = "result" };
    if (std.mem.eql(u8, trimmed, "git") or std.mem.eql(u8, trimmed, "git_stage") or std.mem.eql(u8, trimmed, "git_commit")) return .{ .title = "Git", .summary_label = "op", .result_label = "result" };
    return .{ .title = "Tool", .summary_label = "args", .result_label = "result" };
}

fn agentToolStatusIcon(message: AgentChatMessage) []const u8 {
    if (message.is_error or message.status == 2) return "x";
    if (message.status == 1) return "v";
    return "*";
}

fn agentToolStatusColor(message: AgentChatMessage, maybe_theme: ?Theme) u24 {
    if (message.is_error or message.status == 2) return diagnosticColor(maybe_theme, 0);
    if (message.status == 1) return diagnosticColor(maybe_theme, 3);
    return diagnosticColor(maybe_theme, 1);
}

fn agentToolMeta(buf: []u8, message: AgentChatMessage) []const u8 {
    const approval = switch (message.auto_approved_scope) {
        1 => "auto session",
        2 => "auto turn",
        else => "",
    };
    if (message.duration_ms > 0 and approval.len > 0) return std.fmt.bufPrint(buf, "{d}ms · {s}", .{ message.duration_ms, approval }) catch "";
    if (message.duration_ms > 0) return std.fmt.bufPrint(buf, "{d}ms", .{message.duration_ms}) catch "";
    return approval;
}

fn approvalPreviewKindName(kind: u8) []const u8 {
    return switch (kind) {
        1 => "diff",
        2 => "command",
        3 => "target",
        else => "args",
    };
}

fn renderAgentDetailTitle(surface: anytype, row: u16, end_row: u16, start_col: u16, end_col: u16, title: []const u8, maybe_theme: ?Theme) u16 {
    if (row >= end_row) return row;
    var col = start_col;
    col = writeText(surface, row, col, end_col, "Session", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    if (!std.mem.eql(u8, title, "Session")) {
        col = writeText(surface, row, col, end_col, " ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, row, col, end_col, title, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    }
    return row + 1;
}

fn renderAgentDetailSection(surface: anytype, row: u16, end_row: u16, start_col: u16, end_col: u16, label: []const u8, maybe_theme: ?Theme) u16 {
    if (row >= end_row) return row;
    _ = writeText(surface, row, start_col, end_col, label, mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    return row + 1;
}

fn renderAgentDetailRow(surface: anytype, row: u16, end_row: u16, start_col: u16, end_col: u16, label: []const u8, value: []const u8, maybe_theme: ?Theme) u16 {
    if (row >= end_row) return row;
    const label_width: u16 = @min(@max((end_col - start_col) / 3, @as(u16, 8)), @as(u16, 10));
    const value_col: u16 = @min(end_col, start_col + label_width + 1);
    _ = writeText(surface, row, start_col, value_col, label, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    _ = writeText(surface, row, value_col, end_col, value, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    return row + 1;
}

fn renderAgentDetailHint(surface: anytype, row: u16, end_row: u16, start_col: u16, end_col: u16, key: []const u8, action: []const u8, maybe_theme: ?Theme) u16 {
    if (row >= end_row) return row;
    var col = start_col;
    col = writeText(surface, row, col, end_col, key, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    _ = writeText(surface, row, col, end_col, action, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    return row + 1;
}

fn renderAgentLandingSuggestions(surface: anytype, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (next_row < rect.end_row) {
        _ = writeText(surface, next_row, rect.col, rect.end_col, "Suggested next moves", mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
        next_row += 1;
    }
    next_row = renderAgentSuggestionRow(surface, next_row, rect, "/explain", "Explain this file", "/tests", "Find failing tests", maybe_theme);
    next_row = renderAgentSuggestionRow(surface, next_row, rect, "/review", "Review changes", "/edit", "Edit current buffer", maybe_theme);
    next_row = renderAgentSuggestionRow(surface, next_row, rect, "/run", "Run a command", "/plan", "Draft a plan", maybe_theme);
    return next_row;
}

fn renderAgentSuggestionRow(surface: anytype, row: u16, rect: OverlayRect, left_command: []const u8, left_label: []const u8, right_command: []const u8, right_label: []const u8, maybe_theme: ?Theme) u16 {
    if (row >= rect.end_row) return row;
    var col = rect.col;
    col = writeText(surface, row, col, rect.end_col, left_command, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, rect.end_col, " ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, row, col, rect.end_col, left_label, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, row, col, rect.end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, row, col, rect.end_col, right_command, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, rect.end_col, " ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
    _ = writeText(surface, row, col, rect.end_col, right_label, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    return row + 1;
}

fn renderAgentChatMessages(surface: anytype, chat: AgentChat, start_row: u16, rect: OverlayRect, maybe_theme: ?Theme, has_prompt: bool) u16 {
    var row = start_row;
    const prompt_rows: u16 = if (has_prompt and rect.end_row > row + 1) 2 else 0;
    const available_rows: usize = rect.end_row -| row -| prompt_rows;
    const first_index: usize = if (chat.messages.len > available_rows) chat.messages.len - available_rows else 0;
    var index = first_index;
    while (row < rect.end_row -| prompt_rows and index < chat.messages.len) : (index += 1) {
        row = renderAgentChatMessage(surface, chat.messages[index], row, rect, maybe_theme);
    }
    return row;
}

fn renderAgentChatMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    return switch (message.kind) {
        0x01 => renderAgentUserMessage(surface, message, row, rect, maybe_theme),
        0x02, 0x07 => renderAgentAssistantMessage(surface, message, row, rect, maybe_theme),
        0x03 => renderAgentThinkingMessage(surface, message, row, rect, maybe_theme),
        0x04, 0x08 => renderAgentToolMessage(surface, message, row, rect, maybe_theme),
        0x05 => renderAgentSystemMessage(surface, message, row, rect, maybe_theme),
        0x06 => renderAgentUsageMessage(surface, message, row, rect, maybe_theme),
        0x09 => renderAgentApprovalMessage(surface, message, row, rect, maybe_theme),
        else => renderAgentAssistantMessage(surface, message, row, rect, maybe_theme),
    };
}

fn renderAgentUserMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (next_row >= rect.end_row) return next_row;
    _ = writeText(surface, next_row, rect.col, rect.end_col, "  > You", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    next_row += 1;
    if (next_row < rect.end_row) {
        _ = writeText(surface, next_row, rect.col, rect.end_col, "    ", popupFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, rect.col + 4, rect.end_col, message.text, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    return next_row;
}

fn renderAgentAssistantMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (next_row >= rect.end_row) return next_row;
    _ = writeText(surface, next_row, rect.col, rect.end_col, "  ◇ Minga", popupFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    next_row += 1;
    if (next_row < rect.end_row) {
        var col = rect.col;
        col = writeText(surface, next_row, col, rect.end_col, "  │ ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, col, rect.end_col, messageText(message), popupFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    return next_row;
}

fn renderAgentThinkingMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (next_row >= rect.end_row) return next_row;
    const state = if (message.collapsed) "collapsed" else "expanded";
    var col = rect.col;
    col = writeText(surface, next_row, col, rect.end_col, "  ... Thinking ", mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    _ = writeText(surface, next_row, col, rect.end_col, state, mutedFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_ITALIC);
    next_row += 1;
    if (next_row < rect.end_row) {
        _ = writeText(surface, next_row, rect.col, rect.end_col, "    ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, rect.col + 4, rect.end_col, if (message.text.len > 0) message.text else "working through the request", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    return next_row;
}

fn renderAgentSystemMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    if (row >= rect.end_row) return row;
    const attention = message.status == 1 or message.is_error;
    const label = if (attention) "Needs attention" else "System";
    const fg = if (attention) diagnosticColor(maybe_theme, 0) else mutedFg(maybe_theme);
    var col = rect.col;
    col = writeText(surface, row, col, rect.end_col, if (attention) "  ! " else "  i ", fg, popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, rect.end_col, label, fg, popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, col, rect.end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    _ = writeText(surface, row, col, rect.end_col, message.text, if (attention) popupFg(maybe_theme) else mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    return row + 1;
}

fn renderAgentToolMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (next_row >= rect.end_row) return next_row;
    const presentation = agentToolPresentation(message.name);
    var col = rect.col;
    col = writeText(surface, next_row, col, rect.end_col, "  ├─ ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, next_row, col, rect.end_col, agentToolStatusIcon(message), agentToolStatusColor(message, maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, next_row, col, rect.end_col, " ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, next_row, col, rect.end_col, presentation.title, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, next_row, col, rect.end_col, " · ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, next_row, col, rect.end_col, if (message.name.len > 0) message.name else "tool", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    var meta_buf: [64]u8 = undefined;
    const meta = agentToolMeta(&meta_buf, message);
    if (meta.len > 0) {
        col = writeText(surface, next_row, col, rect.end_col, " · ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, col, rect.end_col, meta, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    next_row += 1;
    if (next_row < rect.end_row) {
        col = rect.col;
        col = writeText(surface, next_row, col, rect.end_col, "  │  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, next_row, col, rect.end_col, presentation.summary_label, accentFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, next_row, col, rect.end_col, ": ", accentFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, col, rect.end_col, if (message.summary.len > 0) message.summary else message.text, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    if (message.result.len > 0 and (!message.collapsed or message.is_error) and next_row < rect.end_row) {
        col = rect.col;
        col = writeText(surface, next_row, col, rect.end_col, "  │  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeText(surface, next_row, col, rect.end_col, if (message.is_error) "ERROR: " else presentation.result_label, if (message.is_error) diagnosticColor(maybe_theme, 0) else diagnosticColor(maybe_theme, 1), popupBg(maybe_theme), protocol.ATTR_BOLD);
        if (!message.is_error) col = writeText(surface, next_row, col, rect.end_col, ": ", diagnosticColor(maybe_theme, 1), popupBg(maybe_theme), protocol.ATTR_BOLD);
        _ = writeText(surface, next_row, col, rect.end_col, message.result, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        next_row += 1;
    }
    return next_row;
}

fn renderAgentApprovalMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var next_row = row;
    if (next_row >= rect.end_row) return next_row;
    var col = rect.col;
    col = writeText(surface, next_row, col, rect.end_col, "  ◆ Approval ", diagnosticColor(maybe_theme, 1), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, next_row, col, rect.end_col, if (message.name.len > 0) message.name else "tool", popupFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, next_row, col, rect.end_col, " · ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, next_row, col, rect.end_col, approvalPreviewKindName(message.preview_kind), accentFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, next_row, col, rect.end_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    _ = writeText(surface, next_row, col, rect.end_col, message.summary, popupFg(maybe_theme), popupBg(maybe_theme), 0);
    next_row += 1;
    var index: usize = 0;
    while (next_row < rect.end_row and index < @min(message.preview_lines.len, 2)) : ({
        next_row += 1;
        index += 1;
    }) {
        col = rect.col;
        col = writeText(surface, next_row, col, rect.end_col, "  │  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, next_row, col, rect.end_col, message.preview_lines[index], mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    return next_row;
}

fn renderAgentUsageMessage(surface: anytype, message: AgentChatMessage, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    if (row >= rect.end_row) return row;
    var usage_buf: [96]u8 = undefined;
    var col = rect.col;
    col = writeText(surface, row, col, rect.end_col, "  ◌ Usage · ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, row, col, rect.end_col, formatAgentUsage(&usage_buf, message.usage_input, message.usage_output), mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    if (message.usage_cost_micros > 0) {
        var cost_buf: [32]u8 = undefined;
        col = writeText(surface, row, col, rect.end_col, " · ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, row, col, rect.end_col, formatAgentCost(&cost_buf, message.usage_cost_micros), mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    return row + 1;
}

fn renderAgentChatStatusLine(surface: anytype, chat: AgentChat, row: u16, rect: OverlayRect, maybe_theme: ?Theme) u16 {
    var count_buf: [64]u8 = undefined;
    const message_count = if (chat.messages.len > 0) chat.messages.len else chat.message_count;
    const label: []const u8 = if (message_count == 1) "message" else "messages";
    const status = std.fmt.bufPrint(&count_buf, "{d} {s}", .{ message_count, label }) catch "";
    var col = writeAsciiStableText(surface, row, rect.col, rect.end_col, status, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, row, col, rect.end_col, " · ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    col = writeText(surface, row, col, rect.end_col, agentChatStatusLabel(chat.status), mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    if (chat.thinking_level.len > 0) {
        col = writeText(surface, row, col, rect.end_col, " · thinking ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, row, col, rect.end_col, chat.thinking_level, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
    return row + 1;
}

fn agentChatMessageLabel(kind: u8) []const u8 {
    return switch (kind) {
        0x01 => "user",
        0x02 => "assistant",
        0x03 => "thinking",
        0x04, 0x08 => "tool",
        0x05 => "system",
        0x06 => "usage",
        0x09 => "approval",
        else => "msg",
    };
}

fn agentChatMessageStyle(message: AgentChatMessage, maybe_theme: ?Theme) RenderStyle {
    return switch (message.kind) {
        0x01 => .{ .fg = accentFg(maybe_theme), .bg = popupBg(maybe_theme), .attrs = 0 },
        0x03, 0x05, 0x06 => .{ .fg = mutedFg(maybe_theme), .bg = popupBg(maybe_theme), .attrs = 0 },
        0x04, 0x08 => .{ .fg = if (message.is_error) diagnosticColor(maybe_theme, 0) else if (message.status == 1) accentFg(maybe_theme) else mutedFg(maybe_theme), .bg = popupBg(maybe_theme), .attrs = 0 },
        0x09 => .{ .fg = diagnosticColor(maybe_theme, 1), .bg = popupBg(maybe_theme), .attrs = 0 },
        else => .{ .fg = popupFg(maybe_theme), .bg = popupBg(maybe_theme), .attrs = 0 },
    };
}

fn messageText(message: AgentChatMessage) []const u8 {
    if (message.summary.len > 0) return message.summary;
    return message.text;
}

fn renderChangeSummary(surface: anytype, summary: ChangeSummary, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!summary.visible or summary.entries.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;
    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const available_height: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (available_height == 0) return;

    const overlay_width: u16 = @min(width, 44);
    const overlay_height: u16 = @min(@min(available_height, 12), @as(u16, @intCast(@min(summary.entries.len + 2, std.math.maxInt(u16)))));
    if (overlay_height == 0) return;
    const rect = OverlayRect{
        .row = 0,
        .col = width - overlay_width,
        .end_row = overlay_height,
        .end_col = width,
    };
    fillOverlay(surface, rect, popupBg(maybe_theme));

    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col) return;

    var row = rect.row;
    _ = writeText(surface, row, content_col, content_end_col, "Changes", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    var index: usize = 0;
    while (row < rect.end_row and index < summary.entries.len) : ({
        row += 1;
        index += 1;
    }) {
        const entry = summary.entries[index];
        const selected = index == summary.selected_index;
        const fg = if (selected) popupSelectionFg(maybe_theme) else popupFg(maybe_theme);
        const bg = if (selected) popupSelectionBg(maybe_theme) else popupBg(maybe_theme);
        fillRowRangeWith(surface, row, content_col, content_end_col, bg);
        var col = content_col;
        col = writeText(surface, row, col, content_end_col, entry.path, fg, bg, if (selected) protocol.ATTR_BOLD else 0);
        col = writeText(surface, row, col, content_end_col, " ", mutedFg(maybe_theme), bg, 0);
        var buf: [32]u8 = undefined;
        const stats = std.fmt.bufPrint(&buf, "+{d} -{d}", .{ entry.lines_added, entry.lines_removed }) catch "";
        _ = writeAsciiStableText(surface, row, col, content_end_col, stats, mutedFg(maybe_theme), bg, 0);
    }
}

fn renderNotifications(surface: anytype, notifications: Notifications, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!notifications.visible or notifications.items.len == 0) return;

    const row_count: u16 = @as(u16, @intCast(@min(notifications.items.len * 2, 9))) + 1;
    const rect = centeredOverlayRect(surface, 60, @max(@as(u16, 3), row_count), has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    _ = writeText(surface, row, content.col, content.end_col, "Notifications", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    var index: usize = 0;
    while (row < content.end_row and index < notifications.items.len) : (index += 1) {
        const item = notifications.items[index];
        var desc_buf: [160]u8 = undefined;
        var description: []const u8 = item.body;
        if (item.source.len > 0) {
            description = std.fmt.bufPrint(&desc_buf, "{s} {s}", .{ item.source, item.body }) catch item.body;
        }
        row = renderPopupListItem(surface, row, content.end_row, content.col, content.end_col, item.title, std.mem.trim(u8, description, " "), index == 0, maybe_theme);
    }
}

fn renderEditTimeline(surface: anytype, timeline: EditTimeline, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!timeline.visible or timeline.entries.len == 0) return;

    const row_count: u16 = @as(u16, @intCast(@min(timeline.entries.len, 9))) + 2;
    const rect = centeredOverlayRect(surface, 50, @max(@as(u16, 3), row_count), has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    const index_width: u16 = @min(content.end_col - content.col, 4);
    const age_width: u16 = @min(@as(u16, 8), content.end_col - content.col);
    const tool_col: u16 = @min(content.end_col, content.col + index_width);
    const age_col: u16 = if (content.end_col > age_width) content.end_col - age_width else content.end_col;
    _ = writeText(surface, row, content.col, tool_col, "#", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    _ = writeText(surface, row, tool_col, age_col, "Tool", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    _ = writeText(surface, row, age_col, content.end_col, "Age", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    var index: usize = 0;
    while (row < content.end_row and index < timeline.entries.len) : ({
        row += 1;
        index += 1;
    }) {
        const entry = timeline.entries[index];
        const selected = @as(u16, entry.index) == timeline.viewing_index;
        const fg = if (selected) popupSelectionFg(maybe_theme) else popupFg(maybe_theme);
        const bg = if (selected) popupSelectionBg(maybe_theme) else popupBg(maybe_theme);
        if (selected) fillRowRangeWith(surface, row, content.col, content.end_col, bg);
        const col = content.col;
        var index_buf: [12]u8 = undefined;
        const index_text = std.fmt.bufPrint(&index_buf, "{d}", .{entry.index}) catch "";
        _ = writeAsciiStableText(surface, row, col, tool_col, index_text, fg, bg, if (selected) protocol.ATTR_BOLD else 0);
        _ = writeText(surface, row, tool_col, age_col, entry.tool_name, fg, bg, if (selected) protocol.ATTR_BOLD else 0);
        var delta_buf: [16]u8 = undefined;
        const delta = std.fmt.bufPrint(&delta_buf, "{d}", .{entry.timestamp_delta}) catch "";
        _ = writeAsciiStableText(surface, row, age_col, content.end_col, delta, mutedFg(maybe_theme), bg, 0);
    }
}

fn renderExtensionOverlay(surface: anytype, overlay: ExtensionOverlay, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (overlay.entries.len == 0) return;

    const row_count: u16 = @as(u16, @intCast(@min(overlay.entries.len, 9))) + 2;
    const rect = centeredOverlayRect(surface, 70, @max(@as(u16, 3), row_count), has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    _ = writeText(surface, row, content.col, content.end_col, "Extension overlays", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    var index: usize = 0;
    while (row < content.end_row and index < overlay.entries.len) : ({
        row += 1;
        index += 1;
    }) {
        const entry = overlay.entries[index];
        var coord_buf: [32]u8 = undefined;
        const coords = std.fmt.bufPrint(&coord_buf, " {d}:{d} ", .{ entry.row + 1, entry.col + 1 }) catch " ";
        var col = content.col;
        col = writeText(surface, row, col, content.end_col, entry.extension, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        col = writeAsciiStableText(surface, row, col, content.end_col, coords, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        _ = writeText(surface, row, col, content.end_col, entry.content, if (entry.fg != 0) entry.fg else popupFg(maybe_theme), popupBg(maybe_theme), 0);
    }
}

fn renderExtensionPanel(surface: anytype, panel: ExtensionPanel, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (panel.panels.len == 0) return;

    const rect = centeredOverlayRect(surface, 70, 10, has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    _ = writeText(surface, row, content.col, content.end_col, "Extensions", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    for (panel.panels) |entry| {
        if (row >= content.end_row) break;
        if (!entry.visible) continue;
        _ = writeText(surface, row, content.col, content.end_col, entry.title, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        row += 1;

        var block_index: usize = 0;
        while (row < content.end_row and block_index < @min(entry.blocks.len, 2)) : ({
            row += 1;
            block_index += 1;
        }) {
            _ = writeText(surface, row, content.col, content.end_col, entry.blocks[block_index], mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        }
    }
}

fn renderObservatory(surface: anytype, observatory: Observatory, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!observatory.visible or observatory.nodes.len == 0) return;

    const row_count: u16 = @as(u16, @intCast(@min(observatory.nodes.len, 9))) + 2;
    const rect = centeredOverlayRect(surface, 70, @max(@as(u16, 3), row_count), has_minibuffer, has_status_bar) orelse return;
    const content = preparePopup(surface, rect, maybe_theme) orelse return;
    var row = content.row;
    const content_width: u16 = content.end_col - content.col;
    const pid_width: u16 = @min(content_width, 12);
    const queue_width: u16 = @min(@as(u16, 6), content_width);
    const process_col: u16 = @min(content.end_col, content.col + pid_width);
    const queue_col: u16 = if (content.end_col > queue_width) content.end_col - queue_width else content.end_col;
    var col = content.col;
    col = writeText(surface, row, col, process_col, "Observatory ", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    var count_buf: [16]u8 = undefined;
    const title_count = std.fmt.bufPrint(&count_buf, "{d}", .{@max(observatory.count, @as(u16, @intCast(@min(observatory.nodes.len, std.math.maxInt(u16)))))}) catch "";
    _ = writeAsciiStableText(surface, row, col, process_col, title_count, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    _ = writeText(surface, row, process_col, queue_col, "Process", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    _ = writeText(surface, row, queue_col, content.end_col, "Q", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    row += 1;

    var index: usize = 0;
    while (row < content.end_row and index < observatory.nodes.len) : ({
        row += 1;
        index += 1;
    }) {
        const node = observatory.nodes[index];
        col = content.col;
        _ = writeText(surface, row, col, process_col, node.pid, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        col = process_col;
        var depth: u8 = 0;
        while (depth < node.depth and col < queue_col) : (depth += 1) {
            col = writeText(surface, row, col, queue_col, "  ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        }
        _ = writeText(surface, row, col, queue_col, node.name, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        var queue_buf: [24]u8 = undefined;
        const queue = std.fmt.bufPrint(&queue_buf, "{d}", .{node.message_queue_len}) catch "";
        _ = writeAsciiStableText(surface, row, queue_col, content.end_col, queue, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }
}

const OverlayRect = struct {
    row: u16,
    col: u16,
    end_row: u16,
    end_col: u16,
};

fn centeredOverlayRect(surface: anytype, preferred_width: u16, preferred_height: u16, has_minibuffer: bool, has_status_bar: bool) ?OverlayRect {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return null;
    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const available_height: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (available_height == 0) return null;
    const overlay_width: u16 = @min(width, preferred_width);
    const overlay_height: u16 = @min(available_height, preferred_height);
    const col: u16 = if (width > overlay_width) (width - overlay_width) / 2 else 0;
    const row: u16 = if (available_height > overlay_height) (available_height - overlay_height) / 2 else 0;
    return .{
        .row = row,
        .col = col,
        .end_row = row + overlay_height,
        .end_col = col + overlay_width,
    };
}

fn anchoredOverlayRect(area_width: u16, area_height: u16, col: u16, row: u16, preferred_width: u16, preferred_height: u16) ?OverlayRect {
    if (area_width == 0 or area_height == 0) return null;
    const overlay_width: u16 = @min(area_width, preferred_width);
    const overlay_height: u16 = @min(area_height, preferred_height);
    if (overlay_width == 0 or overlay_height == 0) return null;
    const start_col: u16 = @min(col, area_width - overlay_width);
    const start_row: u16 = @min(row, area_height - overlay_height);
    return .{
        .row = start_row,
        .col = start_col,
        .end_row = start_row + overlay_height,
        .end_col = start_col + overlay_width,
    };
}

fn preparePopup(surface: anytype, rect: OverlayRect, maybe_theme: ?Theme) ?OverlayRect {
    fillOverlay(surface, rect, popupBg(maybe_theme));
    const content_col: u16 = @min(rect.col + 1, rect.end_col);
    const content_end_col: u16 = if (rect.end_col > content_col) rect.end_col - 1 else rect.end_col;
    if (content_col >= content_end_col or rect.row >= rect.end_row) return null;
    return .{
        .row = rect.row,
        .col = content_col,
        .end_row = rect.end_row,
        .end_col = content_end_col,
    };
}

fn clearOverlay(surface: anytype, rect: OverlayRect) void {
    var row = rect.row;
    while (row < rect.end_row) : (row += 1) {
        clearRowRange(surface, row, rect.col, rect.end_col);
    }
}

fn fillOverlay(surface: anytype, rect: OverlayRect, bg: u24) void {
    var row = rect.row;
    while (row < rect.end_row) : (row += 1) {
        var col = rect.col;
        while (col < rect.end_col) : (col += 1) {
            surface.writeCell(col, row, .{ .grapheme = " ", .width = 1, .fg = 0, .bg = bg, .attrs = 0 });
        }
    }
}

fn agentContextStatusLabel(status: u8) []const u8 {
    return switch (status) {
        1 => "working",
        2 => "iterating",
        3 => "needs you",
        4 => "done",
        5 => "error",
        else => if (status == 0) "idle" else "unknown",
    };
}

fn toolStatusLabel(status: u8) []const u8 {
    return switch (status) {
        1 => "installed",
        2 => "installing",
        3 => "update available",
        4 => "failed",
        else => "not installed",
    };
}

fn boardStatusLabel(status: u8) []const u8 {
    return switch (status) {
        1 => "working",
        2 => "iterating",
        3 => "needs you",
        4 => "done",
        5 => "error",
        else => if (status == 0) "idle" else "unknown",
    };
}

fn boundedDimension(preferred: u16, minimum: u16, maximum: u16) u16 {
    if (maximum == 0) return 0;
    return @min(maximum, @max(minimum, preferred));
}

fn renderGitStatus(surface: anytype, git: GitStatus, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const footer_rows: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const row: u16 = if (height > footer_rows) height - footer_rows - 1 else height - 1;
    clearRow(surface, row, width);
    fillRowRemainder(surface, row, 0, width, editorBg(maybe_theme));

    var col: u16 = 0;
    col = writeText(surface, row, col, width, "git", accentFg(maybe_theme), editorBg(maybe_theme), protocol.ATTR_BOLD);
    if (git.branch.len > 0) {
        col = writeText(surface, row, col, width, " ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        col = writeText(surface, row, col, width, git.branch, popupFg(maybe_theme), editorBg(maybe_theme), 0);
    }
    if (git.syncing) col = writeText(surface, row, col, width, "  syncing", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    if (git.ahead > 0) {
        var ahead_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&ahead_buf, "  ahead {d}", .{git.ahead}) catch "";
        col = writeAsciiStableText(surface, row, col, width, text, mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    }
    if (git.behind > 0) {
        var behind_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&behind_buf, "  behind {d}", .{git.behind}) catch "";
        col = writeAsciiStableText(surface, row, col, width, text, mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    }
    if (git.entries.len > 0) {
        var files_buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&files_buf, "  {d} files", .{git.entries.len}) catch "";
        col = writeAsciiStableText(surface, row, col, width, text, mutedFg(maybe_theme), editorBg(maybe_theme), 0);
    }
    if (git.toast.visible and git.toast.message.len > 0) {
        col = writeText(surface, row, col, width, "  ", mutedFg(maybe_theme), editorBg(maybe_theme), 0);
        _ = writeText(surface, row, col, width, git.toast.message, accentFg(maybe_theme), editorBg(maybe_theme), protocol.ATTR_BOLD);
    }
}

fn renderSplitSeparators(surface: anytype, separators: SplitSeparators, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const separator_fg = if (separators.color != 0) separators.color else mutedFg(maybe_theme);
    const separator_bg = editorBg(maybe_theme);
    for (separators.verticals) |vertical| {
        if (vertical.col >= width) continue;
        var row = vertical.start_row;
        const end_row = @min(vertical.end_row, height - 1);
        while (row <= end_row) : (row += 1) {
            surface.writeCell(vertical.col, row, .{
                .grapheme = "│",
                .width = 1,
                .fg = separator_fg,
                .bg = separator_bg,
                .attrs = 0,
            });
        }
    }

    for (separators.horizontals) |horizontal| {
        if (horizontal.row >= height or horizontal.col >= width or horizontal.width == 0) continue;
        const end_col = @min(width, horizontal.col + horizontal.width);
        var col = horizontal.col;
        const label = std.mem.trim(u8, horizontal.filename, " \t\r\n");
        if (label.len > 0 and horizontal.width >= 4 and textWidth(label) + 2 < horizontal.width) {
            col = writeText(surface, horizontal.row, col, end_col, " ", separator_fg, separator_bg, 0);
            col = writeText(surface, horizontal.row, col, end_col, label, separator_fg, separator_bg, 0);
            if (col < end_col) col = writeText(surface, horizontal.row, col, end_col, " ", separator_fg, separator_bg, 0);
        }
        while (col < end_col) : (col += 1) {
            surface.writeCell(col, horizontal.row, .{
                .grapheme = "─",
                .width = 1,
                .fg = separator_fg,
                .bg = separator_bg,
                .attrs = 0,
            });
        }
    }
}

fn renderGutterSeparator(surface: anytype, separator: GutterSeparator, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0 or separator.col >= width) return;

    const fg = if (separator.color != 0) separator.color else gutterFg(maybe_theme);
    const bg = editorBg(maybe_theme);
    var row: u16 = 0;
    while (row < height) : (row += 1) {
        surface.writeCell(separator.col, row, .{
            .grapheme = "│",
            .width = 1,
            .fg = fg,
            .bg = bg,
            .attrs = 0,
        });
    }
}

fn renderBottomPanel(surface: anytype, panel: BottomPanel, has_minibuffer: bool, has_status_bar: bool, maybe_theme: ?Theme) void {
    if (!panel.visible or panel.entries.len == 0) return;

    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    const reserved_footer: u16 = @as(u16, if (has_status_bar) 1 else 0) + @as(u16, if (has_minibuffer) 1 else 0);
    const available_rows: u16 = if (height > reserved_footer) height - reserved_footer else height;
    if (available_rows == 0) return;

    const percent: u8 = @min(@max(panel.height_percent, 10), 60);
    const requested_rows: u16 = @as(u16, @intCast((@as(u32, available_rows) * @as(u32, percent)) / 100));
    const panel_rows: u16 = boundedDimension(requested_rows, 3, available_rows);
    const start_row: u16 = available_rows - panel_rows;
    fillOverlay(surface, .{ .row = start_row, .col = 0, .end_row = start_row + panel_rows, .end_col = width }, popupBg(maybe_theme));
    var row = start_row;

    const title = bottomPanelTitle(panel);
    const level_width: u16 = @min(width, 10);
    const path_width: u16 = @min(if (width / 4 > 12) width / 4 else 12, width -| level_width);
    const message_col: u16 = @min(width, level_width + path_width);
    var col: u16 = 0;
    col = writeText(surface, row, col, level_width, title, accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, level_width, message_col, "Path", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    col = writeText(surface, row, message_col, width, "Message", accentFg(maybe_theme), popupBg(maybe_theme), protocol.ATTR_BOLD);
    if (panel.filter != 0) {
        col = writeText(surface, row, col, width, "  filter ", mutedFg(maybe_theme), popupBg(maybe_theme), 0);
        var filter_buf: [32]u8 = undefined;
        const filter_text = std.fmt.bufPrint(&filter_buf, "{d}", .{panel.filter}) catch "";
        _ = writeAsciiStableText(surface, row, col, width, filter_text, mutedFg(maybe_theme), popupBg(maybe_theme), 0);
    }

    row += 1;
    var index: usize = 0;
    while (row < start_row + panel_rows and index < panel.entries.len) : ({
        row += 1;
        index += 1;
    }) {
        const entry = panel.entries[index];
        col = 0;
        _ = writeText(surface, row, col, level_width, bottomPanelLevelName(entry.level), popupFg(maybe_theme), popupBg(maybe_theme), 0);
        if (entry.file_path.len > 0) {
            _ = writeText(surface, row, level_width, message_col, entry.file_path, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        }
        if (entry.text.len > 0) {
            _ = writeText(surface, row, message_col, width, entry.text, popupFg(maybe_theme), popupBg(maybe_theme), 0);
        }
    }
}

fn bottomPanelLevelName(level: u8) []const u8 {
    return switch (level) {
        1 => "warn",
        2 => "error",
        3 => "ok",
        4 => "progress",
        else => "info",
    };
}

fn bottomPanelTitle(panel: BottomPanel) []const u8 {
    if (panel.tabs.len > panel.active_tab_index) {
        const tab = panel.tabs[panel.active_tab_index];
        if (tab.name.len > 0) return tab.name;
    }
    return "Panel";
}

fn renderStatusBar(surface: anytype, status: StatusBar, search: ?SearchState, changes: ?ChangeSummary, notifications: ?Notifications, timeline: ?EditTimeline, extension_overlay: ?ExtensionOverlay, extension_panel: ?ExtensionPanel, observatory: ?Observatory, agent_context: ?AgentContext, tool_manager: ?ToolManager, board: ?Board, agent_chat: ?AgentChat, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;

    // The modeline always sits on the second-from-bottom row; the bottom row is
    // reserved for the message bar / minibuffer (matching the BEAM `Layout.TUI`,
    // which places the status bar at rows-2 and the minibuffer at rows-1).
    const row: u16 = if (height > 1) height - 2 else height - 1;
    clearRow(surface, row, width);
    fillRowRemainder(surface, row, 0, width, modelineBg(maybe_theme));

    if (status.left_segments.len > 0 or status.right_segments.len > 0) {
        renderStatusSegments(surface, row, width, status, search, changes, notifications, timeline, extension_overlay, extension_panel, observatory, agent_context, tool_manager, board, agent_chat, maybe_theme);
    } else {
        renderStatusFallback(surface, row, width, status, search, changes, notifications, timeline, extension_overlay, extension_panel, observatory, agent_context, tool_manager, board, agent_chat, maybe_theme);
    }
}

fn renderStandaloneFooter(surface: anytype, search: ?SearchState, changes: ?ChangeSummary, notifications: ?Notifications, timeline: ?EditTimeline, extension_overlay: ?ExtensionOverlay, extension_panel: ?ExtensionPanel, observatory: ?Observatory, agent_context: ?AgentContext, tool_manager: ?ToolManager, board: ?Board, agent_chat: ?AgentChat, has_minibuffer: bool, maybe_theme: ?Theme) void {
    const width = surface.width();
    const height = surface.height();
    if (width == 0 or height == 0) return;
    if (!hasFooterIndicators(search, changes, notifications, timeline, extension_overlay, extension_panel, observatory, agent_context, tool_manager, board, agent_chat)) return;

    const row = if (has_minibuffer and height > 1) height - 2 else height - 1;
    clearRow(surface, row, width);
    fillRowRemainder(surface, row, 0, width, modelineBg(maybe_theme));
    _ = renderFooterIndicators(surface, row, width, 0, search, changes, notifications, timeline, extension_overlay, extension_panel, observatory, agent_context, tool_manager, board, agent_chat, maybe_theme);
}

fn renderStatusSegments(surface: anytype, row: u16, width: u16, status: StatusBar, search: ?SearchState, changes: ?ChangeSummary, notifications: ?Notifications, timeline: ?EditTimeline, extension_overlay: ?ExtensionOverlay, extension_panel: ?ExtensionPanel, observatory: ?Observatory, agent_context: ?AgentContext, tool_manager: ?ToolManager, board: ?Board, agent_chat: ?AgentChat, maybe_theme: ?Theme) void {
    var col: u16 = 0;
    for (status.left_segments) |segment| {
        col = writeText(surface, row, col, width, segment.text, themedSegmentFg(segment, maybe_theme), themedSegmentBg(segment, maybe_theme), segment.attrs);
    }
    col = renderFooterIndicators(surface, row, width, col, search, changes, notifications, timeline, extension_overlay, extension_panel, observatory, agent_context, tool_manager, board, agent_chat, maybe_theme);

    var right_width: u16 = 0;
    for (status.right_segments) |segment| {
        right_width +|= textWidth(segment.text);
    }

    col = if (right_width >= width) 0 else width - right_width;
    for (status.right_segments) |segment| {
        col = writeText(surface, row, col, width, segment.text, themedSegmentFg(segment, maybe_theme), themedSegmentBg(segment, maybe_theme), segment.attrs);
    }
}

fn renderStatusFallback(surface: anytype, row: u16, width: u16, status: StatusBar, search: ?SearchState, changes: ?ChangeSummary, notifications: ?Notifications, timeline: ?EditTimeline, extension_overlay: ?ExtensionOverlay, extension_panel: ?ExtensionPanel, observatory: ?Observatory, agent_context: ?AgentContext, tool_manager: ?ToolManager, board: ?Board, agent_chat: ?AgentChat, maybe_theme: ?Theme) void {
    var col: u16 = 0;
    if (status.filename.len > 0) {
        col = writeText(surface, row, col, width, status.filename, modelineFg(maybe_theme), modelineBg(maybe_theme), 0);
        col = writeText(surface, row, col, width, "  ", modelineFg(maybe_theme), modelineBg(maybe_theme), 0);
    }

    var cursor_buf: [64]u8 = undefined;
    const cursor_text = std.fmt.bufPrint(&cursor_buf, "{d}:{d}", .{ status.line, status.col }) catch "";
    col = writeText(surface, row, col, width, cursor_text, modelineFg(maybe_theme), modelineBg(maybe_theme), 0);

    if (status.message.len > 0) {
        col = writeText(surface, row, col, width, "  ", modelineFg(maybe_theme), modelineBg(maybe_theme), 0);
        col = writeText(surface, row, col, width, status.message, modelineFg(maybe_theme), modelineBg(maybe_theme), protocol.ATTR_BOLD);
    }

    _ = renderFooterIndicators(surface, row, width, col, search, changes, notifications, timeline, extension_overlay, extension_panel, observatory, agent_context, tool_manager, board, agent_chat, maybe_theme);
}

fn hasFooterIndicators(search: ?SearchState, changes: ?ChangeSummary, notifications: ?Notifications, timeline: ?EditTimeline, extension_overlay: ?ExtensionOverlay, extension_panel: ?ExtensionPanel, observatory: ?Observatory, agent_context: ?AgentContext, tool_manager: ?ToolManager, board: ?Board, agent_chat: ?AgentChat) bool {
    _ = notifications;
    _ = timeline;
    _ = extension_overlay;
    _ = extension_panel;
    _ = observatory;
    _ = agent_context;
    _ = tool_manager;
    _ = board;
    _ = agent_chat;
    if (search) |state| {
        if (state.active) return true;
    }
    if (changes) |summary| {
        if (summary.visible and summary.entries.len > 0) return true;
    }
    return false;
}

fn renderFooterIndicators(surface: anytype, row: u16, width: u16, start_col: u16, search: ?SearchState, changes: ?ChangeSummary, notifications: ?Notifications, timeline: ?EditTimeline, extension_overlay: ?ExtensionOverlay, extension_panel: ?ExtensionPanel, observatory: ?Observatory, agent_context: ?AgentContext, tool_manager: ?ToolManager, board: ?Board, agent_chat: ?AgentChat, maybe_theme: ?Theme) u16 {
    _ = notifications;
    _ = timeline;
    _ = extension_overlay;
    _ = extension_panel;
    _ = observatory;
    _ = agent_context;
    _ = tool_manager;
    _ = board;
    _ = agent_chat;
    var col = start_col;
    const fg = modelineFg(maybe_theme);
    const bg = modelineBg(maybe_theme);
    if (search) |state| {
        if (state.active) {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "  search {d}/{d}", .{ state.current_index, state.match_count }) catch "";
            col = writeText(surface, row, col, width, text, fg, bg, 0);
        }
    }
    if (changes) |summary| {
        if (summary.visible and summary.entries.len > 0) {
            var buf: [32]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "  changes {d}", .{summary.entries.len}) catch "";
            col = writeText(surface, row, col, width, text, fg, bg, 0);
        }
    }
    return col;
}

fn agentChatStatusLabel(status: u8) []const u8 {
    return switch (status) {
        1 => "thinking",
        2 => "tool",
        3 => "error",
        else => "idle",
    };
}

const MockSurface = struct {
    cells: std.ArrayList(MockCell) = .empty,
    mock_width: u16 = 20,
    mock_height: u16 = 4,
    cursor_col: ?u16 = null,
    cursor_row: ?u16 = null,
    cursor_shape: ?surface_mod.CursorShape = null,

    fn deinit(self: *MockSurface, alloc: std.mem.Allocator) void {
        self.cells.deinit(alloc);
    }

    fn clear(_: *MockSurface) void {}
    fn fillBg(_: *MockSurface, _: u24) void {}
    fn showCursor(self: *MockSurface, col: u16, row: u16) void {
        self.cursor_col = col;
        self.cursor_row = row;
    }
    fn setCursorShape(self: *MockSurface, shape: surface_mod.CursorShape) void {
        self.cursor_shape = shape;
    }
    fn scrollRegion(_: *MockSurface, _: u16, _: u16, _: i16) void {}
    fn render(_: *MockSurface) !void {}
    fn width(self: *MockSurface) u16 {
        return self.mock_width;
    }
    fn height(self: *MockSurface) u16 {
        return self.mock_height;
    }
    pub fn writeCell(self: *MockSurface, col: u16, row: u16, cell: surface_mod.Cell) void {
        self.cells.append(std.testing.allocator, .{
            .row = row,
            .col = col,
            .text = cell.grapheme,
            .fg = cell.fg,
            .bg = cell.bg,
            .attrs = cell.attrs,
            .strikethrough = cell.strikethrough,
            .ul_style = cell.ul_style,
        }) catch {};
    }
};

const MockCell = struct {
    row: u16,
    col: u16,
    text: []const u8,
    fg: u24,
    bg: u24,
    attrs: u8,
    strikethrough: bool,
    ul_style: u3,
};

fn expectMockCell(surface: *const MockSurface, row: u16, text: []const u8, attrs: ?u8) !void {
    for (surface.cells.items) |cell| {
        if (cell.row == row and std.mem.eql(u8, cell.text, text)) {
            if (attrs) |expected_attrs| try std.testing.expectEqual(expected_attrs, cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn expectMockCellAfterCol(surface: *const MockSurface, min_col: u16, text: []const u8, attrs: ?u8) !void {
    for (surface.cells.items) |cell| {
        if (cell.col >= min_col and std.mem.eql(u8, cell.text, text)) {
            if (attrs) |expected_attrs| try std.testing.expectEqual(expected_attrs, cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn expectMockCellCountAfterCol(surface: *const MockSurface, min_col: u16, text: []const u8, expected_min: usize) !void {
    var count: usize = 0;
    for (surface.cells.items) |cell| {
        if (cell.col >= min_col and std.mem.eql(u8, cell.text, text)) count += 1;
    }
    try std.testing.expect(count >= expected_min);
}

fn expectMockText(surface: *const MockSurface, row: u16, text: []const u8) !void {
    if (text.len == 0 or text.len > surface.mock_width) return error.TestExpectedEqual;

    var start_col: u16 = 0;
    while (start_col + text.len <= surface.mock_width) : (start_col += 1) {
        var matched = true;
        var index: usize = 0;
        while (index < text.len) : (index += 1) {
            const cell_text = finalMockCellText(surface, row, start_col + @as(u16, @intCast(index)));
            if (cell_text == null or cell_text.?.len != 1 or cell_text.?[0] != text[index]) {
                matched = false;
                break;
            }
        }
        if (matched) return;
    }

    return error.TestExpectedEqual;
}

fn finalMockCellText(surface: *const MockSurface, row: u16, col: u16) ?[]const u8 {
    var index = surface.cells.items.len;
    while (index > 0) {
        index -= 1;
        const cell = surface.cells.items[index];
        if (cell.row == row and cell.col == col) return cell.text;
    }
    return null;
}

fn expectMockCellStyled(surface: *const MockSurface, row: u16, text: []const u8, fg: u24, bg: u24, attrs: u8) !void {
    for (surface.cells.items) |cell| {
        if (cell.row == row and std.mem.eql(u8, cell.text, text)) {
            try std.testing.expectEqual(fg, cell.fg);
            try std.testing.expectEqual(bg, cell.bg);
            try std.testing.expectEqual(attrs, cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn notificationPacketForTest() [63]u8 {
    var packet: [63]u8 = undefined;
    packet[0] = protocol.OP_GUI_NOTIFICATIONS;

    var offset: usize = 3;
    packet[offset] = 1;
    offset += 1;
    std.mem.writeInt(u16, packet[offset..][0..2], 1, .big);
    offset += 2;
    writeNotificationTestString(&packet, &offset, "n1");
    @memset(packet[offset .. offset + 22], 0);
    packet[offset] = 2;
    packet[offset + 1] = 1;
    std.mem.writeInt(u64, packet[offset + 2 ..][0..8], 42, .big);
    std.mem.writeInt(u64, packet[offset + 10 ..][0..8], 99, .big);
    std.mem.writeInt(u32, packet[offset + 18 ..][0..4], 5000, .big);
    offset += 22;
    writeNotificationTestString(&packet, &offset, "Build");
    writeNotificationTestString(&packet, &offset, "Done");
    writeNotificationTestString(&packet, &offset, "mix");
    packet[offset] = 1;
    offset += 1;
    writeNotificationTestString(&packet, &offset, "open");
    writeNotificationTestString(&packet, &offset, "Open");

    std.debug.assert(offset == packet.len);
    std.mem.writeInt(u16, packet[1..3], @intCast(packet.len - 3), .big);
    return packet;
}

fn writeNotificationTestString(packet: anytype, offset: *usize, text: []const u8) void {
    std.mem.writeInt(u16, packet[offset.*..][0..2], @intCast(text.len), .big);
    offset.* += 2;
    @memcpy(packet[offset.* .. offset.* + text.len], text);
    offset.* += text.len;
}

test "decodeTabBar retains tab entries" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_TAB_BAR, 0,    2,
            0xF5,                    0,    0,
            0,                       1,    0,
            7,                       1,    'e',
            0,                       7,    'm',
            'a',                     'i',  'n',
            '.',                     'e',  'x',
            0x11,                    0x22, 0x33,
            0x44,                    0x02, 0,
            0,                       0,    2,
            0,                       0,    1,
            'r',                     0,    9,
            'r',                     'o',  'u',
            't',                     'e',  'r',
            '.',                     'e',  'x',
            0,                       0,    0,
            0,
        };

    var tab_bar = try decodeTabBar(alloc, packet);
    defer tab_bar.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0), tab_bar.active_index);
    try std.testing.expectEqual(@as(usize, 2), tab_bar.tabs.len);
    try std.testing.expect(tab_bar.tabs[0].active());
    try std.testing.expect(tab_bar.tabs[0].agent());
    try std.testing.expect(tab_bar.tabs[0].pinned());
    try std.testing.expectEqual(@as(u8, 7), tab_bar.tabs[0].agentStatus());
    try std.testing.expect(tab_bar.tabs[1].dirty());
    try std.testing.expectEqual(@as(u32, 1), tab_bar.tabs[0].id);
    try std.testing.expectEqual(@as(u16, 7), tab_bar.tabs[0].group_id);
    try std.testing.expectEqualStrings("main.ex", tab_bar.tabs[0].label);
    try std.testing.expectEqualStrings("router.ex", tab_bar.tabs[1].label);
    try std.testing.expectEqual(@as(u32, 0x11223344), tab_bar.tabs[0].tint);
}

test "semantic state renders retained tab bar on top row" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_TAB_BAR, 0,    1,
            0x01,                    0,    0,
            0,                       1,    0,
            0,                       1,    'e',
            0,                       7,    'm',
            'a',                     'i',  'n',
            '.',                     'e',  'x',
            0x11,                    0x22, 0x33,
            0x44,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyTabBarPacket(packet);

    var surface = MockSurface{};
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "▌")) {
            try std.testing.expectEqual(@as(u8, protocol.ATTR_BOLD), cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "semantic state hit-tests retained tab bar to select tab action" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_TAB_BAR, 0,    1,
            0x01,                    0,    0,
            0,                       42,   0,
            0,                       1,    'e',
            0,                       7,    'm',
            'a',                     'i',  'n',
            '.',                     'e',  'x',
            0x11,                    0x22, 0x33,
            0x44,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyTabBarPacket(packet);

    const action = state.hitTest(0, 3, 40, 5) orelse return error.TestExpectedEqual;
    switch (action) {
        .u32_payload => |payload| {
            try std.testing.expectEqual(protocol.GUI_ACTION_SELECT_TAB, payload.action);
            try std.testing.expectEqual(@as(u32, 42), payload.value);
        },
        else => return error.TestExpectedEqual,
    }
}

test "semantic state renders retained tab bar with theme colors" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_tab_bg, .rgb = 0x010203 },
            .{ .id = theme_tab_active_bg, .rgb = 0x111213 },
            .{ .id = theme_tab_active_fg, .rgb = 0x212223 },
            .{ .id = theme_tab_inactive_fg, .rgb = 0x313233 },
            .{ .id = theme_tab_modified_fg, .rgb = 0x414243 },
            .{ .id = theme_tab_attention_fg, .rgb = 0x515253 },
        }),
    };
    state.tab_bar = .{
        .active_index = 0,
        .tabs = try alloc.alloc(Tab, 2),
    };
    state.tab_bar.?.tabs[0] = .{
        .id = 1,
        .flags = 0x01,
        .label = try alloc.dupe(u8, "active"),
    };
    state.tab_bar.?.tabs[1] = .{
        .id = 2,
        .flags = 0x0A,
        .label = try alloc.dupe(u8, "dirty"),
    };

    var surface = MockSurface{ .mock_width = 40, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_active = false;
    var saw_dirty = false;
    var saw_attention = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "a") and cell.fg == 0x212223 and cell.bg == 0x111213) saw_active = true;
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "*") and cell.fg == 0x414243) saw_dirty = true;
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "!") and cell.fg == 0x515253) saw_attention = true;
        if (cell.row == 0 and cell.col == 39 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_active);
    try std.testing.expect(saw_dirty);
    try std.testing.expect(saw_attention);
    try std.testing.expect(saw_background);
}

test "decodeMinibuffer retains prompt input context and candidates" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_MINIBUFFER, 1,
            0,                          0,
            3,                          1,
            ':',                        0,
            5,                          'w',
            'r',                        'i',
            't',                        'e',
            0,                          4,
            'c',                        't',
            'x',                        '!',
            0,                          0,
            0,                          1,
            0,                          4,
            255,                        0,
            5,                          'w',
            'r',                        'i',
            't',                        'e',
            0,                          4,
            's',                        'a',
            'v',                        'e',
            0,                          3,
            'c',                        'm',
            'd',                        1,
            0,                          0,
        };

    var minibuffer = try decodeMinibuffer(alloc, packet);
    defer minibuffer.deinit(alloc);

    try std.testing.expect(minibuffer.visible);
    try std.testing.expectEqual(@as(u8, 0), minibuffer.mode);
    try std.testing.expectEqual(@as(u16, 3), minibuffer.cursor_pos);
    try std.testing.expectEqualStrings(":", minibuffer.prompt);
    try std.testing.expectEqualStrings("write", minibuffer.input);
    try std.testing.expectEqualStrings("ctx!", minibuffer.context);
    try std.testing.expectEqual(@as(u16, 4), minibuffer.total_candidates);
    try std.testing.expectEqual(@as(usize, 1), minibuffer.candidates.len);
    try std.testing.expectEqualStrings("write", minibuffer.candidates[0].label);
    try std.testing.expectEqualStrings("save", minibuffer.candidates[0].description);
    try std.testing.expectEqualStrings("cmd", minibuffer.candidates[0].annotation);
}

test "semantic state renders retained minibuffer on bottom row" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_MINIBUFFER, 1,
            0,                          0,
            3,                          1,
            ':',                        0,
            5,                          'w',
            'r',                        'i',
            't',                        'e',
            0,                          0,
            0,                          0,
            0,                          0,
            0,                          0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyMinibufferPacket(packet);

    var surface = MockSurface{};
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        if (cell.row == 3 and std.mem.eql(u8, cell.text, ":")) {
            try std.testing.expectEqual(@as(u8, protocol.ATTR_BOLD), cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "semantic state renders retained minibuffer with theme colors and candidate count" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_accent, .rgb = 0x212223 },
        }),
    };
    state.minibuffer = .{
        .visible = true,
        .prompt = try alloc.dupe(u8, ":"),
        .input = try alloc.dupe(u8, "write"),
        .context = try alloc.dupe(u8, "ctx"),
        .selected_index = 1,
        .total_candidates = 4,
    };

    var surface = MockSurface{ .mock_width = 30, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_prompt = false;
    var saw_input = false;
    var saw_count = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 3 and std.mem.eql(u8, cell.text, ":") and cell.fg == 0x212223 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_prompt = true;
        if (cell.row == 3 and std.mem.eql(u8, cell.text, "w") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_input = true;
        if (cell.row == 3 and std.mem.eql(u8, cell.text, "2") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_count = true;
        if (cell.row == 3 and cell.col == 29 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_prompt);
    try std.testing.expect(saw_input);
    try std.testing.expect(saw_count);
    try std.testing.expect(saw_background);
}

test "decodeWhichKey retains prefix and bindings" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WHICH_KEY, 1,
            0,                         3,
            'S',                       'P',
            'C',                       0,
            2,                         0,
            1,                         0,
            1,                         'f',
            0,                         4,
            'f',                       'i',
            'l',                       'e',
            0,
        };

    var which_key = try decodeWhichKey(alloc, packet);
    defer which_key.deinit(alloc);

    try std.testing.expect(which_key.visible);
    try std.testing.expectEqualStrings("SPC", which_key.prefix);
    try std.testing.expectEqual(@as(u8, 0), which_key.page);
    try std.testing.expectEqual(@as(u8, 2), which_key.page_count);
    try std.testing.expectEqual(@as(usize, 1), which_key.bindings.len);
    try std.testing.expectEqualStrings("f", which_key.bindings[0].key);
    try std.testing.expectEqualStrings("file", which_key.bindings[0].description);
}

test "semantic state renders retained which-key overlay with popup theme" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WHICH_KEY, 1,
            0,                         3,
            'S',                       'P',
            'C',                       0,
            2,                         0,
            1,                         0,
            1,                         'f',
            0,                         4,
            'f',                       'i',
            'l',                       'e',
            0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_popup_selection_fg, .rgb = 0x313233 },
            .{ .id = theme_accent, .rgb = 0x414243 },
        }),
    };
    try state.applyWhichKeyPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_page_count = false;
    var saw_key = false;
    var saw_description = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 10 and std.mem.eql(u8, cell.text, "K") and cell.fg == 0x414243 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 10 and std.mem.eql(u8, cell.text, "/") and cell.fg == 0x414243 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_page_count = true;
        if (cell.row == 11 and std.mem.eql(u8, cell.text, "f") and cell.fg == 0x313233 and cell.bg == 0x212223 and cell.attrs == protocol.ATTR_BOLD) saw_key = true;
        if (cell.row == 11 and std.mem.eql(u8, cell.text, "i") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_description = true;
        if (cell.row == 10 and cell.col == 79 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_page_count);
    try std.testing.expect(saw_key);
    try std.testing.expect(saw_description);
    try std.testing.expect(saw_background);
}

test "decodeCompletion retains selected items" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_COMPLETION, 1,
            0,                          4,
            0,                          12,
            0,                          1,
            0,                          2,
            1,                          0,
            5,                          'w',
            'r',                        'i',
            't',                        'e',
            0,                          9,
            'S',                        'a',
            'v',                        'e',
            ' ',                        'f',
            'i',                        'l',
            'e',                        5,
            0,                          5,
            'M',                        'i',
            'n',                        'g',
            'a',                        0,
            6,                          'm',
            'o',                        'd',
            'u',                        'l',
            'e',
        };

    var completion = try decodeCompletion(alloc, packet);
    defer completion.deinit(alloc);

    try std.testing.expect(completion.visible);
    try std.testing.expectEqual(@as(u16, 4), completion.cursor_row);
    try std.testing.expectEqual(@as(u16, 12), completion.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), completion.selected_index);
    try std.testing.expectEqual(@as(usize, 2), completion.items.len);
    try std.testing.expectEqual(@as(u8, 1), completion.items[0].kind);
    try std.testing.expectEqualStrings("write", completion.items[0].label);
    try std.testing.expectEqualStrings("Save file", completion.items[0].detail);
    try std.testing.expectEqual(@as(u8, 5), completion.items[1].kind);
    try std.testing.expectEqualStrings("Minga", completion.items[1].label);
    try std.testing.expectEqualStrings("module", completion.items[1].detail);
}

test "semantic state renders retained completion overlay anchored to cursor" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_COMPLETION, 1,
            0,                          4,
            0,                          12,
            0,                          0,
            0,                          1,
            1,                          0,
            5,                          'w',
            'r',                        'i',
            't',                        'e',
            0,                          9,
            'S',                        'a',
            'v',                        'e',
            ' ',                        'f',
            'i',                        'l',
            'e',
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_popup_selection_fg, .rgb = 0x313233 },
            .{ .id = theme_accent, .rgb = 0x414243 },
        }),
    };
    try state.applyCompletionPacket(packet);

    var surface = MockSurface{ .mock_width = 40, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_selected_label = false;
    var saw_selected_detail = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 5 and std.mem.eql(u8, cell.text, "C") and cell.fg == 0x414243 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 6 and std.mem.eql(u8, cell.text, "w") and cell.fg == 0x313233 and cell.bg == 0x212223) saw_selected_label = true;
        if (cell.row == 6 and std.mem.eql(u8, cell.text, "S") and cell.fg == 0x313233 and cell.bg == 0x212223) saw_selected_detail = true;
        if (cell.row == 5 and cell.col == 31 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_selected_label);
    try std.testing.expect(saw_selected_detail);
    try std.testing.expect(saw_background);
}

test "decodeBreadcrumb retains path segments" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_BREADCRUMB, 3,
            0,                          3,
            'l',                        'i',
            'b',                        0,
            5,                          'm',
            'i',                        'n',
            'g',                        'a',
            0,                          9,
            'e',                        'd',
            'i',                        't',
            'o',                        'r',
            '.',                        'e',
            'x',
        };

    var breadcrumb = try decodeBreadcrumb(alloc, packet);
    defer breadcrumb.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), breadcrumb.segments.len);
    try std.testing.expectEqualStrings("lib", breadcrumb.segments[0]);
    try std.testing.expectEqualStrings("minga", breadcrumb.segments[1]);
    try std.testing.expectEqualStrings("editor.ex", breadcrumb.segments[2]);
}

test "semantic state renders retained breadcrumb below tabs" {
    const alloc = std.testing.allocator;
    const tabs_packet =
        &[_]u8{
            protocol.OP_GUI_TAB_BAR, 0,   1,
            0x01,                    0,   0,
            0,                       1,   0,
            0,                       0,   0,
            4,                       'm', 'a',
            'i',                     'n', 0,
            0,                       0,   0,
        };
    const breadcrumb_packet =
        &[_]u8{
            protocol.OP_GUI_BREADCRUMB, 2,
            0,                          3,
            'l',                        'i',
            'b',                        0,
            7,                          'm',
            'a',                        'i',
            'n',                        '.',
            'e',                        'x',
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyTabBarPacket(tabs_packet);
    try state.applyBreadcrumbPacket(breadcrumb_packet);

    var surface = MockSurface{};
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expect(surface.cells.items.len > 47);
    try expectMockCell(&surface, 1, "l", null);
    try expectMockCell(&surface, 1, "m", protocol.ATTR_BOLD);
}

test "semantic state renders retained breadcrumb with theme colors and git summary" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
            .{ .id = theme_editor_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_gutter_fg, .rgb = 0x313233 },
        }),
    };
    state.breadcrumb = .{
        .segments = try alloc.alloc([]u8, 2),
    };
    state.breadcrumb.?.segments[0] = try alloc.dupe(u8, "lib");
    state.breadcrumb.?.segments[1] = try alloc.dupe(u8, "main.ex");
    state.git_status = .{
        .branch = try alloc.dupe(u8, "main"),
        .ahead = 2,
        .entries = try alloc.dupe(GitStatusEntry, &[_]GitStatusEntry{
            .{ .path = try alloc.dupe(u8, "lib/main.ex") },
        }),
        .toast = .{
            .visible = true,
            .message = try alloc.dupe(u8, "synced"),
        },
    };
    var summary_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("git main  ahead 2  1 files  synced", gitSummary(&summary_buf, state.git_status.?));

    var surface = MockSurface{ .mock_width = 120, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_muted_segment = false;
    var saw_current_segment = false;
    var saw_separator = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "l") and cell.fg == 0x212223 and cell.bg == 0x010203) saw_muted_segment = true;
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "m") and cell.fg == 0x111213 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_current_segment = true;
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "›") and cell.fg == 0x313233 and cell.bg == 0x010203) saw_separator = true;
        if (cell.row == 0 and cell.col == 119 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_muted_segment);
    try std.testing.expect(saw_current_segment);
    try std.testing.expect(saw_separator);
    try std.testing.expect(saw_background);
    try expectMockText(&surface, 0, "git main");
    try expectMockText(&surface, 0, "1 files");
    try expectMockText(&surface, 0, "synced");
}

test "decodePicker retains visible list state" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_PICKER, 6,
            0x01,                   0,
            17,                     1,
            0,                      1,
            0,                      1,
            0,                      2,
            0,                      0,
            5,                      'F',
            'i',                    'l',
            'e',                    's',
            0,                      1,
            0x02,                   0,
            5,                      0,
            3,                      's',
            'r',                    'c',
            0x03,                   0,
            31,                     0,
            1,                      0x11,
            0x22,                   0x33,
            0x03,                   0,
            7,                      'm',
            'a',                    'i',
            'n',                    '.',
            'e',                    'x',
            0,                      3,
            'l',                    'i',
            'b',                    0,
            8,                      'm',
            'o',                    'd',
            'i',                    'f',
            'i',                    'e',
            'd',                    0,
            0x04,                   0,
            9,                      1,
            0,                      1,
            0,                      4,
            'o',                    'p',
            'e',                    'n',
            0x05,                   0,
            3,                      0,
            1,                      '>',
            0x06,                   0,
            1,                      0,
        };

    var picker = try decodePicker(alloc, packet);
    defer picker.deinit(alloc);

    try std.testing.expect(picker.visible);
    try std.testing.expectEqual(@as(u16, 1), picker.selected_index);
    try std.testing.expectEqual(@as(u16, 1), picker.filtered_count);
    try std.testing.expectEqual(@as(u16, 2), picker.total_count);
    try std.testing.expectEqual(@as(u16, 1), picker.marked_count);
    try std.testing.expectEqualStrings("Files", picker.title);
    try std.testing.expectEqualStrings("src", picker.query);
    try std.testing.expectEqualStrings(">", picker.mode_prefix);
    try std.testing.expect(picker.action_visible);
    try std.testing.expectEqual(@as(u8, 0), picker.action_index);
    try std.testing.expectEqual(@as(usize, 1), picker.actions.len);
    try std.testing.expectEqualStrings("open", picker.actions[0]);
    try std.testing.expectEqual(@as(usize, 1), picker.items.len);
    try std.testing.expect(picker.items[0].twoLine());
    try std.testing.expect(picker.items[0].marked());
    try std.testing.expectEqual(@as(u8, 0x03), picker.items[0].flags);
    try std.testing.expectEqual(@as(u24, 0x112233), picker.items[0].icon_color);
    try std.testing.expectEqualStrings("main.ex", picker.items[0].label);
    try std.testing.expectEqualStrings("lib", picker.items[0].description);
    try std.testing.expectEqualStrings("modified", picker.items[0].annotation);
}

test "semantic state renders retained picker overlay" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_PICKER, 5,
            0x01,                   0,
            17,                     1,
            0,                      0,
            0,                      1,
            0,                      2,
            0,                      0,
            5,                      'F',
            'i',                    'l',
            'e',                    's',
            0,                      1,
            0x02,                   0,
            5,                      0,
            3,                      's',
            'r',                    'c',
            0x03,                   0,
            31,                     0,
            1,                      0x11,
            0x22,                   0x33,
            0x02,                   0,
            7,                      'm',
            'a',                    'i',
            'n',                    '.',
            'e',                    'x',
            0,                      3,
            'l',                    'i',
            'b',                    0,
            8,                      'm',
            'o',                    'd',
            'i',                    'f',
            'i',                    'e',
            'd',                    0,
            0x05,                   0,
            3,                      0,
            1,                      '>',
            0x06,                   0,
            1,                      0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyPickerPacket(packet);

    var surface = MockSurface{};
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 0, "F", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 1, "▌", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 1, "m", protocol.ATTR_BOLD);
}

test "semantic state suppresses generic overlays while picker is visible" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.picker = .{
        .visible = true,
        .title = try alloc.dupe(u8, "Files"),
    };
    state.tool_manager = .{ .visible = true };

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_picker = false;
    var saw_tool_manager = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "F")) saw_picker = true;
        if (std.mem.eql(u8, cell.text, "T")) saw_tool_manager = true;
    }

    try std.testing.expect(saw_picker);
    try std.testing.expect(!saw_tool_manager);
}

test "decodePickerPreview retains styled preview lines" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_PICKER_PREVIEW, 1,
            0,                              1,
            1,                              0x11,
            0x22,                           0x33,
            1,                              0,
            7,                              'p',
            'r',                            'e',
            'v',                            'i',
            'e',                            'w',
        };

    var preview = try decodePickerPreview(alloc, packet);
    defer preview.deinit(alloc);

    try std.testing.expect(preview.visible);
    try std.testing.expectEqual(@as(usize, 1), preview.lines.len);
    try std.testing.expectEqual(@as(usize, 1), preview.lines[0].segments.len);
    try std.testing.expectEqualStrings("preview", preview.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(u24, 0x112233), preview.lines[0].segments[0].fg);
    try std.testing.expect(preview.lines[0].segments[0].bold);
}

test "semantic state renders retained picker preview beside picker on wide surface" {
    const alloc = std.testing.allocator;
    const picker_packet =
        &[_]u8{
            protocol.OP_GUI_PICKER, 1,
            0x01,                   0,
            17,                     1,
            0,                      0,
            0,                      0,
            0,                      0,
            1,                      0,
            5,                      'F',
            'i',                    'l',
            'e',                    's',
            0,                      0,
        };
    const preview_packet =
        &[_]u8{
            protocol.OP_GUI_PICKER_PREVIEW, 1,
            0,                              1,
            1,                              0x11,
            0x22,                           0x33,
            1,                              0,
            7,                              'p',
            'r',                            'e',
            'v',                            'i',
            'e',                            'w',
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyPickerPacket(picker_packet);
    try state.applyPickerPreviewPacket(preview_packet);

    var surface = MockSurface{ .mock_width = 120, .mock_height = 6 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 0, "P", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 1, "p", protocol.ATTR_BOLD);
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "p")) {
            try std.testing.expectEqual(@as(u16, 54), cell.col);
            try std.testing.expectEqual(@as(u24, 0x112233), cell.fg);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "decodeHoverPopup retains rich hover lines" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_HOVER_POPUP, 1,
            0,                           3,
            0,                           9,
            1,                           0,
            2,                           0,
            1,                           0,
            0,                           2,
            1,                           0,
            4,                           'B',
            'o',                         'l',
            'd',                         13,
            0x11,                        0x22,
            0x33,                        1,
            0,                           4,
            'C',                         'o',
            'd',                         'e',
        };

    var hover = try decodeHoverPopup(alloc, packet);
    defer hover.deinit(alloc);

    try std.testing.expect(hover.visible);
    try std.testing.expect(hover.focused);
    try std.testing.expectEqual(@as(u16, 3), hover.anchor_row);
    try std.testing.expectEqual(@as(u16, 9), hover.anchor_col);
    try std.testing.expectEqual(@as(u16, 2), hover.scroll_offset);
    try std.testing.expectEqual(@as(usize, 1), hover.lines.len);
    try std.testing.expectEqual(@as(usize, 2), hover.lines[0].segments.len);
    try std.testing.expectEqualStrings("Bold", hover.lines[0].segments[0].text);
    try std.testing.expectEqual(@as(u8, 1), hover.lines[0].segments[0].style);
    try std.testing.expectEqualStrings("Code", hover.lines[0].segments[1].text);
    try std.testing.expectEqual(@as(u8, 13), hover.lines[0].segments[1].style);
    try std.testing.expectEqual(@as(u24, 0x112233), hover.lines[0].segments[1].fg);
    try std.testing.expectEqual(@as(u8, 1), hover.lines[0].segments[1].flags);
}

test "semantic state renders retained hover popup near anchor" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_HOVER_POPUP, 1,
            0,                           2,
            0,                           9,
            1,                           0,
            0,                           0,
            1,                           0,
            0,                           2,
            1,                           0,
            4,                           'B',
            'o',                         'l',
            'd',                         13,
            0x11,                        0x22,
            0x33,                        1,
            0,                           4,
            'C',                         'o',
            'd',                         'e',
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyHoverPopupPacket(packet);

    var surface = MockSurface{ .mock_width = 60, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 3, "H", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "B", protocol.ATTR_BOLD);
    for (surface.cells.items) |cell| {
        if (cell.row == 4 and std.mem.eql(u8, cell.text, "C")) {
            try std.testing.expectEqual(@as(u24, 0x112233), cell.fg);
            try std.testing.expectEqual(@as(u8, protocol.ATTR_BOLD), cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "semantic state hit-tests retained hover open action" {
    const alloc = std.testing.allocator;
    const hover_packet =
        &[_]u8{
            protocol.OP_GUI_HOVER_POPUP, 1,
            0,                           2,
            0,                           9,
            1,                           0,
            0,                           0,
            1,                           0,
            0,                           1,
            1,                           0,
            4,                           'O',
            'p',                         'e',
            'n',
        };
    const action_packet = &[_]u8{ protocol.OP_GUI_HOVER_ACTION, 0, 7, 1, 0, 4, 'O', 'p', 'e', 'n' };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyHoverPopupPacket(hover_packet);
    try state.applyHoverActionPacket(action_packet);

    const action = state.hitTest(5, 11, 60, 8) orelse return error.TestExpectedEqual;
    switch (action) {
        .no_payload => |action_id| try std.testing.expectEqual(protocol.GUI_ACTION_HOVER_OPEN_ACTION, action_id),
        else => return error.TestExpectedEqual,
    }
}

test "decodeSignatureHelp retains signatures and parameters" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SIGNATURE_HELP, 1,
            0,                              2,
            0,                              3,
            0,                              1,
            1,                              0,
            8,                              'f',
            'o',                            'o',
            '(',                            'a',
            ',',                            'b',
            ')',                            0,
            4,                              'd',
            'o',                            'c',
            's',                            2,
            0,                              1,
            'a',                            0,
            5,                              'f',
            'i',                            'r',
            's',                            't',
            0,                              1,
            'b',                            0,
            6,                              's',
            'e',                            'c',
            'o',                            'n',
            'd',
        };

    var help = try decodeSignatureHelp(alloc, packet);
    defer help.deinit(alloc);

    try std.testing.expect(help.visible);
    try std.testing.expectEqual(@as(u16, 2), help.anchor_row);
    try std.testing.expectEqual(@as(u16, 3), help.anchor_col);
    try std.testing.expectEqual(@as(u8, 1), help.active_parameter);
    try std.testing.expectEqual(@as(usize, 1), help.signatures.len);
    try std.testing.expectEqualStrings("foo(a,b)", help.signatures[0].label);
    try std.testing.expectEqualStrings("docs", help.signatures[0].documentation);
    try std.testing.expectEqual(@as(usize, 2), help.signatures[0].parameters.len);
    try std.testing.expectEqualStrings("b", help.signatures[0].parameters[1].label);
    try std.testing.expectEqualStrings("second", help.signatures[0].parameters[1].documentation);
}

test "semantic state renders retained signature help near anchor" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SIGNATURE_HELP, 1,
            0,                              2,
            0,                              3,
            0,                              1,
            1,                              0,
            8,                              'f',
            'o',                            'o',
            '(',                            'a',
            ',',                            'b',
            ')',                            0,
            4,                              'd',
            'o',                            'c',
            's',                            2,
            0,                              1,
            'a',                            0,
            5,                              'f',
            'i',                            'r',
            's',                            't',
            0,                              1,
            'b',                            0,
            6,                              's',
            'e',                            'c',
            'o',                            'n',
            'd',
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applySignatureHelpPacket(packet);

    var surface = MockSurface{ .mock_width = 60, .mock_height = 9 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 3, "f", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "d", null);
    try expectMockCell(&surface, 6, ">", null);
    try expectMockCell(&surface, 6, "b", null);
}

test "decodeFloatPopup retains title and lines" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_FLOAT_POPUP, 1,
            0,                           24,
            0,                           5,
            0,                           5,
            'H',                         'e',
            'l',                         'l',
            'o',                         0,
            2,                           0,
            5,                           'l',
            'i',                         'n',
            'e',                         '1',
            0,                           5,
            'l',                         'i',
            'n',                         'e',
            '2',
        };

    var popup = try decodeFloatPopup(alloc, packet);
    defer popup.deinit(alloc);

    try std.testing.expect(popup.visible);
    try std.testing.expectEqual(@as(u16, 24), popup.width);
    try std.testing.expectEqual(@as(u16, 5), popup.height);
    try std.testing.expectEqualStrings("Hello", popup.title);
    try std.testing.expectEqual(@as(usize, 2), popup.lines.len);
    try std.testing.expectEqualStrings("line1", popup.lines[0]);
    try std.testing.expectEqualStrings("line2", popup.lines[1]);
}

test "semantic state renders retained float popup centered" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_FLOAT_POPUP, 1,
            0,                           20,
            0,                           4,
            0,                           5,
            'H',                         'e',
            'l',                         'l',
            'o',                         0,
            1,                           0,
            5,                           'l',
            'i',                         'n',
            'e',                         '1',
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyFloatPopupPacket(packet);

    var surface = MockSurface{ .mock_width = 60, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 2, "H", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 3, "l", null);
    for (surface.cells.items) |cell| {
        if (cell.row == 2 and std.mem.eql(u8, cell.text, "H")) {
            try std.testing.expectEqual(@as(u16, 21), cell.col);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "semantic state renders visible empty float before lower priority overlays" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.float_popup = .{ .visible = true };
    state.tool_manager = .{ .visible = true };

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_popup = false;
    var saw_tool_manager = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "P")) saw_popup = true;
        if (std.mem.eql(u8, cell.text, "T")) saw_tool_manager = true;
    }

    try std.testing.expect(saw_popup);
    try std.testing.expect(!saw_tool_manager);
}

test "decodeGitStatus retains branch entries toast and tail fields" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_GIT_STATUS, 0,
            1,                          0,
            2,                          0,
            1,                          0,
            4,                          'm',
            'a',                        'i',
            'n',                        0,
            1,                          0x11,
            0x22,                       0x33,
            0x44,                       1,
            6,                          0,
            8,                          'l',
            'i',                        'b',
            '/',                        'a',
            '.',                        'e',
            'x',                        1,
            0,                          1,
            0,                          6,
            'p',                        'u',
            's',                        'h',
            'e',                        'd',
            0,                          3,
            'l',                        'i',
            'b',                        0,
            6,                          'c',
            'o',                        'm',
            'm',                        'i',
            't',                        0,
            2,
        };

    var git = try decodeGitStatus(alloc, packet);
    defer git.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0), git.repo_state);
    try std.testing.expect(git.syncing);
    try std.testing.expectEqual(@as(u16, 2), git.ahead);
    try std.testing.expectEqual(@as(u16, 1), git.behind);
    try std.testing.expectEqualStrings("main", git.branch);
    try std.testing.expectEqual(@as(usize, 1), git.entries.len);
    try std.testing.expectEqual(@as(u32, 0x11223344), git.entries[0].path_hash);
    try std.testing.expectEqual(@as(u8, 1), git.entries[0].section);
    try std.testing.expectEqual(@as(u8, 6), git.entries[0].status);
    try std.testing.expectEqualStrings("lib/a.ex", git.entries[0].path);
    try std.testing.expect(git.toast.visible);
    try std.testing.expectEqualStrings("pushed", git.toast.message);
    try std.testing.expectEqualStrings("lib", git.entry_base_path);
    try std.testing.expectEqualStrings("commit", git.last_commit_message);
    try std.testing.expectEqual(@as(u16, 2), git.stash_count);
}

test "semantic state does not render git status as a direct overlay" {
    const alloc = std.testing.allocator;
    const git_packet =
        &[_]u8{
            protocol.OP_GUI_GIT_STATUS, 0,
            1,                          0,
            2,                          0,
            1,                          0,
            4,                          'm',
            'a',                        'i',
            'n',                        0,
            0,                          0,
            0,                          0,
            0,                          0,
            0,                          0,
            1,
        };
    const status_packet =
        &[_]u8{
            protocol.OP_GUI_STATUS_BAR, 1,
            0x07,                       0,
            4,                          0,
            2,                          'o',
            'k',
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_accent, .rgb = 0x313233 },
        }),
    };
    try state.applyGitStatusPacket(git_packet);
    try state.applyStatusBarPacket(status_packet);

    var surface = MockSurface{ .mock_width = 60, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        try std.testing.expect(!(cell.row == 4 and std.mem.eql(u8, cell.text, "g")));
    }
    try expectMockCell(&surface, 3, "o", protocol.ATTR_BOLD);
}

test "decodeBottomPanel retains tabs and entries" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_BOTTOM_PANEL, 1,
            1,                            30,
            2,                            2,
            1,                            4,
            'L',                          'o',
            'g',                          's',
            2,                            5,
            'T',                          'e',
            's',                          't',
            's',                          0,
            1,                            0,
            0,                            0,
            7,                            3,
            4,                            0,
            0,                            0,
            42,                           0,
            8,                            'l',
            'i',                          'b',
            '/',                          'a',
            '.',                          'e',
            'x',                          0,
            4,                            'b',
            'o',                          'o',
            'm',
        };

    var panel = try decodeBottomPanel(alloc, packet);
    defer panel.deinit(alloc);

    try std.testing.expect(panel.visible);
    try std.testing.expectEqual(@as(u8, 1), panel.active_tab_index);
    try std.testing.expectEqual(@as(u8, 30), panel.height_percent);
    try std.testing.expectEqual(@as(u8, 2), panel.filter);
    try std.testing.expectEqual(@as(usize, 2), panel.tabs.len);
    try std.testing.expectEqualStrings("Logs", panel.tabs[0].name);
    try std.testing.expectEqualStrings("Tests", panel.tabs[1].name);
    try std.testing.expectEqual(@as(usize, 1), panel.entries.len);
    try std.testing.expectEqual(@as(u32, 7), panel.entries[0].id);
    try std.testing.expectEqual(@as(u8, 3), panel.entries[0].level);
    try std.testing.expectEqual(@as(u8, 4), panel.entries[0].subsystem);
    try std.testing.expectEqual(@as(u32, 42), panel.entries[0].timestamp_secs);
    try std.testing.expectEqualStrings("lib/a.ex", panel.entries[0].file_path);
    try std.testing.expectEqualStrings("boom", panel.entries[0].text);
}

test "semantic state renders retained bottom panel above status bar" {
    const alloc = std.testing.allocator;
    const panel_packet =
        &[_]u8{
            protocol.OP_GUI_BOTTOM_PANEL, 1,
            0,                            40,
            0,                            1,
            1,                            4,
            'L',                          'o',
            'g',                          's',
            0,                            1,
            0,                            0,
            0,                            7,
            3,                            4,
            0,                            0,
            0,                            42,
            0,                            8,
            'l',                          'i',
            'b',                          '/',
            'a',                          '.',
            'e',                          'x',
            0,                            4,
            'b',                          'o',
            'o',                          'm',
        };
    const status_packet =
        &[_]u8{
            protocol.OP_GUI_STATUS_BAR, 1,
            0x07,                       0,
            4,                          0,
            2,                          'o',
            'k',
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_accent, .rgb = 0x313233 },
            .{ .id = theme_modeline_bar_bg, .rgb = 0x414243 },
            .{ .id = theme_modeline_bar_fg, .rgb = 0x515253 },
        }),
    };
    try state.applyBottomPanelPacket(panel_packet);
    try state.applyStatusBarPacket(status_packet);

    var surface = MockSurface{ .mock_width = 60, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_path_header = false;
    var saw_message_header = false;
    var saw_level = false;
    var saw_path = false;
    var saw_message = false;
    var saw_panel_background = false;
    var saw_status = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 4 and cell.col == 0 and std.mem.eql(u8, cell.text, "L") and cell.fg == 0x313233 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 4 and cell.col == 10 and std.mem.eql(u8, cell.text, "P") and cell.fg == 0x313233 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_path_header = true;
        if (cell.row == 4 and cell.col == 25 and std.mem.eql(u8, cell.text, "M") and cell.fg == 0x313233 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_message_header = true;
        if (cell.row == 5 and cell.col == 0 and std.mem.eql(u8, cell.text, "o") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_level = true;
        if (cell.row == 5 and cell.col == 10 and std.mem.eql(u8, cell.text, "l") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_path = true;
        if (cell.row == 5 and cell.col == 25 and std.mem.eql(u8, cell.text, "b") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_message = true;
        if (cell.row == 4 and cell.col == 59 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_panel_background = true;
        if (cell.row == 6 and std.mem.eql(u8, cell.text, "o") and cell.bg == 0x414243) saw_status = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_path_header);
    try std.testing.expect(saw_message_header);
    try std.testing.expect(saw_level);
    try std.testing.expect(saw_path);
    try std.testing.expect(saw_message);
    try std.testing.expect(saw_panel_background);
    try std.testing.expect(saw_status);
}

test "semantic state suppresses visible empty bottom panel like Go" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.bottom_panel = .{ .visible = true };

    var surface = MockSurface{ .mock_width = 60, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 5 and std.mem.eql(u8, cell.text, "P")) saw_title = true;
    }

    try std.testing.expect(!saw_title);
}

test "decodeFileTree retains rows and metadata" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_FILE_TREE, 0,    0,   0,   134,
            2,                         3,    3,   0,   5,
            'r',                       'o',  'w', '-', '1',
            0,                         5,    '/', 'r', 'e',
            'p',                       'o',  0,   18,  0,
            2,                         0,    0,   0,   0,
            0,                         1,    0,   3,   0,
            0,                         0,    0,   0,   0,
            0,                         0,    0,   0,   0,
            0,                         5,    'r', 'o', 'w',
            '-',                       '0',  0,   9,   '/',
            'r',                       'e',  'p', 'o', '/',
            'l',                       'i',  'b', 0,   3,
            'l',                       'i',  'b', 0,   3,
            'l',                       'i',  'b', 1,   'D',
            0xFF,                      0,    0,   0,   0,
            0,                         2,    0,   32,  1,
            0,                         0,    0,   0,   0,
            0,                         0,    0,   0,   0,
            0,                         5,    'r', 'o', 'w',
            '-',                       '1',  0,   14,  '/',
            'r',                       'e',  'p', 'o', '/',
            'l',                       'i',  'b', '/', 'a',
            '.',                       'e',  'x', 0,   8,
            'l',                       'i',  'b', '/', 'a',
            '.',                       'e',  'x', 0,   4,
            'a',                       '.',  'e', 'x', 1,
            'E',                       0xFF, 0,   0,
        };

    var tree = try decodeFileTree(alloc, packet);
    defer tree.deinit(alloc);

    try std.testing.expect(tree.visible);
    try std.testing.expect(tree.focused);
    try std.testing.expectEqual(@as(u8, 3), tree.status);
    try std.testing.expectEqual(@as(u16, 18), tree.width);
    try std.testing.expectEqualStrings("row-1", tree.selected_id);
    try std.testing.expectEqualStrings("/repo", tree.root_path);
    try std.testing.expectEqual(@as(usize, 2), tree.rows.len);
    try std.testing.expect(tree.rows[0].directory());
    try std.testing.expect(tree.rows[0].expanded());
    try std.testing.expectEqualStrings("/repo/lib", tree.rows[0].path);
    try std.testing.expectEqualStrings("lib", tree.rows[0].name);
    try std.testing.expectEqual(@as(u8, 1), tree.rows[1].depth);
    try std.testing.expect(tree.rows[1].dirty());
    try std.testing.expect(!tree.rows[1].selected());
    try std.testing.expect(!tree.rows[1].focused());
    try std.testing.expect(!tree.rows[1].active());
    try std.testing.expectEqual(@as(u16, 0), tree.rows[1].visibleDiagnostics());
    try std.testing.expectEqualStrings("/repo/lib/a.ex", tree.rows[1].path);
    try std.testing.expectEqualStrings("a.ex", tree.rows[1].name);
}

test "semantic state applies retained file tree selection" {
    const alloc = std.testing.allocator;
    const tree_packet =
        &[_]u8{
            protocol.OP_GUI_FILE_TREE, 0,   0,   0,    76,
            2,                         1,   3,   0,    5,
            'r',                       'o', 'w', '-',  '0',
            0,                         5,   '/', 'r',  'e',
            'p',                       'o', 0,   18,   0,
            1,                         0,   0,   0,    0,
            0,                         1,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         5,   'r', 'o',  'w',
            '-',                       '0', 0,   10,   '/',
            'r',                       'e', 'p', 'o',  '/',
            'a',                       '.', 'e', 'x',  0,
            4,                         'a', '.', 'e',  'x',
            0,                         4,   'a', '.',  'e',
            'x',                       1,   'E', 0xFF, 0,
            0,
        };
    const selection_packet =
        &[_]u8{
            protocol.OP_GUI_FILE_TREE_SELECTION, 0,   8,
            1,                                   0,   5,
            'r',                                 'o', 'w',
            '-',                                 '1',
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyFileTreePacket(tree_packet);
    try state.applyFileTreeSelectionPacket(selection_packet);

    try std.testing.expect(state.file_tree.?.focused);
    try std.testing.expectEqualStrings("row-1", state.file_tree.?.selected_id);
}

test "semantic state renders retained file tree sidebar" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_FILE_TREE, 0,   0,   0,    76,
            2,                         1,   3,   0,    5,
            'r',                       'o', 'w', '-',  '0',
            0,                         5,   '/', 'r',  'e',
            'p',                       'o', 0,   18,   0,
            1,                         0,   0,   0,    0,
            0,                         1,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         5,   'r', 'o',  'w',
            '-',                       '0', 0,   10,   '/',
            'r',                       'e', 'p', 'o',  '/',
            'a',                       '.', 'e', 'x',  0,
            4,                         'a', '.', 'e',  'x',
            0,                         4,   'a', '.',  'e',
            'x',                       1,   'E', 0xFF, 0,
            0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_tree_bg, .rgb = 0x010203 },
            .{ .id = theme_tree_fg, .rgb = 0x111213 },
            .{ .id = theme_tree_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_tree_selection_fg, .rgb = 0x313233 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x414243 },
            .{ .id = theme_gutter_error_fg, .rgb = 0x515253 },
        }),
    };
    try state.applyFileTreePacket(packet);
    state.file_tree.?.rows[0].git_status = 1;
    state.file_tree.?.rows[0].diagnostic_errors = 2;

    var surface = MockSurface{ .mock_width = 80, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_selected = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and cell.col == 0 and std.mem.eql(u8, cell.text, "F") and cell.fg == 0x111213 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "a") and cell.fg == 0x313233 and cell.bg == 0x212223 and cell.attrs == protocol.ATTR_BOLD) saw_selected = true;
        if (cell.row == 2 and cell.col == 17 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_selected);
    try std.testing.expect(saw_background);
    try expectMockCellStyled(&surface, 1, "M", 0x313233, 0x212223, protocol.ATTR_BOLD);
    try expectMockCellStyled(&surface, 1, "2", 0x515253, 0x212223, 0);
}

test "semantic state hit-tests retained file tree rows" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.file_tree = .{
        .visible = true,
        .focused = true,
        .status = 3,
        .width = 18,
        .rows = try alloc.dupe(FileTreeRow, &[_]FileTreeRow{
            .{ .flags = 0x01, .depth = 0 },
            .{ .depth = 1 },
        }),
    };

    const toggle = state.hitTest(1, 0, 80, 5) orelse return error.TestExpectedEqual;
    switch (toggle) {
        .u16_payload => |payload| {
            try std.testing.expectEqual(protocol.GUI_ACTION_FILE_TREE_TOGGLE, payload.action);
            try std.testing.expectEqual(@as(u16, 0), payload.value);
        },
        else => return error.TestExpectedEqual,
    }

    const click = state.hitTest(2, 5, 80, 5) orelse return error.TestExpectedEqual;
    switch (click) {
        .u16_payload => |payload| {
            try std.testing.expectEqual(protocol.GUI_ACTION_FILE_TREE_CLICK, payload.action);
            try std.testing.expectEqual(@as(u16, 1), payload.value);
        },
        else => return error.TestExpectedEqual,
    }
}

test "semantic state renders file tree row selected from decoded row flags" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_FILE_TREE, 0,   0,   0,    76,
            2,                         1,   3,   0,    5,
            'r',                       'o', 'w', '-',  '9',
            0,                         5,   '/', 'r',  'e',
            'p',                       'o', 0,   18,   0,
            1,                         0,   0,   0,    0,
            0,                         4,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         5,   'r', 'o',  'w',
            '-',                       '0', 0,   10,   '/',
            'r',                       'e', 'p', 'o',  '/',
            'a',                       '.', 'e', 'x',  0,
            4,                         'a', '.', 'e',  'x',
            0,                         4,   'a', '.',  'e',
            'x',                       1,   'E', 0xFF, 0,
            0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_tree_bg, .rgb = 0x010203 },
            .{ .id = theme_tree_fg, .rgb = 0x111213 },
            .{ .id = theme_tree_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_tree_selection_fg, .rgb = 0x313233 },
        }),
    };
    try state.applyFileTreePacket(packet);
    state.file_tree.?.rows[0].flags |= 0x0004;

    var surface = MockSurface{ .mock_width = 80, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expect(state.file_tree.?.rows[0].selected());
    try expectMockCellStyled(&surface, 1, "a", 0x313233, 0x212223, protocol.ATTR_BOLD);
}

test "semantic state lets sidebars render when file tree is not visible for width" {
    const alloc = std.testing.allocator;
    const tree_packet =
        &[_]u8{
            protocol.OP_GUI_FILE_TREE, 0,   0,   0,    76,
            2,                         1,   3,   0,    5,
            'r',                       'o', 'w', '-',  '0',
            0,                         5,   '/', 'r',  'e',
            'p',                       'o', 0,   18,   0,
            1,                         0,   0,   0,    0,
            0,                         1,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         0,   0,   0,    0,
            0,                         5,   'r', 'o',  'w',
            '-',                       '0', 0,   10,   '/',
            'r',                       'e', 'p', 'o',  '/',
            'a',                       '.', 'e', 'x',  0,
            4,                         'a', '.', 'e',  'x',
            0,                         4,   'a', '.',  'e',
            'x',                       1,   'E', 0xFF, 0,
            0,
        };
    const sidebars_packet =
        &[_]u8{
            protocol.OP_GUI_SIDEBARS, 0,   0,   0,   45,
            1,                        0,   1,   0,   5,
            'f',                      'i', 'l', 'e', 's',
            0,                        5,   'f', 'i', 'l',
            'e',                      's', 0,   5,   'F',
            'i',                      'l', 'e', 's', 0,
            9,                        'f', 'i', 'l', 'e',
            '_',                      't', 'r', 'e', 'e',
            0,                        1,   'F', 0,   0,
            3,                        0,   22,  0,   2,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyFileTreePacket(tree_packet);
    try state.applySidebarsPacket(sidebars_packet);
    state.file_tree.?.width = 0;

    var surface = MockSurface{ .mock_width = 80, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_sidebars = false;
    var saw_file_tree_header = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and cell.col == 0 and std.mem.eql(u8, cell.text, "S")) saw_sidebars = true;
        if (cell.row == 0 and cell.col == 0 and std.mem.eql(u8, cell.text, "F")) saw_file_tree_header = true;
    }

    try std.testing.expect(saw_sidebars);
    try std.testing.expect(!saw_file_tree_header);
}

test "file tree status text matches Go empty default" {
    try std.testing.expectEqualStrings("", fileTreeStatusText(.{ .status = 0 }));
    try std.testing.expectEqualStrings("No files", fileTreeStatusText(.{ .status = 2 }));
    try std.testing.expectEqualStrings("File tree error", fileTreeStatusText(.{ .status = 4 }));
}

test "decodeSidebars retains visible sidebar entries" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SIDEBARS, 0,   0,   0,   45,
            1,                        0,   1,   0,   5,
            'f',                      'i', 'l', 'e', 's',
            0,                        5,   'f', 'i', 'l',
            'e',                      's', 0,   5,   'F',
            'i',                      'l', 'e', 's', 0,
            9,                        'f', 'i', 'l', 'e',
            '_',                      't', 'r', 'e', 'e',
            0,                        1,   'F', 0,   0,
            3,                        0,   22,  0,   2,
        };

    var sidebars = try decodeSidebars(alloc, packet);
    defer sidebars.deinit(alloc);

    try std.testing.expect(sidebars.visible);
    try std.testing.expectEqualStrings("files", sidebars.active_id);
    try std.testing.expectEqual(@as(usize, 1), sidebars.items.len);
    try std.testing.expectEqualStrings("Files", sidebars.items[0].display_name);
    try std.testing.expectEqualStrings("file_tree", sidebars.items[0].semantic_kind);
    try std.testing.expect(sidebars.items[0].visible);
    try std.testing.expect(sidebars.items[0].focused);
    try std.testing.expectEqual(@as(u16, 22), sidebars.items[0].preferred_width);
    try std.testing.expectEqual(@as(u16, 2), sidebars.items[0].badge_count);
}

test "semantic state renders retained sidebars" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SIDEBARS, 0,   0,   0,   45,
            1,                        0,   1,   0,   5,
            'f',                      'i', 'l', 'e', 's',
            0,                        5,   'f', 'i', 'l',
            'e',                      's', 0,   5,   'F',
            'i',                      'l', 'e', 's', 0,
            9,                        'f', 'i', 'l', 'e',
            '_',                      't', 'r', 'e', 'e',
            0,                        1,   'F', 0,   0,
            3,                        0,   22,  0,   2,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_tree_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_popup_selection_fg, .rgb = 0x313233 },
        }),
    };
    try state.applySidebarsPacket(packet);

    var surface = MockSurface{ .mock_width = 80 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_header = false;
    var saw_selected = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and cell.col == 0 and std.mem.eql(u8, cell.text, "S") and cell.fg == 0x111213 and cell.bg == 0x010203 and cell.attrs == 0) saw_header = true;
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "F") and cell.fg == 0x313233 and cell.bg == 0x212223 and cell.attrs == protocol.ATTR_BOLD) saw_selected = true;
        if (cell.row == 2 and cell.col == 17 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_header);
    try std.testing.expect(saw_selected);
    try std.testing.expect(saw_background);
}

test "semantic state renders sidebar items even when container visible flag is false" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SIDEBARS, 0,   0,   0,   45,
            0,                        0,   1,   0,   5,
            'f',                      'i', 'l', 'e', 's',
            0,                        5,   'f', 'i', 'l',
            'e',                      's', 0,   5,   'F',
            'i',                      'l', 'e', 's', 0,
            9,                        'f', 'i', 'l', 'e',
            '_',                      't', 'r', 'e', 'e',
            0,                        1,   'F', 0,   0,
            3,                        0,   22,  0,   2,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applySidebarsPacket(packet);

    var surface = MockSurface{ .mock_width = 80 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_header = false;
    var saw_item = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and cell.col == 0 and std.mem.eql(u8, cell.text, "S")) saw_header = true;
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "F")) saw_item = true;
    }

    try std.testing.expect(saw_header);
    try std.testing.expect(saw_item);
}

test "decodeTheme retains color slots" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_THEME, 2,
            0x40,                  0x11,
            0x22,                  0x33,
            0x30,                  0x44,
            0x55,                  0x66,
        };

    var theme = try decodeTheme(alloc, packet);
    defer theme.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), theme.slots.len);
    try std.testing.expectEqual(@as(u8, 0x40), theme.slots[0].id);
    try std.testing.expectEqual(@as(u24, 0x112233), theme.slots[0].rgb);
    try std.testing.expectEqual(@as(u24, 0x445566), theme.color(0x30));
}

test "decodeWorkspaces retains spaces and visible tabs" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WORKSPACES, 0,    72,
            2,                          0,    7,
            0,                          1,    1,
            0,                          7,    0,
            0,                          0,    1,
            0x11,                       0x22, 0x33,
            0,                          2,    0,
            1,                          0,    0,
            0,                          0,    4,
            'M',                        'a',  'i',
            'n',                        1,    '*',
            0,                          1,    0,
            0,                          0,    42,
            0,                          7,    0,
            0,                          1,    0,
            0,                          0,    1,
            1,                          'E',  0,
            7,                          'm',  'a',
            'i',                        'n',  '.',
            'e',                        'x',  0,
            10,                         '/',  'r',
            'e',                        'p',  'o',
            '/',                        'a',  '.',
            'e',                        'x',  0,
            0,                          0,    0,
        };

    var workspaces = try decodeWorkspaces(alloc, packet);
    defer workspaces.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 2), workspaces.visible);
    try std.testing.expectEqual(@as(u16, 7), workspaces.active_workspace_id);
    try std.testing.expectEqual(@as(usize, 1), workspaces.spaces.len);
    try std.testing.expectEqualStrings("Main", workspaces.spaces[0].label);
    try std.testing.expect(workspaces.spaces[0].attention());
    try std.testing.expectEqual(@as(usize, 1), workspaces.tabs.len);
    try std.testing.expectEqualStrings("main.ex", workspaces.tabs[0].label);
    try std.testing.expect(workspaces.tabs[0].dirty());
}

test "semantic state renders workspaces above tabs" {
    const alloc = std.testing.allocator;
    const tabs_packet =
        &[_]u8{
            protocol.OP_GUI_TAB_BAR, 0,   1,
            0x01,                    0,   0,
            0,                       1,   0,
            7,                       1,   'E',
            0,                       6,   'e',
            'd',                     'i', 't',
            '.',                     'e', 0,
            0,                       0,   0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x111213 },
            .{ .id = theme_accent, .rgb = 0x212223 },
        }),
    };
    try state.applyTabBarPacket(tabs_packet);
    state.workspaces = .{
        .visible = 2,
        .active_workspace_id = 7,
        .workspace_count = 2,
        .spaces = try alloc.dupe(Workspace, &[_]Workspace{
            .{
                .id = 1,
                .tab_count = 1,
                .label = try alloc.dupe(u8, "Files"),
                .icon = try alloc.dupe(u8, "F"),
            },
            .{
                .id = 7,
                .flags = 0x01,
                .color = 0x313233,
                .tab_count = 2,
                .label = try alloc.dupe(u8, "Main"),
                .icon = try alloc.dupe(u8, "*"),
            },
        }),
    };

    var surface = MockSurface{ .mock_width = 40, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCellStyled(&surface, 0, "S", 0x111213, 0x010203, 0);
    try expectMockText(&surface, 0, "Files");
    try expectMockText(&surface, 0, "Main");
    try expectMockCellStyled(&surface, 0, "M", 0x212223, 0x010203, protocol.ATTR_BOLD);
    try expectMockCell(&surface, 1, "e", protocol.ATTR_BOLD);
}

test "semantic state renders a combined Go-style frame with retained chrome and window content" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();

    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
            .{ .id = theme_editor_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_accent, .rgb = 0x313233 },
            .{ .id = theme_tab_bg, .rgb = 0x414243 },
            .{ .id = theme_tab_active_bg, .rgb = 0x515253 },
            .{ .id = theme_tab_active_fg, .rgb = 0x616263 },
            .{ .id = theme_modeline_bar_bg, .rgb = 0x717273 },
            .{ .id = theme_modeline_bar_fg, .rgb = 0x818283 },
        }),
    };
    state.workspaces = .{
        .visible = 2,
        .active_workspace_id = 7,
        .workspace_count = 2,
        .spaces = try alloc.dupe(Workspace, &[_]Workspace{
            .{
                .id = 1,
                .tab_count = 1,
                .label = try alloc.dupe(u8, "Files"),
                .icon = try alloc.dupe(u8, "F"),
            },
            .{
                .id = 7,
                .flags = 0x01,
                .color = 0x919293,
                .tab_count = 2,
                .label = try alloc.dupe(u8, "Main"),
                .icon = try alloc.dupe(u8, "*"),
            },
        }),
    };
    state.tab_bar = .{
        .active_index = 0,
        .tabs = try alloc.dupe(Tab, &[_]Tab{
            .{
                .id = 11,
                .flags = 0x01,
                .group_id = 7,
                .icon = try alloc.dupe(u8, "E"),
                .label = try alloc.dupe(u8, "main.ex"),
            },
        }),
    };
    state.breadcrumb = .{
        .segments = try alloc.dupe([]u8, &[_][]u8{
            try alloc.dupe(u8, "lib"),
            try alloc.dupe(u8, "main.ex"),
        }),
    };
    state.windows = try alloc.dupe(WindowContent, &[_]WindowContent{
        .{
            .window_id = 42,
            .cursor_row = 3,
            .cursor_col = 6,
            .cursor_shape = 1,
            .text_width = 72,
            .text_height = 7,
            .rows = try alloc.dupe(WindowRow, &[_]WindowRow{
                .{ .text = try alloc.dupe(u8, "window-zero") },
                .{ .text = try alloc.dupe(u8, "window-one") },
                .{ .text = try alloc.dupe(u8, "window-two") },
                .{ .text = try alloc.dupe(u8, "const main = 1;") },
                .{ .text = try alloc.dupe(u8, "pub fn run() void {}") },
            }),
        },
    });
    state.cursor_window_id = 42;
    state.status_bar = .{
        .filename = try alloc.dupe(u8, "main.ex"),
        .message = try alloc.dupe(u8, "ok"),
        .line = 4,
        .col = 7,
        .line_count = 20,
    };
    state.search_state = .{
        .active = true,
        .match_count = 4,
        .current_index = 2,
    };

    var surface = MockSurface{ .mock_width = 72, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockText(&surface, 0, "Spaces");
    try expectMockText(&surface, 0, "Files");
    try expectMockText(&surface, 0, "Main");
    try expectMockCellStyled(&surface, 1, "▌", 0x616263, 0x515253, protocol.ATTR_BOLD);
    try expectMockText(&surface, 1, "main.ex");
    try expectMockText(&surface, 2, "lib");
    try expectMockText(&surface, 2, "main.ex");
    try expectMockText(&surface, 3, "const main = 1;");
    try expectMockText(&surface, 4, "pub fn run() void {}");
    try expectMockText(&surface, 6, "main.ex");
    try expectMockText(&surface, 6, "search");
    try std.testing.expectEqual(@as(?u16, 6), surface.cursor_col);
    try std.testing.expectEqual(@as(?u16, 3), surface.cursor_row);
    try std.testing.expectEqual(surface_mod.CursorShape.beam, surface.cursor_shape.?);
}

test "decodeGutter retains window config and entries" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_GUTTER, 3,
            0x01,                   0,
            11,                     0,
            7,                      0,
            1,                      0,
            0,                      0,
            2,                      1,
            0,                      4,
            0x02,                   0,
            7,                      0,
            0,                      0,
            41,                     0,
            4,                      2,
            0x03,                   0,
            27,                     0,
            2,                      0,
            0,                      0,
            41,                     0,
            0,                      0xFF,
            0xFF,                   0xFF,
            0xFF,                   0,
            0,                      0,
            42,                     5,
            8,                      0xFF,
            0xFF,                   0xFF,
            0xFF,                   0x11,
            0x22,                   0x33,
            1,                      'A',
        };

    var gutter = try decodeGutter(alloc, packet);
    defer gutter.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 7), gutter.window_id);
    try std.testing.expectEqual(@as(u16, 1), gutter.content_row);
    try std.testing.expectEqual(@as(u16, 2), gutter.content_height);
    try std.testing.expect(gutter.is_active);
    try std.testing.expectEqual(@as(u32, 41), gutter.cursor_line);
    try std.testing.expectEqual(@as(u8, 4), gutter.line_number_width);
    try std.testing.expectEqual(@as(usize, 2), gutter.entries.len);
    try std.testing.expectEqual(@as(u32, 42), gutter.entries[1].buf_line);
    try std.testing.expectEqual(@as(u8, 8), gutter.entries[1].sign_type);
    try std.testing.expectEqualStrings("A", gutter.entries[1].sign_text);
}

test "semantic state hit-tests retained gutter fold toggles" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.gutters = try alloc.dupe(Gutter, &[_]Gutter{
        .{
            .window_id = 7,
            .content_row = 1,
            .content_col = 0,
            .content_height = 1,
            .line_number_width = 4,
            .sign_col_width = 2,
            .entries = try alloc.dupe(GutterEntry, &[_]GutterEntry{
                .{ .buf_line = 41, .display_type = 1, .fold_end_line = 45 },
            }),
        },
    });

    const action = state.hitTest(1, 1, 20, 4) orelse return error.TestExpectedEqual;
    switch (action) {
        .fold_toggle => |payload| {
            try std.testing.expectEqual(@as(u16, 7), payload.window_id);
            try std.testing.expectEqual(@as(u32, 41), payload.buffer_line);
        },
        else => return error.TestExpectedEqual,
    }
}

test "decodeIndentGuides retains guide columns and levels" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_INDENT_GUIDES, 0, 11,
            0,                             7, 2,
            0,                             2, 1,
            0,                             2, 0,
            2,                             1, 0,
        };

    var guides = try decodeIndentGuides(alloc, packet);
    defer guides.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 7), guides.window_id);
    try std.testing.expectEqual(@as(u8, 2), guides.tab_width);
    try std.testing.expectEqual(@as(u16, 2), guides.active_guide_col);
    try std.testing.expectEqual(@as(usize, 1), guides.guide_cols.len);
    try std.testing.expectEqual(@as(u16, 2), guides.guide_cols[0]);
    try std.testing.expectEqual(@as(usize, 2), guides.line_indent_levels.len);
    try std.testing.expectEqual(@as(u8, 1), guides.line_indent_levels[0]);
}

test "semantic state renders retained gutter and indent guides with window rows" {
    const alloc = std.testing.allocator;
    const gutter_packet =
        &[_]u8{
            protocol.OP_GUI_GUTTER, 3,
            0x01,                   0,
            11,                     0,
            7,                      0,
            1,                      0,
            0,                      0,
            1,                      1,
            0,                      4,
            0x02,                   0,
            7,                      0,
            0,                      0,
            2,                      0,
            3,                      1,
            0x03,                   0,
            12,                     0,
            1,                      0,
            0,                      0,
            2,                      0,
            1,                      0xFF,
            0xFF,                   0xFF,
            0xFF,
        };
    const guides_packet =
        &[_]u8{
            protocol.OP_GUI_INDENT_GUIDES, 0, 11,
            0,                             7, 2,
            0,                             1, 1,
            0,                             1, 0,
            1,                             1,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
            .{ .id = theme_gutter_fg, .rgb = 0x111213 },
            .{ .id = theme_gutter_current_fg, .rgb = 0x212223 },
        }),
    };
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .origin_row = 1,
        .origin_col = 4,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "  x"),
        .spans = &.{},
    };

    try state.applyGutterPacket(gutter_packet);
    try state.applyIndentGuidesPacket(guides_packet);

    var surface = MockSurface{ .mock_width = 20, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_gutter = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "!") and cell.fg == 0x212223 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_gutter = true;
    }
    try std.testing.expect(saw_gutter);
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 5 and std.mem.eql(u8, cell.text, "│")) return;
    }
    return error.TestExpectedEqual;
}

test "decodeWindowContent retains header rows spans and geometry" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_CONTENT, 3,
            0x01,                           0,
            14,                             0,
            7,                              0x02,
            0,                              1,
            0,                              2,
            0,                              0,
            0,                              0,
            0,                              0,
            9,                              0x02,
            0,                              43,
            0,                              1,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              0,
            1,                              0,
            0,                              0,
            42,                             0x01,
            0x02,                           0x03,
            0x04,                           0,
            0,                              0,
            5,                              'h',
            'e',                            'l',
            'l',                            'o',
            0,                              1,
            0,                              0,
            0,                              5,
            0x11,                           0x22,
            0x33,                           0,
            0,                              0,
            protocol.ATTR_BOLD,             0,
            0,                              0x08,
            0,                              67,
            0,                              7,
            0,                              0,
            0,                              0,
            0,                              20,
            0,                              4,
            0,                              0,
            0,                              0,
            0,                              20,
            0,                              4,
            0,                              1,
            0,                              2,
            0,                              10,
            0,                              2,
            0,                              1,
            0,                              0,
            0,                              2,
            0,                              2,
            0,                              1,
            0,                              2,
            0,                              10,
            0,                              2,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              2,
            0,                              10,
            0,                              0,
            0,                              42,
            0,                              0,
            0,                              0,
            0,                              42,
            0,                              4,
            0,                              1,
            0,
        };

    var window = try decodeWindowContent(alloc, packet);
    defer window.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 7), window.window_id);
    try std.testing.expectEqual(@as(u8, 0x02), window.flags);
    try std.testing.expectEqual(@as(u16, 1), window.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), window.cursor_col);
    try std.testing.expectEqual(@as(u32, 9), window.content_epoch);
    try std.testing.expectEqual(@as(u16, 1), window.origin_row);
    try std.testing.expectEqual(@as(u16, 2), window.origin_col);
    try std.testing.expectEqual(@as(u16, 10), window.text_width);
    try std.testing.expectEqual(@as(u16, 2), window.text_height);
    try std.testing.expectEqual(@as(usize, 1), window.rows.len);
    try std.testing.expectEqual(@as(u64, 1), window.rows[0].row_id);
    try std.testing.expectEqual(@as(u32, 42), window.rows[0].buf_line);
    try std.testing.expectEqualStrings("hello", window.rows[0].text);
    try std.testing.expectEqual(@as(usize, 1), window.rows[0].spans.len);
    try std.testing.expectEqual(@as(u24, 0x112233), window.rows[0].spans[0].fg);
    try std.testing.expectEqual(@as(u8, protocol.ATTR_BOLD), window.rows[0].spans[0].attrs);
}

test "semantic state renders retained window content rows" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_CONTENT, 3,
            0x01,                           0,
            14,                             0,
            7,                              0x02,
            0,                              1,
            0,                              2,
            0,                              0,
            0,                              0,
            0,                              0,
            9,                              0x02,
            0,                              43,
            0,                              1,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              0,
            1,                              0,
            0,                              0,
            42,                             0x01,
            0x02,                           0x03,
            0x04,                           0,
            0,                              0,
            5,                              'h',
            'e',                            'l',
            'l',                            'o',
            0,                              1,
            0,                              0,
            0,                              5,
            0x11,                           0x22,
            0x33,                           0,
            0,                              0,
            protocol.ATTR_BOLD,             0,
            0,                              0x08,
            0,                              67,
            0,                              7,
            0,                              0,
            0,                              0,
            0,                              20,
            0,                              4,
            0,                              0,
            0,                              0,
            0,                              20,
            0,                              4,
            0,                              1,
            0,                              2,
            0,                              10,
            0,                              2,
            0,                              1,
            0,                              0,
            0,                              2,
            0,                              2,
            0,                              1,
            0,                              2,
            0,                              10,
            0,                              2,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              2,
            0,                              10,
            0,                              0,
            0,                              42,
            0,                              0,
            0,                              0,
            0,                              42,
            0,                              4,
            0,                              1,
            0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyWindowContentPacket(packet);

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 2 and std.mem.eql(u8, cell.text, "h")) {
            try std.testing.expectEqual(@as(u24, 0x112233), cell.fg);
            try std.testing.expectEqual(@as(u8, protocol.ATTR_BOLD), cell.attrs);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "semantic state renders retained window tilde rows past content" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 3,
        .cursorline_visible = true,
        .cursorline_row = 2,
        .cursorline_bg = 0x123456,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hello"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 6 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 2, "~", null);
    var saw_tilde = false;
    var saw_trailing_bg = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 3 and cell.col == 2 and std.mem.eql(u8, cell.text, "~")) {
            try std.testing.expectEqual(@as(u24, 0x123456), cell.bg);
            saw_tilde = true;
        }
        if (cell.row == 3 and cell.col == 3 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x123456) saw_trailing_bg = true;
    }
    try std.testing.expect(saw_tilde);
    try std.testing.expect(saw_trailing_bg);
}

test "semantic state fills retained window row cursorline background" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 6,
        .text_height = 1,
        .cursorline_visible = true,
        .cursorline_row = 0,
        .cursorline_bg = 0x123456,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hi"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 5 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x123456) return;
    }
    return error.TestExpectedEqual;
}

test "semantic state maps retained window span attrs to surface attrs" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 8,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "abcd"),
        .spans = try alloc.dupe(WindowSpan, &[_]WindowSpan{
            .{ .start_col = 0, .end_col = 1, .attrs = 0x02 },
            .{ .start_col = 1, .end_col = 2, .attrs = 0x04 },
            .{ .start_col = 2, .end_col = 3, .attrs = 0x08 },
            .{ .start_col = 3, .end_col = 4, .attrs = 0x10 },
        }),
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_italic = false;
    var saw_underline = false;
    var saw_strike = false;
    var saw_curl = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 2 and std.mem.eql(u8, cell.text, "a") and cell.attrs == protocol.ATTR_ITALIC) saw_italic = true;
        if (cell.row == 1 and cell.col == 3 and std.mem.eql(u8, cell.text, "b") and cell.attrs == protocol.ATTR_UNDERLINE) saw_underline = true;
        if (cell.row == 1 and cell.col == 4 and std.mem.eql(u8, cell.text, "c") and cell.strikethrough) saw_strike = true;
        if (cell.row == 1 and cell.col == 5 and std.mem.eql(u8, cell.text, "d") and cell.attrs & protocol.ATTR_UNDERLINE != 0 and cell.ul_style == 1) saw_curl = true;
    }

    try std.testing.expect(saw_italic);
    try std.testing.expect(saw_underline);
    try std.testing.expect(saw_strike);
    try std.testing.expect(saw_curl);
}

test "semantic state applies retained window cursor position and shape" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .flags = 0x01,
        .cursor_row = 0,
        .cursor_col = 4,
        .cursor_shape = 1,
        .scroll_left = 1,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hello"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expectEqual(@as(?u16, 5), surface.cursor_col);
    try std.testing.expectEqual(@as(?u16, 1), surface.cursor_row);
    try std.testing.expectEqual(@as(?surface_mod.CursorShape, .beam), surface.cursor_shape);
}

test "semantic state applies retained window cursor position with gutter width" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.gutters = try alloc.alloc(Gutter, 1);
    state.gutters[0] = .{
        .window_id = 7,
        .line_number_width = 3,
        .sign_col_width = 1,
    };
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .flags = 0x01,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_shape = 0,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hello"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    // gutter width = sign_col_width(1) + line_number_width(3) = 4 (the separator
    // is the last column of the line-number field, no extra column), so the
    // cursor lands at origin_col(2) + gutter_width(4) = 6.
    try std.testing.expectEqual(@as(?u16, 6), surface.cursor_col);
    try std.testing.expectEqual(@as(?u16, 1), surface.cursor_row);
    try std.testing.expectEqual(@as(?surface_mod.CursorShape, .block), surface.cursor_shape);
}

test "semantic state does not apply clipped retained window cursor" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .cursor_row = 0,
        .cursor_col = 11,
        .cursor_shape = 2,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hello"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expectEqual(@as(?u16, null), surface.cursor_col);
    try std.testing.expectEqual(@as(?u16, null), surface.cursor_row);
    try std.testing.expectEqual(@as(?surface_mod.CursorShape, null), surface.cursor_shape);
}

test "semantic state hides window cursor when cursor_visible is false" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .cursor_visible = false,
        .cursor_row = 0,
        .cursor_col = 2,
        .cursor_shape = 0,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hello"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expectEqual(@as(?u16, null), surface.cursor_col);
    try std.testing.expectEqual(@as(?u16, null), surface.cursor_row);
}

test "semantic state places terminal cursor in active minibuffer" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();

    // Window cursor is hidden because the minibuffer owns the cursor.
    state.windows = try alloc.alloc(WindowContent, 1);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .cursor_visible = false,
        .cursor_row = 0,
        .cursor_col = 4,
        .origin_row = 0,
        .origin_col = 0,
        .text_width = 20,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "hello"),
        .spans = &.{},
    };

    // Command mode: prompt ":", input "q", cursor_pos 1 (after the input).
    state.minibuffer = .{
        .visible = true,
        .mode = 0,
        .cursor_pos = 1,
        .prompt = try alloc.dupe(u8, ":"),
        .input = try alloc.dupe(u8, "q"),
    };

    var surface = MockSurface{ .mock_width = 24, .mock_height = 24 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    // No status bar: minibuffer is on the last row. Cursor col = prompt
    // width(1) + input cursor offset(1) = 2.
    try std.testing.expectEqual(@as(?u16, 23), surface.cursor_row);
    try std.testing.expectEqual(@as(?u16, 2), surface.cursor_col);
    try std.testing.expectEqual(@as(?surface_mod.CursorShape, .beam), surface.cursor_shape);
}

test "semantic state renders cursor from retained cursor window id" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 2);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .flags = 0x01,
        .cursor_row = 0,
        .cursor_col = 2,
        .cursor_shape = 1,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "left"),
        .spans = &.{},
    };
    state.windows[1] = .{
        .window_id = 9,
        .flags = 0x01,
        .cursor_row = 0,
        .cursor_col = 0,
        .cursor_shape = 2,
        .origin_row = 3,
        .origin_col = 12,
        .text_width = 8,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[1].rows[0] = .{
        .row_id = 2,
        .content_hash = 2,
        .text = try alloc.dupe(u8, "right"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 24, .mock_height = 6 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expectEqual(@as(?u16, 4), surface.cursor_col);
    try std.testing.expectEqual(@as(?u16, 1), surface.cursor_row);
    try std.testing.expectEqual(@as(?surface_mod.CursorShape, .beam), surface.cursor_shape);
}

test "semantic state switches cursor owner on accepted overlay delta" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 2);
    state.cursor_window_id = 7;
    state.windows[0] = .{
        .window_id = 7,
        .flags = 0x01,
        .content_epoch = 1,
        .cursor_row = 0,
        .cursor_col = 2,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "left"),
        .spans = &.{},
    };
    state.windows[1] = .{
        .window_id = 9,
        .flags = 0x01,
        .content_epoch = 1,
        .cursor_row = 0,
        .cursor_col = 0,
        .origin_row = 3,
        .origin_col = 12,
        .text_width = 8,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[1].rows[0] = .{
        .row_id = 2,
        .content_hash = 2,
        .text = try alloc.dupe(u8, "right"),
        .spans = &.{},
    };

    try state.applyWindowOverlayDeltaPacket(&[_]u8{ protocol.OP_GUI_WINDOW_OVERLAY_DELTA, 0, 9, 0, 0, 0, 1, 0, 0, 0, 0, 5, 0 });
    try std.testing.expectEqual(@as(?u16, 9), state.cursor_window_id);
}

test "decodeWindowRowsDelta retains ref and full row entries" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_ROWS_DELTA, 3,
            0x01,                              0,
            14,                                0,
            7,                                 0,
            0,                                 0,
            9,                                 0x01,
            0,                                 3,
            0,                                 4,
            2,                                 0,
            1,                                 0x02,
            0,                                 42,
            0,                                 2,
            0,                                 0,
            0,                                 0,
            0,                                 0,
            0,                                 0,
            1,                                 0x01,
            0x02,                              0x03,
            0x04,                              1,
            0,                                 0,
            0,                                 0,
            0,                                 0,
            0,                                 0,
            2,                                 0,
            0,                                 0,
            43,                                0x05,
            0x06,                              0x07,
            0x08,                              0,
            0,                                 0,
            3,                                 'b',
            'y',                               'e',
            0,                                 0,
            0x09,                              0,
            5,                                 0,
            1,                                 0x12,
            0x34,                              0x56,
        };

    var delta = try decodeWindowRowsDelta(alloc, packet);
    defer delta.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 7), delta.window_id);
    try std.testing.expectEqual(@as(u32, 9), delta.content_epoch);
    try std.testing.expectEqual(@as(u16, 1), delta.scroll_left);
    try std.testing.expectEqual(@as(usize, 2), delta.rows.len);
    try std.testing.expect(delta.rows[0].ref);
    try std.testing.expectEqual(@as(u64, 1), delta.rows[0].row_id);
    try std.testing.expectEqual(@as(u32, 0x01020304), delta.rows[0].content_hash);
    try std.testing.expect(!delta.rows[1].ref);
    try std.testing.expectEqual(@as(u64, 2), delta.rows[1].row_id);
    try std.testing.expectEqualStrings("bye", delta.rows[1].text);
    try std.testing.expect(delta.cursorline_visible);
    try std.testing.expectEqual(@as(u16, 1), delta.cursorline_row);
    try std.testing.expectEqual(@as(u24, 0x123456), delta.cursorline_bg);
}

test "semantic state applies retained window rows delta refs" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_VIEWPORT_DELTA, 3,
            0x01,                                  0,
            14,                                    0,
            7,                                     0,
            0,                                     0,
            9,                                     0x01,
            0,                                     3,
            0,                                     4,
            2,                                     0,
            1,                                     0x02,
            0,                                     42,
            0,                                     2,
            0,                                     0,
            0,                                     0,
            0,                                     0,
            0,                                     0,
            1,                                     0x01,
            0x02,                                  0x03,
            0x04,                                  1,
            0,                                     0,
            0,                                     0,
            0,                                     0,
            0,                                     0,
            2,                                     0,
            0,                                     0,
            43,                                    0x05,
            0x06,                                  0x07,
            0x08,                                  0,
            0,                                     0,
            3,                                     'b',
            'y',                                   'e',
            0,                                     0,
            0x09,                                  0,
            5,                                     0,
            1,                                     0x12,
            0x34,                                  0x56,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .content_epoch = 9,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 0x01020304,
        .text = try alloc.dupe(u8, "old"),
        .spans = &.{},
    };

    try state.applyWindowRowsDeltaPacket(packet);

    try std.testing.expectEqual(@as(usize, 2), state.windows[0].rows.len);
    try std.testing.expectEqualStrings("old", state.windows[0].rows[0].text);
    try std.testing.expectEqualStrings("bye", state.windows[0].rows[1].text);
    try std.testing.expectEqual(@as(u16, 3), state.windows[0].cursor_row);
    try std.testing.expectEqual(@as(u16, 1), state.windows[0].scroll_left);
    try std.testing.expect(state.windows[0].cursorline_visible);
    try std.testing.expectEqual(@as(u16, 1), state.windows[0].cursorline_row);
    try std.testing.expectEqual(@as(u24, 0x123456), state.windows[0].cursorline_bg);
}

test "semantic state applies retained window geometry delta" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_VIEWPORT_DELTA, 2,
            0x01,                                  0,
            14,                                    0,
            7,                                     0,
            0,                                     0,
            9,                                     0,
            0,                                     1,
            0,                                     2,
            1,                                     0,
            0,                                     0x08,
            0,                                     26,
            0,                                     7,
            0,                                     0,
            0,                                     0,
            0,                                     20,
            0,                                     5,
            0,                                     0,
            0,                                     0,
            0,                                     20,
            0,                                     5,
            0,                                     2,
            0,                                     5,
            0,                                     10,
            0,                                     3,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .content_epoch = 9,
        .origin_row = 9,
        .origin_col = 9,
        .text_width = 1,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "old"),
        .spans = &.{},
    };

    try state.applyWindowRowsDeltaPacket(packet);

    try std.testing.expectEqual(@as(u16, 2), state.windows[0].origin_row);
    try std.testing.expectEqual(@as(u16, 5), state.windows[0].origin_col);
    try std.testing.expectEqual(@as(u16, 10), state.windows[0].text_width);
    try std.testing.expectEqual(@as(u16, 3), state.windows[0].text_height);
    try std.testing.expectEqual(@as(?u16, 7), state.cursor_window_id);
}

test "decodeWindowOverlayDelta retains cursor and cursorline" {
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_OVERLAY_DELTA,
            0,
            7,
            0,
            0,
            0,
            9,
            0x03,
            0,
            3,
            0,
            4,
            2,
            0,
            1,
            0x12,
            0x34,
            0x56,
        };

    const delta = try decodeWindowOverlayDelta(packet);

    try std.testing.expectEqual(@as(u16, 7), delta.window_id);
    try std.testing.expectEqual(@as(u32, 9), delta.content_epoch);
    try std.testing.expectEqual(@as(u16, 3), delta.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), delta.cursor_col);
    try std.testing.expectEqual(@as(u8, 2), delta.cursor_shape);
    try std.testing.expect(delta.cursorline_visible);
    try std.testing.expectEqual(@as(u16, 1), delta.cursorline_row);
    try std.testing.expectEqual(@as(u24, 0x123456), delta.cursorline_bg);
}

test "semantic state applies retained window overlay delta" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_OVERLAY_DELTA,
            0,
            7,
            0,
            0,
            0,
            9,
            0x03,
            0,
            0,
            0,
            4,
            2,
            0,
            0,
            0x12,
            0x34,
            0x56,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .content_epoch = 9,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 10,
        .text_height = 1,
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "old"),
        .spans = &.{},
    };

    try state.applyWindowOverlayDeltaPacket(packet);

    try std.testing.expectEqual(@as(u16, 4), state.windows[0].cursor_col);
    try std.testing.expect(state.windows[0].cursorline_visible);
    try std.testing.expectEqual(@as(u24, 0x123456), state.windows[0].cursorline_bg);

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 2 and std.mem.eql(u8, cell.text, "o")) {
            try std.testing.expectEqual(@as(u24, 0x123456), cell.bg);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "decode retained window overlay sections" {
    const alloc = std.testing.allocator;

    const selection = decodeWindowSelection(&[_]u8{ 1, 0, 2, 0, 3, 0, 2, 0, 8 });
    const matches = try decodeSearchMatches(alloc, &[_]u8{ 0, 1, 0, 2, 0, 3, 0, 8, 1 });
    defer alloc.free(matches);
    const diagnostics = try decodeDiagnosticRanges(alloc, &[_]u8{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 2 });
    defer alloc.free(diagnostics);
    const highlights = try decodeDocumentHighlights(alloc, &[_]u8{ 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 1 });
    defer alloc.free(highlights);
    const annotations = try decodeLineAnnotations(alloc, &[_]u8{ 0, 1, 0, 2, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0, 4, 'n', 'o', 't', 'e' });
    defer {
        for (annotations) |*annotation| annotation.deinit(alloc);
        alloc.free(annotations);
    }

    try std.testing.expectEqual(@as(u8, 1), selection.selection_type);
    try std.testing.expectEqual(@as(u16, 2), selection.start_row);
    try std.testing.expectEqual(@as(u16, 8), selection.end_col);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expect(matches[0].current);
    try std.testing.expectEqual(@as(u8, 2), diagnostics[0].severity);
    try std.testing.expectEqual(@as(u8, 1), highlights[0].kind);
    try std.testing.expectEqual(@as(u24, 0x112233), annotations[0].fg);
    try std.testing.expectEqual(@as(u24, 0x445566), annotations[0].bg);
    try std.testing.expectEqualStrings("note", annotations[0].text);
}

test "retained window rows delta transfers overlay sections" {
    const alloc = std.testing.allocator;

    var window = WindowContent{
        .selection = .{ .selection_type = 1, .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1 },
        .search_matches = try alloc.alloc(SearchMatch, 1),
        .diagnostic_ranges = try alloc.alloc(DiagnosticRange, 1),
        .document_highlights = try alloc.alloc(DocumentHighlight, 1),
        .annotations = try alloc.alloc(LineAnnotation, 1),
    };
    defer window.deinit(alloc);
    window.search_matches[0] = .{ .row = 0, .start_col = 0, .end_col = 1 };
    window.diagnostic_ranges[0] = .{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1 };
    window.document_highlights[0] = .{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1 };
    window.annotations[0] = .{ .row = 0, .text = try alloc.dupe(u8, "old") };

    var delta = WindowRowsDelta{
        .selection = .{ .selection_type = 2, .start_row = 1, .start_col = 2, .end_row = 1, .end_col = 4 },
        .search_matches = try alloc.alloc(SearchMatch, 1),
        .diagnostic_ranges = try alloc.alloc(DiagnosticRange, 1),
        .document_highlights = try alloc.alloc(DocumentHighlight, 1),
        .annotations = try alloc.alloc(LineAnnotation, 1),
    };
    defer delta.deinit(alloc);
    delta.search_matches.?[0] = .{ .row = 1, .start_col = 2, .end_col = 4, .current = true };
    delta.diagnostic_ranges.?[0] = .{ .start_row = 1, .start_col = 3, .end_row = 1, .end_col = 4, .severity = 2 };
    delta.document_highlights.?[0] = .{ .start_row = 1, .start_col = 2, .end_row = 1, .end_col = 3, .kind = 1 };
    delta.annotations.?[0] = .{ .row = 1, .fg = 0x112233, .text = try alloc.dupe(u8, "new") };

    applyWindowOverlaySections(alloc, &window, &delta);

    try std.testing.expectEqual(@as(u8, 2), window.selection.selection_type);
    try std.testing.expectEqual(@as(u16, 1), window.search_matches[0].row);
    try std.testing.expect(window.search_matches[0].current);
    try std.testing.expectEqual(@as(u8, 2), window.diagnostic_ranges[0].severity);
    try std.testing.expectEqual(@as(u8, 1), window.document_highlights[0].kind);
    try std.testing.expectEqualStrings("new", window.annotations[0].text);
    try std.testing.expect(delta.search_matches == null);
    try std.testing.expect(delta.diagnostic_ranges == null);
    try std.testing.expect(delta.document_highlights == null);
    try std.testing.expect(delta.annotations == null);
}

test "semantic state renders retained window overlays and annotations" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 20,
        .text_height = 1,
        .selection = .{ .selection_type = 1, .start_row = 0, .start_col = 1, .end_row = 0, .end_col = 3 },
        .search_matches = try alloc.alloc(SearchMatch, 1),
        .diagnostic_ranges = try alloc.alloc(DiagnosticRange, 1),
        .document_highlights = try alloc.alloc(DocumentHighlight, 1),
        .annotations = try alloc.alloc(LineAnnotation, 3),
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].search_matches[0] = .{ .row = 0, .start_col = 2, .end_col = 4, .current = true };
    state.windows[0].diagnostic_ranges[0] = .{ .start_row = 0, .start_col = 3, .end_row = 0, .end_col = 4, .severity = 2 };
    state.windows[0].document_highlights[0] = .{ .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1, .kind = 2 };
    state.windows[0].annotations[0] = .{ .row = 0, .kind = 1, .fg = 0x112233, .text = try alloc.dupe(u8, "note") };
    state.windows[0].annotations[1] = .{ .row = 0, .kind = 1, .text = try alloc.dupe(u8, "fallback") };
    state.windows[0].annotations[2] = .{ .row = 0, .kind = 2, .text = try alloc.dupe(u8, "skip") };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "abcd"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 30, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_highlight = false;
    var saw_selection = false;
    var saw_search = false;
    var saw_diagnostic = false;
    var saw_annotation = false;
    var saw_fallback_annotation = false;
    var saw_skipped_annotation = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 2 and std.mem.eql(u8, cell.text, "a") and cell.bg == default_document_highlight_read_bg) saw_highlight = true;
        if (cell.row == 1 and cell.col == 3 and std.mem.eql(u8, cell.text, "b") and cell.bg == default_selection_bg) saw_selection = true;
        if (cell.row == 1 and cell.col == 4 and std.mem.eql(u8, cell.text, "c") and cell.bg == default_current_search_match_bg) saw_search = true;
        if (cell.row == 1 and cell.col == 5 and std.mem.eql(u8, cell.text, "d") and cell.fg == default_diagnostic_info_fg and cell.attrs & protocol.ATTR_UNDERLINE != 0) saw_diagnostic = true;
        if (cell.row == 1 and cell.col == 7 and std.mem.eql(u8, cell.text, "n") and cell.fg == 0x112233) saw_annotation = true;
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "f") and cell.fg == default_accent_fg and cell.bg == default_editor_bg) saw_fallback_annotation = true;
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "s")) saw_skipped_annotation = true;
    }

    try std.testing.expect(saw_highlight);
    try std.testing.expect(saw_selection);
    try std.testing.expect(saw_search);
    try std.testing.expect(saw_diagnostic);
    try std.testing.expect(saw_annotation);
    try std.testing.expect(saw_fallback_annotation);
    try std.testing.expect(!saw_skipped_annotation);
}

test "semantic state renders retained window overlays with theme colors" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_selection_bg, .rgb = 0x010203 },
            .{ .id = theme_highlight_write_bg, .rgb = 0x111213 },
            .{ .id = theme_tree_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_gutter_warning_fg, .rgb = 0x313233 },
        }),
    };
    state.windows = try alloc.alloc(WindowContent, 1);
    state.windows[0] = .{
        .window_id = 7,
        .origin_row = 1,
        .origin_col = 2,
        .text_width = 12,
        .text_height = 1,
        .selection = .{ .selection_type = 1, .start_row = 0, .start_col = 0, .end_row = 0, .end_col = 1 },
        .search_matches = try alloc.alloc(SearchMatch, 1),
        .diagnostic_ranges = try alloc.alloc(DiagnosticRange, 1),
        .document_highlights = try alloc.alloc(DocumentHighlight, 1),
        .rows = try alloc.alloc(WindowRow, 1),
    };
    state.windows[0].search_matches[0] = .{ .row = 0, .start_col = 2, .end_col = 3, .current = true };
    state.windows[0].diagnostic_ranges[0] = .{ .start_row = 0, .start_col = 3, .end_row = 0, .end_col = 4, .severity = 1 };
    state.windows[0].document_highlights[0] = .{ .start_row = 0, .start_col = 1, .end_row = 0, .end_col = 2, .kind = 3 };
    state.windows[0].rows[0] = .{
        .row_id = 1,
        .content_hash = 1,
        .text = try alloc.dupe(u8, "abcd"),
        .spans = &.{},
    };

    var surface = MockSurface{ .mock_width = 30, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_selection = false;
    var saw_highlight = false;
    var saw_search = false;
    var saw_diagnostic = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 2 and std.mem.eql(u8, cell.text, "a") and cell.bg == 0x010203) saw_selection = true;
        if (cell.row == 1 and cell.col == 3 and std.mem.eql(u8, cell.text, "b") and cell.bg == 0x111213) saw_highlight = true;
        if (cell.row == 1 and cell.col == 4 and std.mem.eql(u8, cell.text, "c") and cell.bg == 0x212223) saw_search = true;
        if (cell.row == 1 and cell.col == 5 and std.mem.eql(u8, cell.text, "d") and cell.fg == 0x313233 and cell.attrs & protocol.ATTR_UNDERLINE != 0) saw_diagnostic = true;
    }

    try std.testing.expect(saw_selection);
    try std.testing.expect(saw_highlight);
    try std.testing.expect(saw_search);
    try std.testing.expect(saw_diagnostic);
}

test "decodeSplitSeparators retains vertical and horizontal separators" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SPLIT_SEPARATORS, 0x11,
            0x22,                             0x33,
            1,                                0,
            4,                                0,
            1,                                0,
            3,                                1,
            0,                                2,
            0,                                0,
            0,                                12,
            0,                                7,
            'm',                              'a',
            'i',                              'n',
            '.',                              'e',
            'x',
        };

    var separators = try decodeSplitSeparators(alloc, packet);
    defer separators.deinit(alloc);

    try std.testing.expectEqual(@as(u24, 0x112233), separators.color);
    try std.testing.expectEqual(@as(usize, 1), separators.verticals.len);
    try std.testing.expectEqual(@as(u16, 4), separators.verticals[0].col);
    try std.testing.expectEqual(@as(u16, 1), separators.verticals[0].start_row);
    try std.testing.expectEqual(@as(u16, 3), separators.verticals[0].end_row);
    try std.testing.expectEqual(@as(usize, 1), separators.horizontals.len);
    try std.testing.expectEqual(@as(u16, 2), separators.horizontals[0].row);
    try std.testing.expectEqual(@as(u16, 0), separators.horizontals[0].col);
    try std.testing.expectEqual(@as(u16, 12), separators.horizontals[0].width);
    try std.testing.expectEqualStrings("main.ex", separators.horizontals[0].filename);
}

test "semantic state renders retained split separators" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_SPLIT_SEPARATORS, 0x11,
            0x22,                             0x33,
            1,                                0,
            4,                                0,
            1,                                0,
            3,                                1,
            0,                                2,
            0,                                0,
            0,                                12,
            0,                                7,
            'm',                              'a',
            'i',                              'n',
            '.',                              'e',
            'x',
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
        }),
    };
    try state.applySplitSeparatorsPacket(packet);

    var surface = MockSurface{ .mock_width = 20, .mock_height = 5 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 1, "│", null);
    try expectMockCell(&surface, 2, "─", null);
    try expectMockCell(&surface, 2, "m", null);
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and std.mem.eql(u8, cell.text, "│")) {
            try std.testing.expectEqual(@as(u16, 4), cell.col);
            try std.testing.expectEqual(@as(u24, 0x112233), cell.fg);
            try std.testing.expectEqual(@as(u24, 0x010203), cell.bg);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "decodeStatusBar retains modeline segments" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_STATUS_BAR, 3,
            0x01,                       0x00,
            0x03,                       0x00,
            0x00,                       0x07,
            0x02,                       0x00,
            0x0C,                       0,
            0,                          0,
            12,                         0,
            0,                          0,
            4,                          0,
            0,                          0,
            30,                         0x0B,
            0x00,                       0x2E,
            2,                          0,
            1,                          0,
            1,                          4,
            'm',                        'o',
            'd',                        'e',
            0xFF,                       0xFF,
            0xFF,                       0,
            0,                          0,
            0x01,                       0,
            6,                          'N',
            'O',                        'R',
            'M',                        'A',
            'L',                        0,
            0,                          3,
            'p',                        'o',
            's',                        0xAA,
            0xBB,                       0xCC,
            0,                          0,
            0,                          0,
            0,                          4,
            '1',                        ':',
            '1',                        '2',
            0,                          0,
        };

    var status = try decodeStatusBar(alloc, packet);
    defer status.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0), status.mode);
    try std.testing.expectEqual(@as(u8, 0x07), status.flags);
    try std.testing.expectEqual(@as(u32, 12), status.line);
    try std.testing.expectEqual(@as(u32, 4), status.col);
    try std.testing.expectEqual(@as(usize, 1), status.left_segments.len);
    try std.testing.expectEqualStrings("NORMAL", status.left_segments[0].text);
    try std.testing.expectEqual(@as(u24, 0xFFFFFF), status.left_segments[0].fg);
    try std.testing.expectEqual(@as(usize, 1), status.right_segments.len);
    try std.testing.expectEqualStrings("1:12", status.right_segments[0].text);
}

test "decodeStatusBar retains identity cursor and file metadata" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_STATUS_BAR, 3,
            0x01,                       0,
            3,                          5,
            6,                          7,
            0x02,                       0,
            12,                         0,
            0,                          0,
            9,                          0,
            0,                          0,
            3,                          0,
            0,                          0,
            20,                         0x06,
            0,                          17,
            1,                          'E',
            0xAA,                       0xBB,
            0xCC,                       0,
            7,                          'm',
            'a',                        'i',
            'n',                        '.',
            'e',                        'x',
            2,                          'e',
            'x',
        };

    var status = try decodeStatusBar(alloc, packet);
    defer status.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 5), status.content_kind);
    try std.testing.expectEqual(@as(u8, 6), status.mode);
    try std.testing.expectEqual(@as(u8, 7), status.flags);
    try std.testing.expectEqual(@as(u32, 9), status.line);
    try std.testing.expectEqual(@as(u32, 3), status.col);
    try std.testing.expectEqual(@as(u32, 20), status.line_count);
    try std.testing.expectEqualStrings("E", status.icon);
    try std.testing.expectEqualStrings("main.ex", status.filename);
    try std.testing.expectEqualStrings("ex", status.filetype);
}

test "semantic state renders retained status bar" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_STATUS_BAR, 1,
            0x0B,                       0x00,
            0x2E,                       2,
            0,                          1,
            0,                          1,
            4,                          'm',
            'o',                        'd',
            'e',                        0xFF,
            0xFF,                       0xFF,
            0,                          0,
            0,                          0x01,
            0,                          6,
            'N',                        'O',
            'R',                        'M',
            'A',                        'L',
            0,                          0,
            3,                          'p',
            'o',                        's',
            0xAA,                       0xBB,
            0xCC,                       0,
            0,                          0,
            0,                          0,
            4,                          '1',
            ':',                        '1',
            '2',                        0,
            0,
        };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyStatusBarPacket(packet);

    var surface = MockSurface{};
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    for (surface.cells.items) |cell| {
        if (cell.row == 2 and std.mem.eql(u8, cell.text, "N")) {
            try std.testing.expectEqual(@as(u24, 0xFFFFFF), cell.fg);
            return;
        }
    }
    return error.TestExpectedEqual;
}

test "semantic state renders retained status bar with theme colors" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_modeline_bar_bg, .rgb = 0x010203 },
            .{ .id = theme_modeline_bar_fg, .rgb = 0x111213 },
        }),
    };
    state.status_bar = .{
        .filename = try alloc.dupe(u8, "main.ex"),
        .message = try alloc.dupe(u8, "ok"),
        .line = 3,
        .col = 4,
    };
    state.search_state = .{
        .active = true,
        .match_count = 2,
        .current_index = 1,
    };

    var surface = MockSurface{ .mock_width = 40, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_filename = false;
    var saw_footer = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 2 and std.mem.eql(u8, cell.text, "m") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_filename = true;
        if (cell.row == 2 and std.mem.eql(u8, cell.text, "s") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_footer = true;
        if (cell.row == 2 and cell.col == 39 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_filename);
    try std.testing.expect(saw_footer);
    try std.testing.expect(saw_background);
}

test "decodeSearchState retains footer state" {
    const packet = &[_]u8{
        protocol.OP_GUI_SEARCH_STATE,
        0,
        6,
        1,
        0,
        5,
        0,
        3,
        0x0F,
    };

    const state = try decodeSearchState(packet);

    try std.testing.expect(state.active);
    try std.testing.expectEqual(@as(u16, 5), state.match_count);
    try std.testing.expectEqual(@as(u16, 3), state.current_index);
    try std.testing.expectEqual(@as(u8, 0x0F), state.flags);
}

test "decodeChangeSummary retains entries" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_CHANGE_SUMMARY,
        1,
        0,
        0,
        0,
        1,
        0,
        8,
        'l',
        'i',
        'b',
        '/',
        'a',
        '.',
        'e',
        'x',
        1,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        2,
    };

    var summary = try decodeChangeSummary(alloc, packet);
    defer summary.deinit(alloc);

    try std.testing.expect(summary.visible);
    try std.testing.expectEqual(@as(u16, 0), summary.selected_index);
    try std.testing.expectEqual(@as(usize, 1), summary.entries.len);
    try std.testing.expectEqualStrings("lib/a.ex", summary.entries[0].path);
    try std.testing.expectEqual(@as(u8, 1), summary.entries[0].action);
    try std.testing.expectEqual(@as(u32, 4), summary.entries[0].lines_added);
    try std.testing.expectEqual(@as(u32, 2), summary.entries[0].lines_removed);
}

test "semantic state renders change summary as footer indicator" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_CHANGE_SUMMARY,
        1,
        0,
        0,
        0,
        1,
        0,
        8,
        'l',
        'i',
        'b',
        '/',
        'a',
        '.',
        'e',
        'x',
        1,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        2,
    };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_selection_bg, .rgb = 0x212223 },
            .{ .id = theme_popup_selection_fg, .rgb = 0x313233 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x414243 },
            .{ .id = theme_accent, .rgb = 0x515253 },
        }),
    };
    try state.applyChangeSummaryPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 6 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_popup_title = false;
    var saw_footer_indicator = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 0 and std.mem.eql(u8, cell.text, "C")) saw_popup_title = true;
        if (cell.row == 5 and std.mem.eql(u8, cell.text, "c")) saw_footer_indicator = true;
    }

    try std.testing.expect(!saw_popup_title);
    try std.testing.expect(saw_footer_indicator);
}

test "decodeNotifications retains footer notification state" {
    const alloc = std.testing.allocator;
    var packet = notificationPacketForTest();

    var notifications = try decodeNotifications(alloc, &packet);
    defer notifications.deinit(alloc);

    try std.testing.expect(notifications.visible);
    try std.testing.expectEqual(@as(u16, 1), notifications.notification_count);
    try std.testing.expectEqual(@as(usize, 1), notifications.items.len);
    try std.testing.expectEqualStrings("n1", notifications.items[0].id);
    try std.testing.expectEqual(@as(u8, 2), notifications.items[0].level);
    try std.testing.expect(notifications.items[0].dismissable);
    try std.testing.expectEqual(@as(u64, 42), notifications.items[0].created_at);
    try std.testing.expectEqual(@as(u64, 99), notifications.items[0].updated_at);
    try std.testing.expectEqual(@as(u32, 5000), notifications.items[0].auto_dismiss_ms);
    try std.testing.expectEqualStrings("Build", notifications.items[0].title);
    try std.testing.expectEqualStrings("Done", notifications.items[0].body);
    try std.testing.expectEqualStrings("mix", notifications.items[0].source);
    try std.testing.expectEqual(@as(usize, 1), notifications.items[0].actions.len);
    try std.testing.expectEqualStrings("open", notifications.items[0].actions[0].id);
    try std.testing.expectEqualStrings("Open", notifications.items[0].actions[0].label);
}

test "semantic state renders notifications with popup theme" {
    const alloc = std.testing.allocator;
    var packet = notificationPacketForTest();

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_popup_selection_bg, .rgb = 0x414243 },
            .{ .id = theme_popup_selection_fg, .rgb = 0x515253 },
            .{ .id = theme_accent, .rgb = 0x313233 },
        }),
    };
    try state.applyNotificationsPacket(&packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_notification = false;
    var saw_source = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 2 and cell.col == 11 and std.mem.eql(u8, cell.text, "N") and cell.fg == 0x313233 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 3 and cell.col == 12 and std.mem.eql(u8, cell.text, "B") and cell.fg == 0x515253 and cell.bg == 0x414243 and cell.attrs == protocol.ATTR_BOLD) saw_notification = true;
        if (cell.row == 4 and cell.col == 12 and std.mem.eql(u8, cell.text, "m") and cell.fg == 0x515253 and cell.bg == 0x414243) saw_source = true;
        if (cell.row == 2 and cell.col == 69 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_notification);
    try std.testing.expect(saw_source);
    try std.testing.expect(saw_background);
}

test "decodeEditTimeline retains footer edit state" {
    const alloc = std.testing.allocator;
    const packet =
        &[_]u8{
            protocol.OP_GUI_EDIT_TIMELINE, 0,   15,
            1,                             0,   0,
            1,                             3,   5,
            'a',                           'p', 'p',
            'l',                           'y', 0,
            0,                             0,   4,
        };

    var timeline = try decodeEditTimeline(alloc, packet);
    defer timeline.deinit(alloc);

    try std.testing.expect(timeline.visible);
    try std.testing.expectEqual(@as(u16, 0), timeline.viewing_index);
    try std.testing.expectEqual(@as(u8, 1), timeline.entry_count);
    try std.testing.expectEqual(@as(usize, 1), timeline.entries.len);
    try std.testing.expectEqual(@as(u8, 3), timeline.entries[0].index);
    try std.testing.expectEqualStrings("apply", timeline.entries[0].tool_name);
    try std.testing.expectEqual(@as(u32, 4), timeline.entries[0].timestamp_delta);
}

test "decode extension and observatory footer summaries" {
    const alloc = std.testing.allocator;
    const overlay_packet = &[_]u8{ protocol.OP_GUI_EXTENSION_OVERLAY, 0, 1, 2 };
    const panel_packet = &[_]u8{ protocol.OP_GUI_EXTENSION_PANEL, 0, 1, 3 };
    const observatory_packet = &[_]u8{
        protocol.OP_GUI_OBSERVATORY,
        0,
        0,
        0,
        6,
        0x01,
        0,
        3,
        1,
        0,
        4,
    };

    var overlay = try decodeExtensionOverlay(alloc, overlay_packet);
    defer overlay.deinit(alloc);
    var panel = try decodeExtensionPanel(alloc, panel_packet);
    defer panel.deinit(alloc);
    var observatory = try decodeObservatory(alloc, observatory_packet);
    defer observatory.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 2), overlay.entry_count);
    try std.testing.expectEqual(@as(u8, 3), panel.panel_count);
    try std.testing.expect(observatory.visible);
    try std.testing.expectEqual(@as(u16, 4), observatory.count);
}

test "decodeExtensionPanel retains visible panel blocks" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_EXTENSION_PANEL,
        0,
        38,
        1,
        3,
        'l',
        's',
        'p',
        2,
        'p',
        '1',
        4,
        'D',
        'i',
        'a',
        'g',
        1,
        0,
        35,
        1,
        2,
        0,
        0,
        5,
        'R',
        'e',
        'a',
        'd',
        'y',
        3,
        1,
        0,
        5,
        'f',
        'i',
        'l',
        'e',
        's',
        0,
        1,
        '3',
    };

    var panel = try decodeExtensionPanel(alloc, packet);
    defer panel.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 1), panel.panel_count);
    try std.testing.expectEqual(@as(usize, 1), panel.panels.len);
    try std.testing.expectEqualStrings("lsp", panel.panels[0].extension);
    try std.testing.expectEqualStrings("p1", panel.panels[0].id);
    try std.testing.expectEqualStrings("Diag", panel.panels[0].title);
    try std.testing.expect(panel.panels[0].visible);
    try std.testing.expectEqual(@as(u8, 1), panel.panels[0].position);
    try std.testing.expectEqual(@as(u8, 0), panel.panels[0].size_type);
    try std.testing.expectEqual(@as(u8, 35), panel.panels[0].size_value);
    try std.testing.expectEqual(@as(usize, 2), panel.panels[0].blocks.len);
    try std.testing.expectEqualStrings("Ready", panel.panels[0].blocks[0]);
    try std.testing.expectEqualStrings("files: 3", panel.panels[0].blocks[1]);
}

test "decodeExtensionOverlay retains overlay entries" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_EXTENSION_OVERLAY,
        0,
        25,
        1,
        3,
        'l',
        's',
        'p',
        2,
        'o',
        '1',
        0,
        7,
        0,
        2,
        0,
        4,
        2,
        0x11,
        0x22,
        0x33,
        9,
        0,
        4,
        'h',
        'i',
        'n',
        't',
    };

    var overlay = try decodeExtensionOverlay(alloc, packet);
    defer overlay.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 1), overlay.entry_count);
    try std.testing.expectEqual(@as(usize, 1), overlay.entries.len);
    try std.testing.expectEqualStrings("lsp", overlay.entries[0].extension);
    try std.testing.expectEqualStrings("o1", overlay.entries[0].id);
    try std.testing.expectEqual(@as(u16, 7), overlay.entries[0].window_id);
    try std.testing.expectEqual(@as(u16, 2), overlay.entries[0].row);
    try std.testing.expectEqual(@as(u16, 4), overlay.entries[0].col);
    try std.testing.expectEqual(@as(u8, 2), overlay.entries[0].shape);
    try std.testing.expectEqual(@as(u24, 0x112233), overlay.entries[0].fg);
    try std.testing.expectEqual(@as(u8, 9), overlay.entries[0].opacity);
    try std.testing.expectEqualStrings("hint", overlay.entries[0].content);
}

test "decodeObservatory retains process rows" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_OBSERVATORY,
        0,
        0,
        0,
        37,
        0x01,
        0,
        3,
        1,
        0,
        1,
        0x02,
        0,
        28,
        5,
        '<',
        '0',
        '.',
        '1',
        '>',
        0,
        0,
        7,
        'B',
        'u',
        'f',
        'f',
        'e',
        'r',
        's',
        1,
        1,
        0,
        0,
        1,
        0x20,
        0,
        7,
        0,
        0,
        0,
        42,
    };

    var observatory = try decodeObservatory(alloc, packet);
    defer observatory.deinit(alloc);

    try std.testing.expect(observatory.visible);
    try std.testing.expectEqual(@as(u16, 1), observatory.count);
    try std.testing.expectEqual(@as(usize, 1), observatory.nodes.len);
    try std.testing.expectEqualStrings("<0.1>", observatory.nodes[0].pid);
    try std.testing.expectEqualStrings("Buffers", observatory.nodes[0].name);
    try std.testing.expectEqual(@as(u8, 1), observatory.nodes[0].process_class);
    try std.testing.expectEqual(@as(u8, 1), observatory.nodes[0].depth);
    try std.testing.expectEqual(@as(u32, 0x120), observatory.nodes[0].memory);
    try std.testing.expectEqual(@as(u16, 7), observatory.nodes[0].message_queue_len);
    try std.testing.expectEqual(@as(u32, 42), observatory.nodes[0].reductions);
}

test "decodeAgentContext retains footer task state" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CONTEXT,
        1,
        0,
        6,
        'R',
        'e',
        'v',
        'i',
        'e',
        'w',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        42,
        1,
        1,
    };

    var context = try decodeAgentContext(alloc, packet);
    defer context.deinit(alloc);

    try std.testing.expect(context.visible);
    try std.testing.expectEqualStrings("Review", context.task);
    try std.testing.expectEqual(@as(u64, 42), context.timestamp);
    try std.testing.expectEqual(@as(u8, 1), context.status);
    try std.testing.expect(context.can_approve);
}

test "semantic state renders agent context like Go list items" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CONTEXT,
        1,
        0,
        6,
        'R',
        'e',
        'v',
        'i',
        'e',
        'w',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        42,
        1,
        1,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyAgentContextPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 1, "A", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 2, "w", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 3, "R", null);
    try expectMockCell(&surface, 4, "a", null);
    try expectMockCell(&surface, 5, "r", null);
}

test "decodeToolManager retains tool summaries" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_TOOL_MANAGER,
        1,
        0,
        0,
        0,
        0,
        1,
        4,
        'r',
        'e',
        'a',
        'd',
        4,
        'R',
        'e',
        'a',
        'd',
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };

    var manager = try decodeToolManager(alloc, packet);
    defer manager.deinit(alloc);

    try std.testing.expect(manager.visible);
    try std.testing.expectEqual(@as(u16, 0), manager.selected);
    try std.testing.expectEqual(@as(usize, 1), manager.tools.len);
    try std.testing.expectEqualStrings("read", manager.tools[0].name);
    try std.testing.expectEqualStrings("Read", manager.tools[0].label);
    try std.testing.expectEqual(@as(u8, 2), manager.tools[0].status);
}

test "semantic state renders tool manager with selected popup row" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_TOOL_MANAGER,
        1,
        0,
        0,
        0,
        0,
        1,
        4,
        'r',
        'e',
        'a',
        'd',
        4,
        'R',
        'e',
        'a',
        'd',
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_selection_bg, .rgb = 0x111213 },
            .{ .id = theme_popup_selection_fg, .rgb = 0x212223 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x313233 },
            .{ .id = theme_accent, .rgb = 0x414243 },
        }),
    };
    try state.applyToolManagerPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_selected_label = false;
    var saw_selected_detail = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 2 and cell.col == 11 and std.mem.eql(u8, cell.text, "T") and cell.fg == 0x414243 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 3 and cell.col == 12 and std.mem.eql(u8, cell.text, "R") and cell.fg == 0x212223 and cell.bg == 0x111213 and cell.attrs == protocol.ATTR_BOLD) saw_selected_label = true;
        if (cell.row == 4 and cell.col == 12 and std.mem.eql(u8, cell.text, "r") and cell.fg == 0x212223 and cell.bg == 0x111213) saw_selected_detail = true;
        if (cell.row == 2 and cell.col == 69 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_selected_label);
    try std.testing.expect(saw_selected_detail);
    try std.testing.expect(saw_background);
}

test "semantic state renders empty visible tool manager like Go" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.tool_manager = .{ .visible = true };

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_empty_title = false;
    var saw_empty_description = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 2 and cell.col == 11 and std.mem.eql(u8, cell.text, "T")) saw_title = true;
        if (cell.row == 3 and cell.col == 12 and std.mem.eql(u8, cell.text, "N")) saw_empty_title = true;
        if (cell.row == 4 and cell.col == 12 and std.mem.eql(u8, cell.text, "N")) saw_empty_description = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_empty_title);
    try std.testing.expect(saw_empty_description);
}

test "decode small retained semantic state packets" {
    const alloc = std.testing.allocator;

    const cursorline = try decodeCursorline(&[_]u8{ protocol.OP_GUI_CURSORLINE, 0, 2, 0x11, 0x22, 0x33 });
    const separator = try decodeGutterSeparator(&[_]u8{ protocol.OP_GUI_GUTTER_SEP, 0, 7, 0x44, 0x55, 0x66 });
    const spacing = try decodeLineSpacing(&[_]u8{ protocol.OP_GUI_LINE_SPACING, 0, 2, 0, 120 });
    const animation = try decodeCursorAnimation(&[_]u8{ protocol.OP_GUI_CURSOR_ANIMATION, 0, 1, 0 });
    var config = try decodeConfigState(alloc, &[_]u8{ protocol.OP_GUI_CONFIG_STATE, 0, 3, 1, 2, 3 });
    defer config.deinit(alloc);
    var hover = try decodeHoverAction(alloc, &[_]u8{ protocol.OP_GUI_HOVER_ACTION, 0, 4, 1, 0, 1, 'x' });
    defer hover.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 2), cursorline.row);
    try std.testing.expectEqual(@as(u24, 0x112233), cursorline.bg);
    try std.testing.expectEqual(@as(u16, 7), separator.col);
    try std.testing.expectEqual(@as(u24, 0x445566), separator.color);
    try std.testing.expectEqual(@as(u16, 120), spacing.value);
    try std.testing.expect(!animation.enabled);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, config.payload);
    try std.testing.expect(hover.visible);
    try std.testing.expectEqualStrings("x", hover.name);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0, 1, 'x' }, hover.payload);
}

test "semantic state renders search and change footer indicators" {
    const alloc = std.testing.allocator;
    const status_packet = &[_]u8{
        protocol.OP_GUI_STATUS_BAR, 1,
        0x07,                       0,
        4,                          0,
        2,                          'o',
        'k',
    };
    const search_packet = &[_]u8{
        protocol.OP_GUI_SEARCH_STATE,
        0,
        6,
        1,
        0,
        5,
        0,
        3,
        0,
    };
    const change_packet = &[_]u8{
        protocol.OP_GUI_CHANGE_SUMMARY,
        1,
        0,
        0,
        0,
        1,
        0,
        8,
        'l',
        'i',
        'b',
        '/',
        'a',
        '.',
        'e',
        'x',
        1,
        0,
        0,
        0,
        4,
        0,
        0,
        0,
        2,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyStatusBarPacket(status_packet);
    try state.applySearchStatePacket(search_packet);
    try state.applyChangeSummaryPacket(change_packet);

    var surface = MockSurface{ .mock_width = 80 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 2, "s", null);
    try expectMockCell(&surface, 2, "c", null);
}

test "semantic state renders edit timeline before notifications overlay" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.notifications = .{
        .visible = true,
        .notification_count = 1,
        .items = try alloc.dupe(NotificationItem, &[_]NotificationItem{
            .{ .title = try alloc.dupe(u8, "Build"), .body = try alloc.dupe(u8, "Done") },
        }),
    };
    state.edit_timeline = .{
        .visible = true,
        .entry_count = 1,
        .entries = try alloc.dupe(TimelineEntry, &[_]TimelineEntry{
            .{ .index = 1, .tool_name = try alloc.dupe(u8, "apply"), .timestamp_delta = 4 },
        }),
    };

    var surface = MockSurface{ .mock_width = 80 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_timeline = false;
    var saw_notifications = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "#")) saw_timeline = true;
        if (std.mem.eql(u8, cell.text, "N")) saw_notifications = true;
    }
    try std.testing.expect(saw_timeline);
    try std.testing.expect(!saw_notifications);
}

test "semantic state renders edit timeline age without suffix" {
    const alloc = std.testing.allocator;

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_accent, .rgb = 0x313233 },
        }),
    };
    state.edit_timeline = .{
        .visible = true,
        .viewing_index = 1,
        .entries = try alloc.dupe(TimelineEntry, &[_]TimelineEntry{
            .{ .index = 1, .tool_name = try alloc.dupe(u8, "apply"), .timestamp_delta = 4 },
        }),
    };

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_age = false;
    var saw_suffix = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "4") and cell.fg == 0x212223) saw_age = true;
        if (std.mem.eql(u8, cell.text, "s") and cell.fg == 0x212223) saw_suffix = true;
    }

    try std.testing.expect(saw_age);
    try std.testing.expect(!saw_suffix);
}

test "semantic state renders extension panel before observatory overlay" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.extension_overlay = .{
        .entry_count = 1,
        .entries = try alloc.dupe(ExtensionOverlayEntry, &[_]ExtensionOverlayEntry{
            .{ .extension = try alloc.dupe(u8, "lsp"), .content = try alloc.dupe(u8, "hint") },
        }),
    };
    state.extension_panel = .{
        .panel_count = 1,
        .panels = try alloc.dupe(ExtensionPanelEntry, &[_]ExtensionPanelEntry{
            .{ .visible = true, .title = try alloc.dupe(u8, "Details") },
        }),
    };
    state.observatory = .{ .visible = true, .count = 3 };

    var surface = MockSurface{ .mock_width = 120 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_extension_panel = false;
    var saw_observatory = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "E")) saw_extension_panel = true;
        if (std.mem.eql(u8, cell.text, "O")) saw_observatory = true;
    }
    try std.testing.expect(saw_extension_panel);
    try std.testing.expect(!saw_observatory);
}

test "semantic state renders extension overlay entries" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_EXTENSION_OVERLAY,
        0,
        25,
        1,
        3,
        'l',
        's',
        'p',
        2,
        'o',
        '1',
        0,
        7,
        0,
        2,
        0,
        4,
        2,
        0x11,
        0x22,
        0x33,
        9,
        0,
        4,
        'h',
        'i',
        'n',
        't',
    };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_accent, .rgb = 0x313233 },
        }),
    };
    try state.applyExtensionOverlayPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_extension = false;
    var saw_coords = false;
    var saw_content = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 4 and cell.col == 6 and std.mem.eql(u8, cell.text, "E") and cell.fg == 0x313233 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 5 and cell.col == 6 and std.mem.eql(u8, cell.text, "l") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_extension = true;
        if (cell.row == 5 and std.mem.eql(u8, cell.text, ":") and cell.fg == 0x212223 and cell.bg == 0x010203) saw_coords = true;
        if (cell.row == 5 and std.mem.eql(u8, cell.text, "h") and cell.fg == 0x112233 and cell.bg == 0x010203) saw_content = true;
        if (cell.row == 4 and cell.col == 74 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_extension);
    try std.testing.expect(saw_coords);
    try std.testing.expect(saw_content);
    try std.testing.expect(saw_background);
}

test "semantic state renders extension panel entries" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_EXTENSION_PANEL,
        0,
        38,
        1,
        3,
        'l',
        's',
        'p',
        2,
        'p',
        '1',
        4,
        'D',
        'i',
        'a',
        'g',
        1,
        0,
        35,
        1,
        2,
        0,
        0,
        5,
        'R',
        'e',
        'a',
        'd',
        'y',
        3,
        1,
        0,
        5,
        'f',
        'i',
        'l',
        'e',
        's',
        0,
        1,
        '3',
    };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_popup_bg, .rgb = 0x010203 },
            .{ .id = theme_popup_fg, .rgb = 0x111213 },
            .{ .id = theme_popup_desc_fg, .rgb = 0x212223 },
            .{ .id = theme_accent, .rgb = 0x313233 },
        }),
    };
    try state.applyExtensionPanelPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    var saw_panel = false;
    var saw_block = false;
    var saw_background = false;
    for (surface.cells.items) |cell| {
        if (cell.row == 1 and cell.col == 6 and std.mem.eql(u8, cell.text, "E") and cell.fg == 0x313233 and cell.bg == 0x010203 and cell.attrs == protocol.ATTR_BOLD) saw_title = true;
        if (cell.row == 2 and cell.col == 6 and std.mem.eql(u8, cell.text, "D") and cell.fg == 0x111213 and cell.bg == 0x010203) saw_panel = true;
        if (cell.row == 3 and cell.col == 6 and std.mem.eql(u8, cell.text, "R") and cell.fg == 0x212223 and cell.bg == 0x010203) saw_block = true;
        if (cell.row == 1 and cell.col == 74 and std.mem.eql(u8, cell.text, " ") and cell.bg == 0x010203) saw_background = true;
    }

    try std.testing.expect(saw_title);
    try std.testing.expect(saw_panel);
    try std.testing.expect(saw_block);
    try std.testing.expect(saw_background);
}

test "semantic state renders observatory overlay rows" {
    const alloc = std.testing.allocator;
    const observatory_packet = &[_]u8{
        protocol.OP_GUI_OBSERVATORY,
        0,
        0,
        0,
        37,
        0x01,
        0,
        3,
        1,
        0,
        1,
        0x02,
        0,
        28,
        5,
        '<',
        '0',
        '.',
        '1',
        '>',
        0,
        0,
        7,
        'B',
        'u',
        'f',
        'f',
        'e',
        'r',
        's',
        1,
        1,
        0,
        0,
        1,
        0x20,
        0,
        7,
        0,
        0,
        0,
        42,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyObservatoryPacket(observatory_packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 4, "O", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "P", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "Q", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 5, "<", null);
    try expectMockCell(&surface, 5, "B", null);
    try expectMockCell(&surface, 5, "7", null);
}

test "semantic state suppresses visible empty observatory like Go" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.observatory = .{ .visible = true };

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "O")) saw_title = true;
    }

    try std.testing.expect(!saw_title);
}

test "semantic state renders agent context before tool manager overlay" {
    const alloc = std.testing.allocator;
    const status_packet = &[_]u8{
        protocol.OP_GUI_STATUS_BAR, 1,
        0x07,                       0,
        4,                          0,
        2,                          'o',
        'k',
    };
    const context_packet = &[_]u8{
        protocol.OP_GUI_AGENT_CONTEXT,
        1,
        0,
        6,
        'R',
        'e',
        'v',
        'i',
        'e',
        'w',
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        42,
        1,
        1,
    };
    const tool_packet = &[_]u8{
        protocol.OP_GUI_TOOL_MANAGER,
        1,
        0,
        0,
        0,
        0,
        1,
        4,
        'r',
        'e',
        'a',
        'd',
        4,
        'R',
        'e',
        'a',
        'd',
        0,
        0,
        0,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyStatusBarPacket(status_packet);
    try state.applyAgentContextPacket(context_packet);
    try state.applyToolManagerPacket(tool_packet);

    var surface = MockSurface{ .mock_width = 100 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_context = false;
    var saw_task = false;
    var saw_tool_manager = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "A")) saw_context = true;
        if (std.mem.eql(u8, cell.text, "R")) saw_task = true;
        if (std.mem.eql(u8, cell.text, "T")) saw_tool_manager = true;
    }
    try std.testing.expect(saw_context);
    try std.testing.expect(saw_task);
    try std.testing.expect(!saw_tool_manager);
}

test "semantic state applies cursorline and renders gutter separator" {
    const alloc = std.testing.allocator;
    const window_packet =
        &[_]u8{
            protocol.OP_GUI_WINDOW_CONTENT, 3,
            0x01,                           0,
            17,                             0,
            1,                              0,
            0,                              0,
            0,                              9,
            0,                              0,
            0,                              2,
            0,                              0,
            0,                              1,
            0x02,                           0,
            30,                             0,
            1,                              0,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              0,
            0,                              4,
            't',                            'e',
            'x',                            't',
            0,                              0,
            0x08,                           0,
            8,                              0,
            0,                              0,
            0,                              10,
            3,
        };

    var state = State.init(alloc);
    defer state.deinit();
    state.theme = .{
        .slots = try alloc.dupe(ThemeSlot, &[_]ThemeSlot{
            .{ .id = theme_editor_bg, .rgb = 0x010203 },
        }),
    };
    try state.applyWindowContentPacket(window_packet);
    try state.applyCursorlinePacket(&[_]u8{ protocol.OP_GUI_CURSORLINE, 0, 0, 0x11, 0x22, 0x33 });
    try state.applyGutterSeparatorPacket(&[_]u8{ protocol.OP_GUI_GUTTER_SEP, 0, 5, 0x44, 0x55, 0x66 });

    var surface = MockSurface{ .mock_width = 20, .mock_height = 4 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try std.testing.expect(state.windows[0].cursorline_visible);
    try std.testing.expectEqual(@as(u16, 0), state.windows[0].cursorline_row);
    try std.testing.expectEqual(@as(u24, 0x112233), state.windows[0].cursorline_bg);
    try expectMockCellStyled(&surface, 0, "│", 0x445566, 0x010203, 0);
}

test "decodeBoard retains card summaries" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_BOARD,
        1,
        0,
        0,
        0,
        7,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        7,
        1,
        0x02,
        0,
        6,
        'F',
        'i',
        'x',
        ' ',
        'C',
        'I',
        3,
        'g',
        'p',
        't',
        0,
        0,
        0,
        9,
        1,
        0,
        10,
        'l',
        'i',
        'b',
        '/',
        'a',
        'p',
        'p',
        '.',
        'e',
        'x',
        0,
    };

    var board = try decodeBoard(alloc, packet);
    defer board.deinit(alloc);

    try std.testing.expect(board.visible);
    try std.testing.expectEqual(@as(u32, 7), board.focused_card_id);
    try std.testing.expectEqual(@as(u16, 1), board.card_count);
    try std.testing.expectEqualStrings("", board.filter_text);
    try std.testing.expectEqual(@as(usize, 1), board.cards.len);
    try std.testing.expectEqual(@as(u32, 7), board.cards[0].id);
    try std.testing.expectEqual(@as(u8, 1), board.cards[0].status);
    try std.testing.expectEqual(@as(u8, 0x02), board.cards[0].flags);
    try std.testing.expectEqualStrings("Fix CI", board.cards[0].task);
    try std.testing.expectEqualStrings("gpt", board.cards[0].model);
    try std.testing.expectEqual(@as(u32, 9), board.cards[0].timestamp);
    try std.testing.expectEqual(@as(usize, 1), board.cards[0].recent_files.len);
    try std.testing.expectEqualStrings("lib/app.ex", board.cards[0].recent_files[0]);
}

test "semantic state suppresses visible empty board like Go" {
    const alloc = std.testing.allocator;
    var state = State.init(alloc);
    defer state.deinit();
    state.board = .{ .visible = true };

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_title = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "B")) saw_title = true;
    }

    try std.testing.expect(!saw_title);
}

test "semantic state renders board cards like Go list items" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_BOARD,
        1,
        0,
        0,
        0,
        7,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        7,
        1,
        0x02,
        0,
        6,
        'F',
        'i',
        'x',
        ' ',
        'C',
        'I',
        3,
        'g',
        'p',
        't',
        0,
        0,
        0,
        9,
        0,
        0,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyBoardPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 8 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 2, "B", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 3, ">", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 3, "w", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "F", null);
}

test "decodeAgentChat retains chat summary" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 3,
        0x01,                       0,
        2,                          1,
        2,                          0x02,
        0,                          5,
        0,                          3,
        'g',                        'p',
        't',                        0x06,
        0,                          4,
        0xFF,                       0,
        0,                          3,
    };

    var chat = try decodeAgentChat(alloc, packet);
    defer chat.deinit(alloc);

    try std.testing.expect(chat.visible);
    try std.testing.expectEqual(@as(u8, 2), chat.status);
    try std.testing.expectEqualStrings("gpt", chat.model_name);
    try std.testing.expectEqual(@as(u16, 3), chat.message_count);
}

test "decodeAgentChat retains Go prompt metadata" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 2,
        0x01,                       0,
        2,                          1,
        1,                          0x03,
        0,                          15,
        0,                          6,
        'f',                        'i',
        'x',                        ' ',
        'i',                        't',
        2,                          0,
        1,                          0,
        4,                          1,
        2,
    };

    var chat = try decodeAgentChat(alloc, packet);
    defer chat.deinit(alloc);

    try std.testing.expect(chat.visible);
    try std.testing.expectEqualStrings("fix it", chat.prompt);
    try std.testing.expectEqual(@as(u8, 2), chat.prompt_line_count);
    try std.testing.expectEqual(@as(u16, 1), chat.prompt_cursor_line);
    try std.testing.expectEqual(@as(u16, 4), chat.prompt_cursor_col);
    try std.testing.expectEqual(@as(u8, 1), chat.prompt_vim_mode);
    try std.testing.expectEqual(@as(u8, 2), chat.prompt_visible_rows);
}

test "decodeAgentChat retains Go completion suggestions" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 2,
        0x01,                       0,
        2,                          1,
        1,                          0x07,
        0,                          32,
        1,                          0,
        0,                          0,
        0,                          0,
        0,                          2,
        0,                          9,
        'r',                        'e',
        'a',                        'd',
        '_',                        'f',
        'i',                        'l',
        'e',                        0,
        4,                          'p',
        'a',                        't',
        'h',                        0,
        3,                          'r',
        'u',                        'n',
        0,                          0,
    };

    var chat = try decodeAgentChat(alloc, packet);
    defer chat.deinit(alloc);

    try std.testing.expect(chat.visible);
    try std.testing.expectEqual(@as(usize, 2), chat.completion.len);
    try std.testing.expectEqualStrings("read_file path", chat.completion[0]);
    try std.testing.expectEqualStrings("run", chat.completion[1]);
}

test "decodeAgentChat retains transcript messages" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 2,
        0x01,                       0,
        2,                          1,
        2,                          0x06,
        0,                          55,
        0xFF,                       1,
        0,                          2,
        0,                          0,
        0,                          14,
        0,                          0,
        0,                          1,
        0x01,                       0,
        0,                          0,
        5,                          'h',
        'e',                        'l',
        'l',                        'o',
        0,                          0,
        0,                          29,
        0,                          0,
        0,                          2,
        0x04,                       1,
        0,                          0,
        0,                          0,
        0,                          0,
        0,                          4,
        'r',                        'e',
        'a',                        'd',
        0,                          4,
        'd',                        'o',
        'n',                        'e',
        0,                          0,
        0,                          0,
        0,
    };

    var chat = try decodeAgentChat(alloc, packet);
    defer chat.deinit(alloc);

    try std.testing.expect(chat.visible);
    try std.testing.expectEqual(@as(u16, 2), chat.message_count);
    try std.testing.expectEqual(@as(usize, 2), chat.messages.len);
    try std.testing.expectEqual(@as(u32, 1), chat.messages[0].id);
    try std.testing.expectEqual(@as(u8, 0x01), chat.messages[0].kind);
    try std.testing.expectEqualStrings("hello", chat.messages[0].text);
    try std.testing.expectEqual(@as(u32, 2), chat.messages[1].id);
    try std.testing.expectEqual(@as(u8, 0x04), chat.messages[1].kind);
    try std.testing.expectEqual(@as(u8, 1), chat.messages[1].status);
    try std.testing.expectEqualStrings("read", chat.messages[1].name);
    try std.testing.expectEqualStrings("done", chat.messages[1].summary);
}

test "decodeAgentChatMessage retains Go tool metadata" {
    const alloc = std.testing.allocator;
    const body = &[_]u8{
        0,    0,   0,   7,
        0x04, 1,   0,   1,
        0,    0,   0,   42,
        0,    9,   'r', 'e',
        'a',  'd', '_', 'f',
        'i',  'l', 'e', 0,
        10,   'l', 'i', 'b',
        '/',  'a', 'p', 'p',
        '.',  'e', 'x', 0,
        0,    0,   2,   'o',
        'k',  1,
    };

    var message = try decodeAgentChatMessage(alloc, body);
    defer message.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 7), message.id);
    try std.testing.expectEqual(@as(u8, 0x04), message.kind);
    try std.testing.expectEqual(@as(u8, 1), message.status);
    try std.testing.expect(message.collapsed);
    try std.testing.expectEqual(@as(u32, 42), message.duration_ms);
    try std.testing.expectEqualStrings("read_file", message.name);
    try std.testing.expectEqualStrings("lib/app.ex", message.summary);
    try std.testing.expectEqualStrings("ok", message.result);
    try std.testing.expectEqual(@as(u8, 1), message.auto_approved_scope);
}

test "decodeAgentChatMessage retains Go approval preview" {
    const alloc = std.testing.allocator;
    const body = &[_]u8{
        0,    0,   0,   8,
        0x09, 0,   0,   9,
        'e',  'd', 'i', 't',
        '_',  'f', 'i', 'l',
        'e',  0,   17,  'U',
        'p',  'd', 'a', 't',
        'e',  ' ', 'l', 'i',
        'b',  '/', 'a', 'p',
        'p',  '.', 'e', 'x',
        0,    4,   't', 'c',
        '-',  '1', 1,   0,
        1,    0,   6,   '+',
        'h',  'e', 'l', 'l',
        'o',
    };

    var message = try decodeAgentChatMessage(alloc, body);
    defer message.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0x09), message.kind);
    try std.testing.expectEqualStrings("edit_file", message.name);
    try std.testing.expectEqualStrings("Update lib/app.ex", message.summary);
    try std.testing.expectEqualStrings("tc-1", message.result);
    try std.testing.expectEqual(@as(u8, 1), message.preview_kind);
    try std.testing.expectEqual(@as(usize, 1), message.preview_lines.len);
    try std.testing.expectEqualStrings("+hello", message.preview_lines[0]);
}

test "decodeAgentChatMessage retains Go usage metrics" {
    const alloc = std.testing.allocator;
    const body = &[_]u8{
        0,    0, 0, 9,
        0x06, 0, 0, 4,
        176,  0, 0, 1,
        44,   0, 0, 0,
        40,   0, 0, 0,
        20,   0, 0, 48,
        212,
    };

    var message = try decodeAgentChatMessage(alloc, body);
    defer message.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0x06), message.kind);
    try std.testing.expectEqual(@as(u32, 1200), message.usage_input);
    try std.testing.expectEqual(@as(u32, 300), message.usage_output);
    try std.testing.expectEqual(@as(u32, 40), message.usage_cache_read);
    try std.testing.expectEqual(@as(u32, 20), message.usage_cache_write);
    try std.testing.expectEqual(@as(u32, 12500), message.usage_cost_micros);
    try std.testing.expectEqualStrings("usage in:1200 out:300", message.text);
}

test "decodeAgentChatMessage retains Go styled assistant text" {
    const alloc = std.testing.allocator;
    const body = &[_]u8{
        0,    0,   0,   10,
        0x07, 0,   2,   0,
        1,    0,   5,   'h',
        'e',  'l', 'l', 'o',
        0,    0,   0,   0,
        0,    0,   0,   0,
        1,    0,   5,   'w',
        'o',  'r', 'l', 'd',
        0,    0,   0,   0,
        0,    0,   0,
    };

    var message = try decodeAgentChatMessage(alloc, body);
    defer message.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0x07), message.kind);
    try std.testing.expectEqualStrings("hello world", message.text);
}

test "decodeAgentChatMessage retains Go styled tool result text" {
    const alloc = std.testing.allocator;
    const body = &[_]u8{
        0,    0,   0,   11,
        0x08, 1,   0,   0,
        0,    0,   0,   8,
        0,    9,   'r', 'e',
        'a',  'd', '_', 'f',
        'i',  'l', 'e', 0,
        10,   'l', 'i', 'b',
        '/',  'a', 'p', 'p',
        '.',  'e', 'x', 0,
        1,    0,   1,   0,
        2,    'o', 'k', 0,
        0,    0,   0,   0,
        0,    0,   2,
    };

    var message = try decodeAgentChatMessage(alloc, body);
    defer message.deinit(alloc);

    try std.testing.expectEqual(@as(u8, 0x08), message.kind);
    try std.testing.expectEqualStrings("read_file", message.name);
    try std.testing.expectEqualStrings("lib/app.ex", message.summary);
    try std.testing.expectEqualStrings("ok", message.result);
    try std.testing.expectEqual(@as(u8, 2), message.auto_approved_scope);
}

test "semantic state renders agent chat before board overlay" {
    const alloc = std.testing.allocator;
    const status_packet = &[_]u8{
        protocol.OP_GUI_STATUS_BAR, 1,
        0x07,                       0,
        4,                          0,
        2,                          'o',
        'k',
    };
    const board_packet = &[_]u8{
        protocol.OP_GUI_BOARD,
        1,
        0,
        0,
        0,
        7,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        7,
        1,
        0x02,
        0,
        6,
        'F',
        'i',
        'x',
        ' ',
        'C',
        'I',
        3,
        'g',
        'p',
        't',
        0,
        0,
        0,
        9,
        0,
        0,
    };
    const chat_packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 1,
        0x01,                       0,
        2,                          1,
        2,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyStatusBarPacket(status_packet);
    try state.applyBoardPacket(board_packet);
    try state.applyAgentChatPacket(chat_packet);

    var surface = MockSurface{ .mock_width = 100 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    var saw_chat = false;
    var saw_transcript = false;
    var saw_board = false;
    for (surface.cells.items) |cell| {
        if (std.mem.eql(u8, cell.text, "A")) saw_chat = true;
        if (std.mem.eql(u8, cell.text, "T")) saw_transcript = true;
        if (std.mem.eql(u8, cell.text, "B")) saw_board = true;
    }
    try std.testing.expect(saw_chat);
    try std.testing.expect(saw_transcript);
    try std.testing.expect(!saw_board);
}

test "semantic state renders agent chat transcript rows" {
    const alloc = std.testing.allocator;
    const chat_packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 2,
        0x01,                       0,
        2,                          1,
        2,                          0x06,
        0,                          55,
        0xFF,                       1,
        0,                          2,
        0,                          0,
        0,                          14,
        0,                          0,
        0,                          1,
        0x01,                       0,
        0,                          0,
        5,                          'h',
        'e',                        'l',
        'l',                        'o',
        0,                          0,
        0,                          29,
        0,                          0,
        0,                          2,
        0x04,                       1,
        0,                          0,
        0,                          0,
        0,                          0,
        0,                          4,
        'r',                        'e',
        'a',                        'd',
        0,                          4,
        'd',                        'o',
        'n',                        'e',
        0,                          0,
        0,                          0,
        0,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyAgentChatPacket(chat_packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 1, "A", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 2, "T", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 3, "Y", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "h", null);
    try expectMockCell(&surface, 5, "T", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 6, "a", null);
    try expectMockCell(&surface, 7, "2", null);
}

test "semantic state renders rich agent chat message blocks like Go" {
    const alloc = std.testing.allocator;

    var preview_lines = try alloc.alloc([]u8, 1);
    preview_lines[0] = try alloc.dupe(u8, "+hello");
    var messages = try alloc.alloc(AgentChatMessage, 5);
    messages[0] = .{ .id = 1, .kind = 0x02, .text = try alloc.dupe(u8, "answer") };
    messages[1] = .{ .id = 2, .kind = 0x03, .text = try alloc.dupe(u8, "checking"), .collapsed = true };
    messages[2] = .{ .id = 3, .kind = 0x05, .text = try alloc.dupe(u8, "couldn't authenticate"), .status = 1 };
    messages[3] = .{
        .id = 4,
        .kind = 0x09,
        .name = try alloc.dupe(u8, "edit_file"),
        .summary = try alloc.dupe(u8, "Update lib/app.ex"),
        .preview_kind = 1,
        .preview_lines = preview_lines,
    };
    messages[4] = .{
        .id = 5,
        .kind = 0x06,
        .text = try alloc.dupe(u8, "usage in:1200 out:300"),
        .usage_input = 1200,
        .usage_output = 300,
        .usage_cost_micros = 12500,
    };

    var state = State.init(alloc);
    defer state.deinit();
    state.agent_chat = .{
        .visible = true,
        .status = 1,
        .messages = messages,
    };

    var surface = MockSurface{ .mock_width = 100, .mock_height = 18 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 4, "M", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 5, "a", null);
    try expectMockCell(&surface, 6, "T", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 7, "c", null);
    try expectMockCell(&surface, 8, "N", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 8, "a", null);
    try expectMockCell(&surface, 9, "A", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 9, "d", null);
    try expectMockCell(&surface, 10, "+", null);
    try expectMockCell(&surface, 11, "U", null);
}

test "semantic state renders agent prompt composer like Go" {
    const alloc = std.testing.allocator;
    const packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 2,
        0x01,                       0,
        2,                          1,
        1,                          0x03,
        0,                          15,
        0,                          6,
        'f',                        'i',
        'x',                        ' ',
        'i',                        't',
        2,                          0,
        1,                          0,
        4,                          1,
        2,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyAgentChatPacket(packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 4, "P", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 5, "I", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 5, "f", null);
    try expectMockCell(&surface, 6, "E", null);
    try expectMockCell(&surface, 6, "2", null);
    try expectMockCell(&surface, 6, "5", null);
}

test "semantic state renders empty agent chat landing state like Go" {
    const alloc = std.testing.allocator;
    const chat_packet = &[_]u8{
        protocol.OP_GUI_AGENT_CHAT, 1,
        0x01,                       0,
        2,                          1,
        2,
    };

    var state = State.init(alloc);
    defer state.deinit();
    try state.applyAgentChatPacket(chat_packet);

    var surface = MockSurface{ .mock_width = 80, .mock_height = 12 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCell(&surface, 1, "A", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 2, "T", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 3, "M", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 4, "A", null);
    try expectMockCell(&surface, 5, "S", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 6, "/", protocol.ATTR_BOLD);
    try expectMockCell(&surface, 6, "E", null);
    try expectMockCell(&surface, 7, "R", null);
    try expectMockCell(&surface, 8, "D", null);
    try expectMockCell(&surface, 9, "0", null);
}

test "semantic state renders wide agent chat details rail like Go" {
    const alloc = std.testing.allocator;

    var messages = try alloc.alloc(AgentChatMessage, 3);
    messages[0] = .{
        .id = 1,
        .kind = 0x04,
        .name = try alloc.dupe(u8, "read_file"),
        .summary = try alloc.dupe(u8, "lib/app.ex"),
        .result = try alloc.dupe(u8, "ok"),
        .status = 0,
        .duration_ms = 42,
    };
    messages[1] = .{
        .id = 2,
        .kind = 0x09,
        .name = try alloc.dupe(u8, "edit_file"),
        .summary = try alloc.dupe(u8, "Update lib/app.ex"),
        .status = 0,
    };
    messages[2] = .{
        .id = 3,
        .kind = 0x06,
        .text = try alloc.dupe(u8, "usage in:1200 out:300"),
        .usage_input = 1200,
        .usage_output = 300,
        .usage_cost_micros = 12500,
    };

    var state = State.init(alloc);
    defer state.deinit();
    state.agent_chat = .{
        .visible = true,
        .status = 1,
        .model_name = try alloc.dupe(u8, "openai:gpt-5"),
        .pending = try alloc.dupe(u8, "approve edit"),
        .thinking_level = try alloc.dupe(u8, "high"),
        .messages = messages,
    };

    var surface = MockSurface{ .mock_width = 160, .mock_height = 24 };
    defer surface.deinit(alloc);
    state.render(MockSurface, &surface);

    try expectMockCellAfterCol(&surface, 110, "S", protocol.ATTR_BOLD);
    try expectMockCellAfterCol(&surface, 110, "P", null);
    try expectMockCellAfterCol(&surface, 110, "M", null);
    try expectMockCellAfterCol(&surface, 110, "T", null);
    try expectMockCellAfterCol(&surface, 110, "A", null);
    try expectMockCellAfterCol(&surface, 110, "C", null);
}
