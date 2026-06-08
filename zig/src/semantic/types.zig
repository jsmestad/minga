const std = @import("std");

pub const Error = error{Malformed} || std.mem.Allocator.Error;

/// A clickable/status modeline segment.
pub const StatusSegment = struct {
    name: []u8 = &.{},
    text: []u8 = &.{},
    command: []u8 = &.{},
    fg: u24 = 0,
    bg: u24 = 0,
    attrs: u8 = 0,

    pub fn deinit(self: *StatusSegment, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.text);
        alloc.free(self.command);
        self.* = .{};
    }
};

/// One retained tab entry decoded from `gui_tab_bar`.
pub const Tab = struct {
    id: u32 = 0,
    group_id: u16 = 0,
    flags: u8 = 0,
    icon: []u8 = &.{},
    label: []u8 = &.{},
    tint: u32 = 0,

    pub fn active(self: Tab) bool {
        return self.flags & 0x01 != 0;
    }

    pub fn dirty(self: Tab) bool {
        return self.flags & 0x02 != 0;
    }

    pub fn agent(self: Tab) bool {
        return self.flags & 0x04 != 0;
    }

    pub fn attention(self: Tab) bool {
        return self.flags & 0x08 != 0;
    }

    pub fn agentStatus(self: Tab) u8 {
        return (self.flags >> 4) & 0x07;
    }

    pub fn pinned(self: Tab) bool {
        return self.flags & 0x80 != 0;
    }

    pub fn deinit(self: *Tab, alloc: std.mem.Allocator) void {
        alloc.free(self.icon);
        alloc.free(self.label);
        self.* = .{};
    }
};

/// Retained tab bar state decoded from `gui_tab_bar`.
pub const TabBar = struct {
    active_index: u8 = 0,
    tabs: []Tab = &.{},

    pub fn deinit(self: *TabBar, alloc: std.mem.Allocator) void {
        for (self.tabs) |*tab| tab.deinit(alloc);
        alloc.free(self.tabs);
        self.* = .{};
    }
};

/// One retained minibuffer completion candidate.
pub const MinibufferCandidate = struct {
    label: []u8 = &.{},
    description: []u8 = &.{},
    annotation: []u8 = &.{},

    pub fn deinit(self: *MinibufferCandidate, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.description);
        alloc.free(self.annotation);
        self.* = .{};
    }
};

/// Retained minibuffer state decoded from `gui_minibuffer`.
pub const Minibuffer = struct {
    visible: bool = false,
    mode: u8 = 0,
    cursor_pos: u16 = 0xFFFF,
    prompt: []u8 = &.{},
    input: []u8 = &.{},
    context: []u8 = &.{},
    selected_index: u16 = 0,
    total_candidates: u16 = 0,
    candidates: []MinibufferCandidate = &.{},

    pub fn deinit(self: *Minibuffer, alloc: std.mem.Allocator) void {
        alloc.free(self.prompt);
        alloc.free(self.input);
        alloc.free(self.context);
        for (self.candidates) |*candidate| candidate.deinit(alloc);
        alloc.free(self.candidates);
        self.* = .{};
    }
};

/// One retained which-key binding.
pub const WhichKeyBinding = struct {
    kind: u8 = 0,
    key: []u8 = &.{},
    description: []u8 = &.{},
    icon: []u8 = &.{},

    pub fn deinit(self: *WhichKeyBinding, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        alloc.free(self.description);
        alloc.free(self.icon);
        self.* = .{};
    }
};

/// Retained which-key overlay state decoded from `gui_which_key`.
pub const WhichKey = struct {
    visible: bool = false,
    prefix: []u8 = &.{},
    page: u8 = 0,
    page_count: u8 = 0,
    bindings: []WhichKeyBinding = &.{},

    pub fn deinit(self: *WhichKey, alloc: std.mem.Allocator) void {
        alloc.free(self.prefix);
        for (self.bindings) |*binding| binding.deinit(alloc);
        alloc.free(self.bindings);
        self.* = .{};
    }
};

/// One retained completion candidate.
pub const CompletionItem = struct {
    kind: u8 = 0,
    label: []u8 = &.{},
    detail: []u8 = &.{},

    pub fn deinit(self: *CompletionItem, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.detail);
        self.* = .{};
    }
};

/// Retained completion popup state decoded from `gui_completion`.
pub const Completion = struct {
    visible: bool = false,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    selected_index: u16 = 0,
    items: []CompletionItem = &.{},

    pub fn deinit(self: *Completion, alloc: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = .{};
    }
};

/// Retained breadcrumb state decoded from `gui_breadcrumb`.
pub const Breadcrumb = struct {
    segments: [][]u8 = &.{},

    pub fn deinit(self: *Breadcrumb, alloc: std.mem.Allocator) void {
        for (self.segments) |segment| alloc.free(segment);
        alloc.free(self.segments);
        self.* = .{};
    }
};

/// One retained picker row.
pub const PickerItem = struct {
    label: []u8 = &.{},
    description: []u8 = &.{},
    annotation: []u8 = &.{},
    icon_color: u24 = 0,
    flags: u8 = 0,

    pub fn twoLine(self: PickerItem) bool {
        return self.flags & 0x01 != 0;
    }

    pub fn marked(self: PickerItem) bool {
        return self.flags & 0x02 != 0;
    }

    pub fn deinit(self: *PickerItem, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.description);
        alloc.free(self.annotation);
        self.* = .{};
    }
};

/// Retained picker overlay state decoded from `gui_picker`.
pub const Picker = struct {
    visible: bool = false,
    selected_index: u16 = 0,
    filtered_count: u16 = 0,
    total_count: u16 = 0,
    marked_count: u16 = 0,
    has_preview: bool = false,
    load_status: u8 = 0,
    title: []u8 = &.{},
    query: []u8 = &.{},
    mode_prefix: []u8 = &.{},
    load_error: []u8 = &.{},
    actions: [][]u8 = &.{},
    action_index: u8 = 0,
    action_visible: bool = false,
    items: []PickerItem = &.{},

    pub fn deinit(self: *Picker, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.query);
        alloc.free(self.mode_prefix);
        alloc.free(self.load_error);
        for (self.actions) |action| alloc.free(action);
        alloc.free(self.actions);
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = .{};
    }
};

/// One retained picker preview styled text segment.
pub const PreviewSegment = struct {
    text: []u8 = &.{},
    fg: u24 = 0,
    bold: bool = false,

    pub fn deinit(self: *PreviewSegment, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        self.* = .{};
    }
};

/// One retained picker preview line.
pub const PreviewLine = struct {
    segments: []PreviewSegment = &.{},

    pub fn deinit(self: *PreviewLine, alloc: std.mem.Allocator) void {
        for (self.segments) |*segment| segment.deinit(alloc);
        alloc.free(self.segments);
        self.* = .{};
    }
};

/// Retained picker preview state decoded from `gui_picker_preview`.
pub const PickerPreview = struct {
    visible: bool = false,
    lines: []PreviewLine = &.{},

    pub fn deinit(self: *PickerPreview, alloc: std.mem.Allocator) void {
        for (self.lines) |*line| line.deinit(alloc);
        alloc.free(self.lines);
        self.* = .{};
    }
};

/// One retained hover popup rich text segment.
pub const HoverSegment = struct {
    style: u8 = 0,
    fg: u24 = 0,
    flags: u8 = 0,
    text: []u8 = &.{},

    pub fn deinit(self: *HoverSegment, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        self.* = .{};
    }
};

/// One retained hover popup line.
pub const HoverLine = struct {
    line_type: u8 = 0,
    segments: []HoverSegment = &.{},

    pub fn deinit(self: *HoverLine, alloc: std.mem.Allocator) void {
        for (self.segments) |*segment| segment.deinit(alloc);
        alloc.free(self.segments);
        self.* = .{};
    }
};

/// Retained hover popup state decoded from `gui_hover_popup`.
pub const HoverPopup = struct {
    visible: bool = false,
    anchor_row: u16 = 0,
    anchor_col: u16 = 0,
    focused: bool = false,
    scroll_offset: u16 = 0,
    lines: []HoverLine = &.{},

    pub fn deinit(self: *HoverPopup, alloc: std.mem.Allocator) void {
        for (self.lines) |*line| line.deinit(alloc);
        alloc.free(self.lines);
        self.* = .{};
    }
};

/// One retained signature help parameter.
pub const SignatureParameter = struct {
    label: []u8 = &.{},
    documentation: []u8 = &.{},

    pub fn deinit(self: *SignatureParameter, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.documentation);
        self.* = .{};
    }
};

/// One retained signature help overload.
pub const Signature = struct {
    label: []u8 = &.{},
    documentation: []u8 = &.{},
    parameters: []SignatureParameter = &.{},

    pub fn deinit(self: *Signature, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.documentation);
        for (self.parameters) |*parameter| parameter.deinit(alloc);
        alloc.free(self.parameters);
        self.* = .{};
    }
};

/// Retained signature help state decoded from `gui_signature_help`.
pub const SignatureHelp = struct {
    visible: bool = false,
    anchor_row: u16 = 0,
    anchor_col: u16 = 0,
    active_signature: u8 = 0,
    active_parameter: u8 = 0,
    signatures: []Signature = &.{},

    pub fn deinit(self: *SignatureHelp, alloc: std.mem.Allocator) void {
        for (self.signatures) |*signature| signature.deinit(alloc);
        alloc.free(self.signatures);
        self.* = .{};
    }
};

/// Retained float popup state decoded from `gui_float_popup`.
pub const FloatPopup = struct {
    visible: bool = false,
    width: u16 = 0,
    height: u16 = 0,
    title: []u8 = &.{},
    lines: [][]u8 = &.{},

    pub fn deinit(self: *FloatPopup, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        for (self.lines) |line| alloc.free(line);
        alloc.free(self.lines);
        self.* = .{};
    }
};

/// One retained git status entry.
pub const GitStatusEntry = struct {
    path_hash: u32 = 0,
    section: u8 = 0,
    status: u8 = 0,
    path: []u8 = &.{},

    pub fn deinit(self: *GitStatusEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        self.* = .{};
    }
};

/// Retained git toast state.
pub const GitToast = struct {
    visible: bool = false,
    level: u8 = 0,
    action: u8 = 0,
    message: []u8 = &.{},

    pub fn deinit(self: *GitToast, alloc: std.mem.Allocator) void {
        alloc.free(self.message);
        self.* = .{};
    }
};

/// Retained git status state decoded from `gui_git_status`.
pub const GitStatus = struct {
    repo_state: u8 = 0,
    syncing: bool = false,
    ahead: u16 = 0,
    behind: u16 = 0,
    branch: []u8 = &.{},
    entries: []GitStatusEntry = &.{},
    toast: GitToast = .{},
    entry_base_path: []u8 = &.{},
    last_commit_message: []u8 = &.{},
    stash_count: u16 = 0,

    pub fn deinit(self: *GitStatus, alloc: std.mem.Allocator) void {
        alloc.free(self.branch);
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
        self.toast.deinit(alloc);
        alloc.free(self.entry_base_path);
        alloc.free(self.last_commit_message);
        self.* = .{};
    }
};

/// One retained bottom panel tab.
pub const BottomPanelTab = struct {
    tab_type: u8 = 0,
    name: []u8 = &.{},

    pub fn deinit(self: *BottomPanelTab, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.* = .{};
    }
};

/// One retained bottom panel message entry.
pub const BottomPanelEntry = struct {
    id: u32 = 0,
    level: u8 = 0,
    subsystem: u8 = 0,
    timestamp_secs: u32 = 0,
    file_path: []u8 = &.{},
    text: []u8 = &.{},

    pub fn deinit(self: *BottomPanelEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.file_path);
        alloc.free(self.text);
        self.* = .{};
    }
};

/// Retained bottom panel state decoded from `gui_bottom_panel`.
pub const BottomPanel = struct {
    visible: bool = false,
    active_tab_index: u8 = 0,
    height_percent: u8 = 0,
    filter: u8 = 0,
    tabs: []BottomPanelTab = &.{},
    entries: []BottomPanelEntry = &.{},

    pub fn deinit(self: *BottomPanel, alloc: std.mem.Allocator) void {
        for (self.tabs) |*tab| tab.deinit(alloc);
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.tabs);
        alloc.free(self.entries);
        self.* = .{};
    }
};

/// One retained vertical split separator.
pub const VerticalSeparator = struct {
    col: u16 = 0,
    start_row: u16 = 0,
    end_row: u16 = 0,
};

/// One retained horizontal split separator.
pub const HorizontalSeparator = struct {
    row: u16 = 0,
    col: u16 = 0,
    width: u16 = 0,
    filename: []u8 = &.{},

    pub fn deinit(self: *HorizontalSeparator, alloc: std.mem.Allocator) void {
        alloc.free(self.filename);
        self.* = .{};
    }
};

/// Retained split separator state decoded from `gui_split_separators`.
pub const SplitSeparators = struct {
    color: u24 = 0,
    verticals: []VerticalSeparator = &.{},
    horizontals: []HorizontalSeparator = &.{},

    pub fn deinit(self: *SplitSeparators, alloc: std.mem.Allocator) void {
        for (self.horizontals) |*horizontal| horizontal.deinit(alloc);
        alloc.free(self.verticals);
        alloc.free(self.horizontals);
        self.* = .{};
    }
};

/// One style span within a retained window row.
pub const WindowSpan = struct {
    start_col: u16 = 0,
    end_col: u16 = 0,
    fg: u24 = 0,
    bg: u24 = 0,
    attrs: u8 = 0,
};

pub const RenderStyle = struct {
    fg: u24 = 0,
    bg: u24 = 0,
    attrs: u8 = 0,
    strikethrough: bool = false,
    ul_style: u3 = 0,
};

/// One retained semantic buffer row.
pub const WindowRow = struct {
    ref: bool = false,
    row_type: u8 = 0,
    row_id: u64 = 0,
    buf_line: u32 = 0,
    content_hash: u32 = 0,
    text: []u8 = &.{},
    spans: []WindowSpan = &.{},

    pub fn deinit(self: *WindowRow, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.spans);
        self.* = .{};
    }
};

/// Retained rows update decoded from `gui_window_rows_delta` and `gui_window_viewport_delta`.
pub const WindowRowsDelta = struct {
    window_id: u16 = 0,
    content_epoch: u32 = 0,
    flags: u8 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_shape: u8 = 0,
    scroll_left: u16 = 0,
    geometry_set: bool = false,
    origin_row: u16 = 0,
    origin_col: u16 = 0,
    text_width: u16 = 0,
    text_height: u16 = 0,
    cursorline_visible: bool = false,
    cursorline_row: u16 = 0,
    cursorline_bg: u24 = 0,
    rows: []WindowRow = &.{},
    selection: ?WindowSelection = null,
    search_matches: ?[]SearchMatch = null,
    diagnostic_ranges: ?[]DiagnosticRange = null,
    document_highlights: ?[]DocumentHighlight = null,
    annotations: ?[]LineAnnotation = null,

    pub fn deinit(self: *WindowRowsDelta, alloc: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(alloc);
        alloc.free(self.rows);
        if (self.search_matches) |items| alloc.free(items);
        if (self.diagnostic_ranges) |items| alloc.free(items);
        if (self.document_highlights) |items| alloc.free(items);
        if (self.annotations) |items| {
            for (items) |*item| item.deinit(alloc);
            alloc.free(items);
        }
        self.* = .{};
    }
};

pub const WindowSelection = struct {
    selection_type: u8 = 0,
    start_row: u16 = 0,
    start_col: u16 = 0,
    end_row: u16 = 0,
    end_col: u16 = 0,
};

pub const SearchMatch = struct {
    row: u16 = 0,
    start_col: u16 = 0,
    end_col: u16 = 0,
    current: bool = false,
};

pub const DiagnosticRange = struct {
    start_row: u16 = 0,
    start_col: u16 = 0,
    end_row: u16 = 0,
    end_col: u16 = 0,
    severity: u8 = 0,
};

pub const DocumentHighlight = struct {
    start_row: u16 = 0,
    start_col: u16 = 0,
    end_row: u16 = 0,
    end_col: u16 = 0,
    kind: u8 = 0,
};

pub const LineAnnotation = struct {
    row: u16 = 0,
    kind: u8 = 0,
    fg: u24 = 0,
    bg: u24 = 0,
    text: []u8 = &.{},

    pub fn deinit(self: *LineAnnotation, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        self.* = .{};
    }
};

/// Cursor/cursorline overlay update decoded from `gui_window_overlay_delta`.
pub const WindowOverlayDelta = struct {
    window_id: u16 = 0,
    content_epoch: u32 = 0,
    flags: u8 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_shape: u8 = 0,
    cursorline_visible: bool = false,
    cursorline_row: u16 = 0,
    cursorline_bg: u24 = 0,
};

/// One retained file-tree row.
pub const FileTreeRow = struct {
    id: []u8 = &.{},
    path: []u8 = &.{},
    name: []u8 = &.{},
    icon: []u8 = &.{},
    depth: u8 = 0,
    flags: u16 = 0,
    git_status: u8 = 0,
    diagnostic_errors: u16 = 0,
    diagnostic_warnings: u16 = 0,
    diagnostic_info: u16 = 0,
    diagnostic_hints: u16 = 0,
    editing_text: []u8 = &.{},

    pub fn directory(self: FileTreeRow) bool {
        return self.flags & 0x01 != 0;
    }

    pub fn expanded(self: FileTreeRow) bool {
        return self.flags & 0x02 != 0;
    }

    pub fn selected(self: FileTreeRow) bool {
        return self.flags & 0x04 != 0;
    }

    pub fn focused(self: FileTreeRow) bool {
        return self.flags & 0x08 != 0;
    }

    pub fn active(self: FileTreeRow) bool {
        return self.flags & 0x10 != 0;
    }

    pub fn dirty(self: FileTreeRow) bool {
        return self.flags & 0x20 != 0;
    }

    pub fn visibleDiagnostics(self: FileTreeRow) u16 {
        return self.diagnostic_errors +| self.diagnostic_warnings;
    }

    pub fn deinit(self: *FileTreeRow, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.path);
        alloc.free(self.name);
        alloc.free(self.icon);
        alloc.free(self.editing_text);
        self.* = .{};
    }
};

/// Retained file-tree sidebar decoded from `gui_file_tree`.
pub const FileTree = struct {
    visible: bool = false,
    focused: bool = false,
    status: u8 = 0,
    width: u16 = 0,
    selected_id: []u8 = &.{},
    root_path: []u8 = &.{},
    error_text: []u8 = &.{},
    rows: []FileTreeRow = &.{},

    pub fn deinit(self: *FileTree, alloc: std.mem.Allocator) void {
        alloc.free(self.selected_id);
        alloc.free(self.root_path);
        alloc.free(self.error_text);
        for (self.rows) |*row| row.deinit(alloc);
        alloc.free(self.rows);
        self.* = .{};
    }
};

/// Selection-only update decoded from `gui_file_tree_selection`.
pub const FileTreeSelection = struct {
    focused: bool = false,
    selected_id: []u8 = &.{},

    pub fn deinit(self: *FileTreeSelection, alloc: std.mem.Allocator) void {
        alloc.free(self.selected_id);
        self.* = .{};
    }
};

/// One retained sidebar entry decoded from `gui_sidebars`.
pub const Sidebar = struct {
    id: []u8 = &.{},
    display_name: []u8 = &.{},
    semantic_kind: []u8 = &.{},
    icon: []u8 = &.{},
    order: u16 = 0,
    flags: u8 = 0,
    preferred_width: u16 = 0,
    badge_count: u16 = 0,
    visible: bool = false,
    focused: bool = false,

    pub fn deinit(self: *Sidebar, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.display_name);
        alloc.free(self.semantic_kind);
        alloc.free(self.icon);
        self.* = .{};
    }
};

/// Retained sidebars metadata decoded from `gui_sidebars`.
pub const Sidebars = struct {
    visible: bool = false,
    active_id: []u8 = &.{},
    items: []Sidebar = &.{},

    pub fn deinit(self: *Sidebars, alloc: std.mem.Allocator) void {
        alloc.free(self.active_id);
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = .{};
    }

    pub fn visibleCount(self: Sidebars) usize {
        var count: usize = 0;
        for (self.items) |item| {
            if (item.visible) count += 1;
        }
        return count;
    }

    pub fn preferredWidth(self: Sidebars) u16 {
        for (self.items) |item| {
            if (item.visible) return @max(item.preferred_width, 18);
        }
        return 0;
    }
};

/// One retained gutter entry for a semantic window row.
pub const GutterEntry = struct {
    buf_line: u32 = 0,
    display_type: u8 = 0,
    sign_type: u8 = 0,
    fold_end_line: u32 = 0,
    sign_fg: u24 = 0,
    sign_text: []u8 = &.{},

    pub fn deinit(self: *GutterEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.sign_text);
        self.* = .{};
    }
};

/// Retained gutter state decoded from `gui_gutter`.
pub const Gutter = struct {
    window_id: u16 = 0,
    content_row: u16 = 0,
    content_col: u16 = 0,
    content_height: u16 = 0,
    is_active: bool = false,
    content_width: u16 = 0,
    cursor_line: u32 = 0,
    line_number_style: u8 = 0,
    line_number_width: u8 = 0,
    sign_col_width: u8 = 0,
    entries: []GutterEntry = &.{},

    pub fn deinit(self: *Gutter, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
        self.* = .{};
    }
};

/// Retained indent guide state decoded from `gui_indent_guides`.
pub const IndentGuides = struct {
    window_id: u16 = 0,
    tab_width: u8 = 0,
    active_guide_col: u16 = 0,
    guide_cols: []u16 = &.{},
    line_indent_levels: []u8 = &.{},

    pub fn deinit(self: *IndentGuides, alloc: std.mem.Allocator) void {
        alloc.free(self.guide_cols);
        alloc.free(self.line_indent_levels);
        self.* = .{};
    }
};

/// One retained theme color slot decoded from `gui_theme`.
pub const ThemeSlot = struct {
    id: u8 = 0,
    rgb: u24 = 0,
};

/// Retained theme state decoded from `gui_theme`.
pub const Theme = struct {
    slots: []ThemeSlot = &.{},

    pub fn deinit(self: *Theme, alloc: std.mem.Allocator) void {
        alloc.free(self.slots);
        self.* = .{};
    }

    pub fn color(self: Theme, id: u8) u24 {
        for (self.slots) |slot| {
            if (slot.id == id) return slot.rgb;
        }
        return 0;
    }
};

/// One retained workspace summary.
pub const Workspace = struct {
    id: u16 = 0,
    kind: u8 = 0,
    status: u8 = 0,
    flags: u16 = 0,
    color: u24 = 0,
    tab_count: u16 = 0,
    draft_count: u16 = 0,
    conflict_count: u16 = 0,
    background_count: u16 = 0,
    label: []u8 = &.{},
    icon: []u8 = &.{},

    pub fn attention(self: Workspace) bool {
        return self.flags & 0x01 != 0;
    }

    pub fn deinit(self: *Workspace, alloc: std.mem.Allocator) void {
        alloc.free(self.label);
        alloc.free(self.icon);
        self.* = .{};
    }
};

/// One visible tab entry in the workspace bar.
pub const WorkspaceTab = struct {
    id: u32 = 0,
    workspace_id: u16 = 0,
    kind: u8 = 0,
    flags: u16 = 0,
    path_hash: u32 = 0,
    icon: []u8 = &.{},
    label: []u8 = &.{},
    path: []u8 = &.{},
    tint: u32 = 0,

    pub fn dirty(self: WorkspaceTab) bool {
        return self.flags & 0x01 != 0;
    }

    pub fn deinit(self: *WorkspaceTab, alloc: std.mem.Allocator) void {
        alloc.free(self.icon);
        alloc.free(self.label);
        alloc.free(self.path);
        self.* = .{};
    }
};

/// Retained workspace header state decoded from `gui_workspaces`.
pub const Workspaces = struct {
    visible: u8 = 0,
    active_workspace_id: u16 = 0,
    mode: u8 = 0,
    flags: u8 = 0,
    workspace_count: u8 = 0,
    spaces: []Workspace = &.{},
    tabs: []WorkspaceTab = &.{},

    pub fn deinit(self: *Workspaces, alloc: std.mem.Allocator) void {
        for (self.spaces) |*space| space.deinit(alloc);
        for (self.tabs) |*tab| tab.deinit(alloc);
        alloc.free(self.spaces);
        alloc.free(self.tabs);
        self.* = .{};
    }
};

/// Retained search state decoded from `gui_search_state`.
pub const SearchState = struct {
    active: bool = false,
    match_count: u16 = 0,
    current_index: u16 = 0,
    flags: u8 = 0,
};

/// One retained change-summary entry decoded from `gui_change_summary`.
pub const ChangeSummaryEntry = struct {
    path: []u8 = &.{},
    action: u8 = 0,
    lines_added: u32 = 0,
    lines_removed: u32 = 0,

    pub fn deinit(self: *ChangeSummaryEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.path);
        self.* = .{};
    }
};

/// Retained change-summary state decoded from `gui_change_summary`.
pub const ChangeSummary = struct {
    visible: bool = false,
    selected_index: u16 = 0,
    entries: []ChangeSummaryEntry = &.{},

    pub fn deinit(self: *ChangeSummary, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
        self.* = .{};
    }
};

/// One retained notification item decoded from `gui_notifications`.
pub const NotificationAction = struct {
    id: []u8 = &.{},
    label: []u8 = &.{},

    pub fn deinit(self: *NotificationAction, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.label);
        self.* = .{};
    }
};

pub const NotificationItem = struct {
    id: []u8 = &.{},
    level: u8 = 0,
    dismissable: bool = false,
    created_at: u64 = 0,
    updated_at: u64 = 0,
    auto_dismiss_ms: u32 = 0,
    title: []u8 = &.{},
    body: []u8 = &.{},
    source: []u8 = &.{},
    actions: []NotificationAction = &.{},

    pub fn deinit(self: *NotificationItem, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.body);
        alloc.free(self.source);
        for (self.actions) |*action| action.deinit(alloc);
        alloc.free(self.actions);
        self.* = .{};
    }
};

/// Retained notification state decoded from `gui_notifications`.
pub const Notifications = struct {
    visible: bool = false,
    notification_count: u16 = 0,
    items: []NotificationItem = &.{},

    pub fn deinit(self: *Notifications, alloc: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
        self.* = .{};
    }
};

/// One retained edit timeline entry decoded from `gui_edit_timeline`.
pub const TimelineEntry = struct {
    index: u8 = 0,
    tool_name: []u8 = &.{},
    timestamp_delta: u32 = 0,

    pub fn deinit(self: *TimelineEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.tool_name);
        self.* = .{};
    }
};

/// Retained edit timeline state decoded from `gui_edit_timeline`.
pub const EditTimeline = struct {
    visible: bool = false,
    viewing_index: u16 = 0,
    entry_count: u8 = 0,
    entries: []TimelineEntry = &.{},

    pub fn deinit(self: *EditTimeline, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
        self.* = .{};
    }
};

/// Retained extension overlay state decoded from `gui_extension_overlay`.
pub const ExtensionOverlay = struct {
    entry_count: u8 = 0,
    entries: []ExtensionOverlayEntry = &.{},

    pub fn deinit(self: *ExtensionOverlay, alloc: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(alloc);
        alloc.free(self.entries);
        self.* = .{};
    }
};

/// One retained extension overlay row.
pub const ExtensionOverlayEntry = struct {
    extension: []u8 = &.{},
    id: []u8 = &.{},
    window_id: u16 = 0,
    row: u16 = 0,
    col: u16 = 0,
    shape: u8 = 0,
    fg: u24 = 0,
    opacity: u8 = 0,
    content: []u8 = &.{},

    pub fn deinit(self: *ExtensionOverlayEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.extension);
        alloc.free(self.id);
        alloc.free(self.content);
        self.* = .{};
    }
};

/// Retained extension panel state decoded from `gui_extension_panel`.
pub const ExtensionPanel = struct {
    panel_count: u8 = 0,
    panels: []ExtensionPanelEntry = &.{},

    pub fn deinit(self: *ExtensionPanel, alloc: std.mem.Allocator) void {
        for (self.panels) |*panel| panel.deinit(alloc);
        alloc.free(self.panels);
        self.* = .{};
    }
};

/// One retained extension panel with display-ready content blocks.
pub const ExtensionPanelEntry = struct {
    extension: []u8 = &.{},
    id: []u8 = &.{},
    title: []u8 = &.{},
    position: u8 = 0,
    size_type: u8 = 0,
    size_value: u8 = 0,
    visible: bool = false,
    blocks: [][]u8 = &.{},

    pub fn deinit(self: *ExtensionPanelEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.extension);
        alloc.free(self.id);
        alloc.free(self.title);
        for (self.blocks) |block| alloc.free(block);
        alloc.free(self.blocks);
        self.* = .{};
    }
};

/// Retained observatory visibility decoded from `gui_observatory`.
pub const Observatory = struct {
    visible: bool = false,
    count: u16 = 0,
    nodes: []ObservatoryNode = &.{},

    pub fn deinit(self: *Observatory, alloc: std.mem.Allocator) void {
        for (self.nodes) |*node| node.deinit(alloc);
        alloc.free(self.nodes);
        self.* = .{};
    }
};

/// One retained BEAM process row decoded from `gui_observatory`.
pub const ObservatoryNode = struct {
    pid: []u8 = &.{},
    name: []u8 = &.{},
    process_class: u8 = 5,
    depth: u8 = 0,
    memory: u32 = 0,
    message_queue_len: u16 = 0,
    reductions: u32 = 0,

    pub fn deinit(self: *ObservatoryNode, alloc: std.mem.Allocator) void {
        alloc.free(self.pid);
        alloc.free(self.name);
        self.* = .{};
    }
};

/// Retained agent context state decoded from `gui_agent_context`.
pub const AgentContext = struct {
    visible: bool = false,
    task: []u8 = &.{},
    timestamp: u64 = 0,
    status: u8 = 0,
    can_approve: bool = false,

    pub fn deinit(self: *AgentContext, alloc: std.mem.Allocator) void {
        alloc.free(self.task);
        self.* = .{};
    }
};

/// One retained tool summary decoded from `gui_tool_manager`.
pub const ToolSummary = struct {
    name: []u8 = &.{},
    label: []u8 = &.{},
    status: u8 = 0,

    pub fn deinit(self: *ToolSummary, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.label);
        self.* = .{};
    }
};

/// Retained tool manager state decoded from `gui_tool_manager`.
pub const ToolManager = struct {
    visible: bool = false,
    filter: u8 = 0,
    selected: u16 = 0,
    tools: []ToolSummary = &.{},

    pub fn deinit(self: *ToolManager, alloc: std.mem.Allocator) void {
        for (self.tools) |*tool| tool.deinit(alloc);
        alloc.free(self.tools);
        self.* = .{};
    }
};

/// Legacy cursorline chrome decoded from `gui_cursorline`.
pub const Cursorline = struct {
    row: u16 = 0,
    bg: u24 = 0,
};

/// Legacy gutter separator decoded from `gui_gutter_sep`.
pub const GutterSeparator = struct {
    col: u16 = 0,
    color: u24 = 0,
};

/// Retained line spacing state decoded from `gui_line_spacing`.
pub const LineSpacing = struct {
    value: u16 = 100,
};

/// Retained cursor animation state decoded from `gui_cursor_animation`.
pub const CursorAnimation = struct {
    enabled: bool = true,
};

/// Retained config state payload decoded from `gui_config_state`.
pub const ConfigState = struct {
    payload: []u8 = &.{},

    pub fn deinit(self: *ConfigState, alloc: std.mem.Allocator) void {
        alloc.free(self.payload);
        self.* = .{};
    }
};

/// Retained hover action payload decoded from `gui_hover_action`.
pub const HoverAction = struct {
    visible: bool = false,
    name: []u8 = &.{},
    payload: []u8 = &.{},

    pub fn deinit(self: *HoverAction, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        alloc.free(self.payload);
        self.* = .{};
    }
};

/// Retained agent chat state decoded from `gui_agent_chat`.
pub const AgentChat = struct {
    visible: bool = false,
    status: u8 = 0,
    model_name: []u8 = &.{},
    prompt: []u8 = &.{},
    prompt_line_count: u8 = 0,
    prompt_cursor_line: u16 = 0,
    prompt_cursor_col: u16 = 0,
    prompt_vim_mode: u8 = 0,
    prompt_visible_rows: u8 = 0,
    pending: []u8 = &.{},
    completion: [][]u8 = &.{},
    thinking_level: []u8 = &.{},
    message_count: u16 = 0,
    messages: []AgentChatMessage = &.{},

    pub fn deinit(self: *AgentChat, alloc: std.mem.Allocator) void {
        alloc.free(self.model_name);
        alloc.free(self.prompt);
        alloc.free(self.pending);
        for (self.completion) |item| alloc.free(item);
        alloc.free(self.completion);
        alloc.free(self.thinking_level);
        for (self.messages) |*message| message.deinit(alloc);
        alloc.free(self.messages);
        self.* = .{};
    }
};

/// One retained transcript item decoded from `gui_agent_chat`.
pub const AgentChatMessage = struct {
    id: u32 = 0,
    kind: u8 = 0,
    text: []u8 = &.{},
    name: []u8 = &.{},
    summary: []u8 = &.{},
    result: []u8 = &.{},
    status: u8 = 0,
    is_error: bool = false,
    collapsed: bool = false,
    duration_ms: u32 = 0,
    auto_approved_scope: u8 = 0,
    usage_input: u32 = 0,
    usage_output: u32 = 0,
    usage_cache_read: u32 = 0,
    usage_cache_write: u32 = 0,
    usage_cost_micros: u32 = 0,
    preview_kind: u8 = 0,
    preview_lines: [][]u8 = &.{},

    pub fn deinit(self: *AgentChatMessage, alloc: std.mem.Allocator) void {
        alloc.free(self.text);
        alloc.free(self.name);
        alloc.free(self.summary);
        alloc.free(self.result);
        for (self.preview_lines) |line| alloc.free(line);
        alloc.free(self.preview_lines);
        self.* = .{};
    }
};

/// Retained semantic window content decoded from `gui_window_content`.
pub const WindowContent = struct {
    window_id: u16 = 0,
    flags: u8 = 0,
    // Whether this window owns the visible terminal cursor. The BEAM hides the
    // editor cursor when a minibuffer input mode (command/search/eval) is
    // active so the minibuffer can own the cursor instead. Defaults to true.
    cursor_visible: bool = true,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cursor_shape: u8 = 0,
    scroll_left: u16 = 0,
    content_epoch: u32 = 0,
    origin_row: u16 = 0,
    origin_col: u16 = 0,
    text_width: u16 = 0,
    text_height: u16 = 0,
    cursorline_visible: bool = false,
    cursorline_row: u16 = 0,
    cursorline_bg: u24 = 0,
    selection: WindowSelection = .{},
    search_matches: []SearchMatch = &.{},
    diagnostic_ranges: []DiagnosticRange = &.{},
    document_highlights: []DocumentHighlight = &.{},
    annotations: []LineAnnotation = &.{},
    rows: []WindowRow = &.{},

    pub fn deinit(self: *WindowContent, alloc: std.mem.Allocator) void {
        for (self.rows) |*row| row.deinit(alloc);
        alloc.free(self.rows);
        alloc.free(self.search_matches);
        alloc.free(self.diagnostic_ranges);
        alloc.free(self.document_highlights);
        for (self.annotations) |*annotation| annotation.deinit(alloc);
        alloc.free(self.annotations);
        self.* = .{};
    }
};

/// Retained status bar state decoded from `gui_status_bar`.
pub const StatusBar = struct {
    content_kind: u8 = 0,
    mode: u8 = 0,
    flags: u8 = 0,
    line: u32 = 0,
    col: u32 = 0,
    line_count: u32 = 0,
    branch: []u8 = &.{},
    icon: []u8 = &.{},
    filename: []u8 = &.{},
    filetype: []u8 = &.{},
    message: []u8 = &.{},
    left_segments: []StatusSegment = &.{},
    right_segments: []StatusSegment = &.{},

    pub fn deinit(self: *StatusBar, alloc: std.mem.Allocator) void {
        alloc.free(self.branch);
        alloc.free(self.icon);
        alloc.free(self.filename);
        alloc.free(self.filetype);
        alloc.free(self.message);
        for (self.left_segments) |*segment| segment.deinit(alloc);
        for (self.right_segments) |*segment| segment.deinit(alloc);
        alloc.free(self.left_segments);
        alloc.free(self.right_segments);
        self.* = .{};
    }
};
