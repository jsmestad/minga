use crate::protocol::{
    DecodeError,
    command_size::{self, CommandSize},
    opcodes, semantic_decode, semantic_types,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    WindowContent(WindowContent, usize),
    StatusBar(StatusBar, usize),
    TabBar(TabBar, usize),
    FileTree(FileTree, usize),
    FileTreeSelection(FileTreeSelection, usize),
    Picker(Picker, usize),
    PickerPreview(PickerPreview, usize),
    Minibuffer(Minibuffer, usize),
    Breadcrumb(Breadcrumb, usize),
    Completion(Completion, usize),
    WhichKey(WhichKey, usize),
    SignatureHelp(SignatureHelp, usize),
    FloatPopup(FloatPopup, usize),
    HoverPopup(HoverPopup, usize),
    BottomPanel(BottomPanel, usize),
    ChangeSummary(ChangeSummary, usize),
    GitStatus(GitStatus, usize),
    Theme(Theme, usize),
    Gutter(Gutter, usize),
    Cursorline(Cursorline, usize),
    GutterSeparator(GutterSeparator, usize),
    SplitSeparators(SplitSeparators, usize),
    IndentGuides(IndentGuides, usize),
    WindowOverlayDelta(WindowOverlayDelta, usize),
    ClipboardWrite(ClipboardWrite, usize),
    LineSpacing(LineSpacing, usize),
    CursorAnimation(CursorAnimation, usize),
    ConfigState(ConfigState, usize),
    AgentContext(AgentContext, usize),
    HoverAction(HoverAction, usize),
    SearchState(SearchState, usize),
    Workspaces(Workspaces, usize),
    Notifications(Notifications, usize),
    EditTimeline(EditTimeline, usize),
    ExtensionOverlay(ExtensionOverlay, usize),
    ExtensionPanel(ExtensionPanel, usize),
    Observatory(Observatory, usize),
    Sidebars(Sidebars, usize),
    Board(Board, usize),
    AgentChat(AgentChat, usize),
    ToolManager(ToolManager, usize),
}

impl Command {
    pub fn custom_size(&self) -> usize {
        match self {
            Self::WindowContent(_, size) => *size,
            Self::StatusBar(_, size) => *size,
            Self::TabBar(_, size) => *size,
            Self::FileTree(_, size) => *size,
            Self::FileTreeSelection(_, size) => *size,
            Self::Picker(_, size) => *size,
            Self::PickerPreview(_, size) => *size,
            Self::Minibuffer(_, size) => *size,
            Self::Breadcrumb(_, size) => *size,
            Self::Completion(_, size) => *size,
            Self::WhichKey(_, size) => *size,
            Self::SignatureHelp(_, size) => *size,
            Self::FloatPopup(_, size) => *size,
            Self::HoverPopup(_, size) => *size,
            Self::BottomPanel(_, size) => *size,
            Self::ChangeSummary(_, size) => *size,
            Self::GitStatus(_, size) => *size,
            Self::Theme(_, size) => *size,
            Self::Gutter(_, size) => *size,
            Self::Cursorline(_, size) => *size,
            Self::GutterSeparator(_, size) => *size,
            Self::SplitSeparators(_, size) => *size,
            Self::IndentGuides(_, size) => *size,
            Self::WindowOverlayDelta(_, size) => *size,
            Self::ClipboardWrite(_, size) => *size,
            Self::LineSpacing(_, size) => *size,
            Self::CursorAnimation(_, size) => *size,
            Self::ConfigState(_, size) => *size,
            Self::AgentContext(_, size) => *size,
            Self::HoverAction(_, size) => *size,
            Self::SearchState(_, size) => *size,
            Self::Workspaces(_, size) => *size,
            Self::Notifications(_, size) => *size,
            Self::EditTimeline(_, size) => *size,
            Self::ExtensionOverlay(_, size) => *size,
            Self::ExtensionPanel(_, size) => *size,
            Self::Observatory(_, size) => *size,
            Self::Sidebars(_, size) => *size,
            Self::Board(_, size) => *size,
            Self::AgentChat(_, size) => *size,
            Self::ToolManager(_, size) => *size,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowContent {
    pub window_id: u16,
    pub origin_row: u16,
    pub origin_col: u16,
    pub text_width: u16,
    pub text_height: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub cursor_shape: u8,
    pub content_epoch: u32,
    pub rows: Vec<Row>,
    pub cursorline: Option<Cursorline>,
}

pub type Row = semantic_types::Row;
#[allow(dead_code)]
pub type Span = semantic_types::Span;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StatusBar {
    pub mode: u8,
    pub flags: u8,
    pub line: u32,
    pub col: u32,
    pub line_count: u32,
    pub filename: String,
    pub filetype: String,
    pub branch: String,
    pub message: String,
    pub left_segments: Vec<StatusSegment>,
    pub right_segments: Vec<StatusSegment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusSegment {
    pub text: String,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabBar {
    pub active_index: u8,
    pub tabs: Vec<Tab>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tab {
    pub active: bool,
    pub dirty: bool,
    pub label: String,
    pub tint: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTree {
    pub visible: bool,
    pub focused: bool,
    pub status: u8,
    pub selected_id: String,
    pub root_path: String,
    pub width: u16,
    pub error: String,
    pub rows: Vec<FileTreeRow>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeRow {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub depth: u8,
    pub flags: u16,
    pub git_status: u8,
    pub diagnostics: (u16, u16, u16, u16),
    pub editing_text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeSelection {
    pub focused: bool,
    pub selected_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Picker {
    pub visible: bool,
    pub selected_index: u16,
    pub filtered_count: u16,
    pub total_count: u16,
    pub marked_count: u16,
    pub has_preview: bool,
    pub title: String,
    pub query: String,
    pub mode_prefix: String,
    pub load_status: u8,
    pub load_error: String,
    pub items: Vec<PickerItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PickerItem {
    pub label: String,
    pub description: String,
    pub annotation: String,
    pub icon_color: u32,
    pub marked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PickerPreview {
    pub visible: bool,
    pub lines: Vec<Vec<PreviewSegment>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreviewSegment {
    pub text: String,
    pub fg: u32,
    pub bold: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Minibuffer {
    pub visible: bool,
    pub mode: u8,
    pub cursor_pos: u16,
    pub prompt: String,
    pub input: String,
    pub context: String,
    pub selected_index: u16,
    pub total_candidates: u16,
    pub candidates: Vec<MinibufferCandidate>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinibufferCandidate {
    pub label: String,
    pub description: String,
    pub annotation: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Breadcrumb {
    pub segments: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Completion {
    pub visible: bool,
    pub anchor_row: u16,
    pub anchor_col: u16,
    pub selected_index: u16,
    pub items: Vec<CompletionItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompletionItem {
    pub kind: u8,
    pub label: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WhichKey {
    pub visible: bool,
    pub prefix: String,
    pub page: u8,
    pub page_count: u8,
    pub bindings: Vec<WhichKeyBinding>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WhichKeyBinding {
    pub kind: u8,
    pub key: String,
    pub description: String,
    pub icon: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SignatureHelp {
    pub visible: bool,
    pub anchor_row: u16,
    pub anchor_col: u16,
    pub active_signature: u8,
    pub active_parameter: u8,
    pub signatures: Vec<Signature>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Signature {
    pub label: String,
    pub documentation: String,
    pub parameters: Vec<SignatureParameter>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignatureParameter {
    pub label: String,
    pub documentation: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FloatPopup {
    pub visible: bool,
    pub width: u16,
    pub height: u16,
    pub title: String,
    pub lines: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HoverPopup {
    pub visible: bool,
    pub anchor_row: u16,
    pub anchor_col: u16,
    pub focused: bool,
    pub scroll_offset: u16,
    pub lines: Vec<HoverLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HoverLine {
    pub line_type: u8,
    pub segments: Vec<HoverSegment>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HoverSegment {
    pub style: u8,
    pub fg: u32,
    pub flags: u8,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BottomPanel {
    pub visible: bool,
    pub active_tab_index: u8,
    pub height_percent: u8,
    pub filter: u8,
    pub tabs: Vec<BottomPanelTab>,
    pub entries: Vec<BottomPanelEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BottomPanelTab {
    pub tab_type: u8,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BottomPanelEntry {
    pub id: u32,
    pub level: u8,
    pub subsystem: u8,
    pub timestamp_secs: u32,
    pub file_path: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChangeSummary {
    pub visible: bool,
    pub selected_index: u16,
    pub entries: Vec<ChangeSummaryEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeSummaryEntry {
    pub path: String,
    pub action: u8,
    pub lines_added: u32,
    pub lines_removed: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GitStatus {
    pub repo_state: u8,
    pub syncing: bool,
    pub ahead: u16,
    pub behind: u16,
    pub branch: String,
    pub entries: Vec<GitStatusEntry>,
    pub toast: Option<GitToast>,
    pub entry_base_path: String,
    pub last_commit_message: String,
    pub stash_count: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitStatusEntry {
    pub path_hash: u32,
    pub section: u8,
    pub status: u8,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitToast {
    pub level: u8,
    pub action: u8,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub slots: Vec<ThemeSlot>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThemeSlot {
    pub id: u8,
    pub rgb: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Gutter {
    pub window_id: u16,
    pub content_row: u16,
    pub content_col: u16,
    pub content_height: u16,
    pub is_active: bool,
    pub content_width: u16,
    pub cursor_line: u32,
    pub line_number_style: u8,
    pub line_number_width: u8,
    pub sign_col_width: u8,
    pub entries: Vec<GutterEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GutterEntry {
    pub buf_line: u32,
    pub display_type: u8,
    pub sign_type: u8,
    pub fold_end_line: u32,
    pub sign_fg: u32,
    pub sign_text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursorline {
    pub row: u16,
    pub bg: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GutterSeparator {
    pub col: u16,
    pub color: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SplitSeparators {
    pub color: u32,
    pub verticals: Vec<VerticalSeparator>,
    pub horizontals: Vec<HorizontalSeparator>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VerticalSeparator {
    pub col: u16,
    pub start_row: u16,
    pub end_row: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HorizontalSeparator {
    pub row: u16,
    pub col: u16,
    pub width: u16,
    pub filename: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct IndentGuides {
    pub window_id: u16,
    pub tab_width: u8,
    pub active_guide_col: u16,
    pub guide_cols: Vec<u16>,
    pub line_indent_levels: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowOverlayDelta {
    pub window_id: u16,
    pub content_epoch: u32,
    pub cursor_visible: bool,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub cursor_shape: u8,
    pub cursorline: Option<Cursorline>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardWrite {
    pub target: u8,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LineSpacing {
    pub value: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorAnimation {
    pub enabled: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigState {
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentContext {
    pub visible: u8,
    pub task: String,
    pub timestamp: u64,
    pub status: u8,
    pub can_approve: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HoverAction {
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchState {
    pub active: u8,
    pub match_count: u16,
    pub current_index: u16,
    pub flags: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Workspaces {
    pub visible: u8,
    pub active_workspace_id: u16,
    pub mode: u8,
    pub flags: u8,
    pub workspace_count: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Notifications {
    pub visible: u8,
    pub notification_count: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditTimeline {
    pub visible: u8,
    pub viewing_index: u16,
    pub entry_count: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExtensionOverlay {
    pub entry_count: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExtensionPanel {
    pub panel_count: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Observatory {
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sidebars {
    pub visible: u8,
    pub sidebar_count: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Board {
    pub visible: u8,
    pub focused_card_id: u32,
    pub card_count: u16,
    pub filter_mode: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AgentChat {
    pub visible: u8,
    pub flags: u8,
    pub message_count: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ToolManager {
    pub visible: u8,
}

pub fn decode(bytes: &[u8]) -> Result<Command, DecodeError> {
    let opcode = *bytes.first().ok_or(DecodeError::Empty)?;

    match opcode {
        opcodes::OP_GUI_WINDOW_CONTENT => decode_window_content(bytes),
        opcodes::OP_GUI_STATUS_BAR => decode_status_bar(bytes),
        opcodes::OP_GUI_TAB_BAR => decode_tab_bar(bytes),
        opcodes::OP_GUI_FILE_TREE => decode_file_tree(bytes),
        opcodes::OP_GUI_FILE_TREE_SELECTION => decode_file_tree_selection(bytes),
        opcodes::OP_GUI_PICKER => decode_picker(bytes),
        opcodes::OP_GUI_PICKER_PREVIEW => decode_picker_preview(bytes),
        opcodes::OP_GUI_MINIBUFFER => decode_minibuffer(bytes),
        opcodes::OP_GUI_BREADCRUMB => decode_breadcrumb(bytes),
        opcodes::OP_GUI_COMPLETION => decode_completion(bytes),
        opcodes::OP_GUI_WHICH_KEY => decode_which_key(bytes),
        opcodes::OP_GUI_SIGNATURE_HELP => decode_signature_help(bytes),
        opcodes::OP_GUI_FLOAT_POPUP => decode_float_popup(bytes),
        opcodes::OP_GUI_HOVER_POPUP => decode_hover_popup(bytes),
        opcodes::OP_GUI_BOTTOM_PANEL => decode_bottom_panel(bytes),
        opcodes::OP_GUI_CHANGE_SUMMARY => decode_change_summary(bytes),
        opcodes::OP_GUI_GIT_STATUS => decode_git_status(bytes),
        opcodes::OP_GUI_THEME => decode_theme(bytes),
        opcodes::OP_GUI_GUTTER => decode_gutter(bytes),
        opcodes::OP_GUI_CURSORLINE => decode_cursorline(bytes),
        opcodes::OP_GUI_GUTTER_SEP => decode_gutter_separator(bytes),
        opcodes::OP_GUI_SPLIT_SEPARATORS => decode_split_separators(bytes),
        opcodes::OP_GUI_INDENT_GUIDES => decode_indent_guides(bytes),
        opcodes::OP_GUI_WINDOW_OVERLAY_DELTA => decode_window_overlay_delta(bytes),
        opcodes::OP_GUI_WINDOW_VIEWPORT_DELTA
        | opcodes::OP_GUI_WINDOW_ROWS_DELTA => decode_window_content(bytes),
        opcodes::OP_CLIPBOARD_WRITE => decode_clipboard_write(bytes),
        opcodes::OP_GUI_LINE_SPACING => decode_line_spacing(bytes),
        opcodes::OP_GUI_CURSOR_ANIMATION => decode_cursor_animation(bytes),
        opcodes::OP_GUI_CONFIG_STATE => decode_config_state(bytes),
        opcodes::OP_GUI_AGENT_CONTEXT => decode_agent_context(bytes),
        opcodes::OP_GUI_HOVER_ACTION => decode_hover_action(bytes),
        opcodes::OP_GUI_SEARCH_STATE => decode_search_state(bytes),
        opcodes::OP_GUI_WORKSPACES => decode_workspaces(bytes),
        opcodes::OP_GUI_NOTIFICATIONS => decode_notifications(bytes),
        opcodes::OP_GUI_EDIT_TIMELINE => decode_edit_timeline(bytes),
        opcodes::OP_GUI_EXTENSION_OVERLAY => decode_extension_overlay(bytes),
        opcodes::OP_GUI_EXTENSION_PANEL => decode_extension_panel(bytes),
        opcodes::OP_GUI_OBSERVATORY => decode_observatory(bytes),
        opcodes::OP_GUI_SIDEBARS => decode_sidebars(bytes),
        opcodes::OP_GUI_BOARD => decode_board(bytes),
        opcodes::OP_GUI_AGENT_CHAT => decode_agent_chat(bytes),
        opcodes::OP_GUI_TOOL_MANAGER => decode_tool_manager(bytes),
        _ => Err(DecodeError::UnknownOpcode(opcode)),
    }
}

fn semantic_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    match command_size::command_size(bytes) {
        CommandSize::Sized(size) => Ok(size),
        CommandSize::Custom => custom_semantic_size(bytes),
        CommandSize::Incomplete => Err(DecodeError::Malformed("incomplete semantic command")),
        CommandSize::Unknown => match bytes.first() {
            Some(opcode) => Err(DecodeError::UnknownOpcode(*opcode)),
            None => Err(DecodeError::Empty),
        },
    }
}

fn decode_window_content(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let sections = sections(&bytes[..size])?;
    let mut window_id = 0;
    let mut cursor_row = 0;
    let mut cursor_col = 0;
    let mut cursor_shape = 0;
    let mut origin_row = 0;
    let mut origin_col = 0;
    let mut text_width = 0;
    let mut text_height = 0;
    let mut content_epoch = 0;
    let mut rows = Vec::new();
    let mut cursorline = None;

    for (section_id, payload) in sections {
        match section_id {
            0x01 => {
                let (header, _) = semantic_decode::decode_gui_window_content_header(payload, 0)?;
                window_id = header.window_id;
                cursor_row = header.cursor_row;
                cursor_col = header.cursor_col;
                cursor_shape = header.cursor_shape;
                content_epoch = header.content_epoch;
            }
            0x02 => rows = decode_rows(payload)?,
            0x08 => {
                let (geometry, _) =
                    semantic_decode::decode_gui_window_content_geometry(payload, 0)?;
                origin_row = geometry.text_rect.row;
                origin_col = geometry.text_rect.col;
                text_width = geometry.text_rect.width;
                text_height = geometry.text_rect.height;
            }
            0x09 => {
                let (cl, _) = semantic_decode::decode_gui_window_content_cursorline(payload, 0)?;
                cursorline = Some(Cursorline {
                    row: cl.row,
                    bg: cl.bg,
                });
            }
            _ => {}
        }
    }

    Ok(Command::WindowContent(
        WindowContent {
            window_id,
            origin_row,
            origin_col,
            text_width,
            text_height,
            cursor_row,
            cursor_col,
            cursor_shape,
            content_epoch,
            rows,
            cursorline: cursorline.map(|line| Cursorline {
                row: origin_row.saturating_add(line.row),
                bg: line.bg,
            }),
        },
        size,
    ))
}

fn decode_status_bar(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let sections = sections(&bytes[..size])?;
    let mut status = StatusBar::default();

    for (section_id, payload) in sections {
        match section_id {
            0x01 => {
                let (identity, _) = semantic_decode::decode_gui_status_bar_identity(payload, 0)?;
                status.mode = identity.mode;
                status.flags = identity.flags;
            }
            0x02 => {
                let (cursor, _) = semantic_decode::decode_gui_status_bar_cursor(payload, 0)?;
                status.line = cursor.line;
                status.col = cursor.col;
                status.line_count = cursor.line_count;
            }
            0x05 => {
                let (git, _) = semantic_decode::decode_gui_status_bar_git(payload, 0)?;
                status.branch = git.branch;
            }
            0x06 => {
                let (file, _) = semantic_decode::decode_gui_status_bar_file(payload, 0)?;
                status.filename = file.filename;
                status.filetype = file.filetype;
            }
            0x07 => {
                let (message, _) = semantic_decode::decode_gui_status_bar_message(payload, 0)?;
                status.message = message.text;
            }
            0x0B => status_segments(payload, &mut status)?,
            _ => {}
        }
    }

    Ok(Command::StatusBar(status, size))
}

fn status_segments(payload: &[u8], status: &mut StatusBar) -> Result<(), DecodeError> {
    require_len(payload, 5, "status modeline header")?;
    let left_count = read_u16(payload, 1) as usize;
    let right_count = read_u16(payload, 3) as usize;
    let mut offset = 5;

    for _ in 0..left_count {
        let (segment, used) = decode_status_segment(&payload[offset..])?;
        offset += used;
        status.left_segments.push(segment);
    }

    for _ in 0..right_count {
        let (segment, used) = decode_status_segment(&payload[offset..])?;
        offset += used;
        status.right_segments.push(segment);
    }

    Ok(())
}

fn decode_status_segment(bytes: &[u8]) -> Result<(StatusSegment, usize), DecodeError> {
    require_len(bytes, 1, "status segment name length")?;
    let name_len = bytes[0] as usize;
    let mut offset = 1 + name_len;
    require_len(bytes, offset + 8, "status segment colors")?;
    let fg = read_u24(bytes, offset);
    let bg = read_u24(bytes, offset + 3);
    let attrs = bytes[offset + 6] as u16;
    let text_len = read_u16(bytes, offset + 7) as usize;
    offset += 9;
    let text = read_string(bytes, offset, text_len)?;
    offset += text_len;
    require_len(bytes, offset + 2, "status segment target")?;
    let target_len = read_u16(bytes, offset) as usize;
    offset += 2 + target_len;
    require_len(bytes, offset, "status segment end")?;

    Ok((
        StatusSegment {
            text,
            fg,
            bg,
            attrs,
        },
        offset,
    ))
}

fn decode_tab_bar(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 3, "tab bar header")?;
    let active_index = bytes[1];
    let count = bytes[2] as usize;
    let mut offset = 3;
    let mut tabs = Vec::with_capacity(count);

    for _ in 0..count {
        let flags = bytes[offset];
        let icon_len = bytes[offset + 7] as usize;
        offset += 8 + icon_len;
        let label_len = read_u16(bytes, offset) as usize;
        offset += 2;
        let label = read_string(bytes, offset, label_len)?;
        offset += label_len;
        let tint = read_u32(bytes, offset);
        offset += 4;
        tabs.push(Tab {
            active: flags & 0x01 != 0,
            dirty: flags & 0x02 != 0,
            label,
            tint,
        });
    }

    Ok(Command::TabBar(TabBar { active_index, tabs }, size))
}

fn decode_file_tree(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let payload = &bytes[5..size];
    require_len(payload, 3, "file tree header")?;
    let flags = payload[1];
    let status = payload[2];
    let mut offset = 3;
    let selected_id = read_string16(payload, &mut offset)?;
    let root_path = read_string16(payload, &mut offset)?;
    require_len(payload, offset + 4, "file tree dimensions")?;
    let width = read_u16(payload, offset);
    let row_count = read_u16(payload, offset + 2) as usize;
    offset += 4;
    let error = read_string16(payload, &mut offset)?;
    let mut rows = Vec::with_capacity(row_count);

    for _ in 0..row_count {
        let (row, used) = decode_file_tree_row(&payload[offset..])?;
        offset += used;
        rows.push(row);
    }

    Ok(Command::FileTree(
        FileTree {
            visible: flags & 0x01 != 0,
            focused: flags & 0x02 != 0,
            status,
            selected_id,
            root_path,
            width,
            error,
            rows,
        },
        size,
    ))
}

fn decode_file_tree_selection(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let payload = &bytes[3..size];
    require_len(payload, 1, "file tree selection flags")?;
    let mut offset = 1;
    let selected_id = read_string16(payload, &mut offset)?;

    Ok(Command::FileTreeSelection(
        FileTreeSelection {
            focused: payload[0] & 0x01 != 0,
            selected_id,
        },
        size,
    ))
}

fn decode_picker(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "picker header")?;
    if bytes[1] == 0 {
        return Ok(Command::Picker(Picker::default(), 2));
    }

    let size = semantic_size(bytes)?;
    let sections = sections(&bytes[..size])?;
    let mut picker = Picker {
        visible: true,
        ..Picker::default()
    };

    for (section_id, payload) in sections {
        match section_id {
            0x01 => decode_picker_header(payload, &mut picker)?,
            0x02 => {
                let mut offset = 0;
                picker.query = read_string16(payload, &mut offset)?;
            }
            0x03 => picker.items = decode_picker_items(payload)?,
            0x05 => {
                let mut offset = 0;
                picker.mode_prefix = read_string16(payload, &mut offset)?;
            }
            0x06 => decode_picker_load_status(payload, &mut picker)?,
            _ => {}
        }
    }

    Ok(Command::Picker(picker, size))
}

fn decode_picker_header(payload: &[u8], picker: &mut Picker) -> Result<(), DecodeError> {
    require_len(payload, 10, "picker header section")?;
    picker.selected_index = read_u16(payload, 1);
    picker.filtered_count = read_u16(payload, 3);
    picker.total_count = read_u16(payload, 5);
    picker.has_preview = payload[7] != 0;
    let title_len = read_u16(payload, 8) as usize;
    picker.title = read_string(payload, 10, title_len)?;
    require_len(payload, 10 + title_len + 2, "picker marked count")?;
    picker.marked_count = read_u16(payload, 10 + title_len);
    Ok(())
}

fn decode_picker_items(payload: &[u8]) -> Result<Vec<PickerItem>, DecodeError> {
    require_len(payload, 2, "picker item count")?;
    let count = read_u16(payload, 0) as usize;
    let mut offset = 2;
    let mut items = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(payload, offset + 4, "picker item header")?;
        let icon_color = read_u24(payload, offset);
        let flags = payload[offset + 3];
        offset += 4;
        let label = read_string16(payload, &mut offset)?;
        let description = read_string16(payload, &mut offset)?;
        let annotation = read_string16(payload, &mut offset)?;
        require_len(payload, offset + 1, "picker match count")?;
        let match_count = payload[offset] as usize;
        offset += 1 + match_count * 2;
        require_len(payload, offset, "picker match positions")?;
        items.push(PickerItem {
            label,
            description,
            annotation,
            icon_color,
            marked: flags & 0x02 != 0,
        });
    }

    Ok(items)
}

fn decode_picker_load_status(payload: &[u8], picker: &mut Picker) -> Result<(), DecodeError> {
    require_len(payload, 1, "picker load status")?;
    picker.load_status = payload[0];
    if payload[0] == 2 {
        let mut offset = 1;
        picker.load_error = read_string16(payload, &mut offset)?;
    }
    Ok(())
}

fn decode_picker_preview(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "picker preview header")?;
    if bytes[1] == 0 {
        return Ok(Command::PickerPreview(PickerPreview::default(), 2));
    }

    require_len(bytes, 4, "picker preview visible header")?;
    let line_count = read_u16(bytes, 2) as usize;
    let mut offset = 4;
    let mut lines = Vec::with_capacity(line_count);

    for _ in 0..line_count {
        require_len(bytes, offset + 1, "picker preview segment count")?;
        let segment_count = bytes[offset] as usize;
        offset += 1;
        let mut segments = Vec::with_capacity(segment_count);

        for _ in 0..segment_count {
            require_len(bytes, offset + 6, "picker preview segment")?;
            let fg = read_u24(bytes, offset);
            let bold = bytes[offset + 3] & 0x01 != 0;
            let len = read_u16(bytes, offset + 4) as usize;
            offset += 6;
            let text = read_string(bytes, offset, len)?;
            offset += len;
            segments.push(PreviewSegment { text, fg, bold });
        }

        lines.push(segments);
    }

    Ok(Command::PickerPreview(
        PickerPreview {
            visible: true,
            lines,
        },
        offset,
    ))
}

fn decode_minibuffer(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "minibuffer header")?;
    if bytes[1] == 0 {
        return Ok(Command::Minibuffer(Minibuffer::default(), 2));
    }

    require_len(bytes, 8, "minibuffer visible header")?;
    let mut offset = 2;
    let mode = bytes[offset];
    offset += 1;
    let cursor_pos = read_u16(bytes, offset);
    offset += 2;
    let prompt = read_string8(bytes, &mut offset)?;
    let input = read_string16(bytes, &mut offset)?;
    let context = read_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 6, "minibuffer candidate header")?;
    let selected_index = read_u16(bytes, offset);
    let candidate_count = read_u16(bytes, offset + 2) as usize;
    let total_candidates = read_u16(bytes, offset + 4);
    offset += 6;
    let mut candidates = Vec::with_capacity(candidate_count);

    for _ in 0..candidate_count {
        let (candidate, used) = decode_minibuffer_candidate(&bytes[offset..])?;
        offset += used;
        candidates.push(candidate);
    }

    Ok(Command::Minibuffer(
        Minibuffer {
            visible: true,
            mode,
            cursor_pos,
            prompt,
            input,
            context,
            selected_index,
            total_candidates,
            candidates,
        },
        offset,
    ))
}

fn decode_minibuffer_candidate(bytes: &[u8]) -> Result<(MinibufferCandidate, usize), DecodeError> {
    require_len(bytes, 1, "minibuffer candidate score")?;
    let mut offset = 1;
    let label = read_string16(bytes, &mut offset)?;
    let description = read_string16(bytes, &mut offset)?;
    let annotation = read_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 1, "minibuffer candidate match count")?;
    let match_count = bytes[offset] as usize;
    offset += 1 + match_count * 2;
    require_len(bytes, offset, "minibuffer candidate matches")?;

    Ok((
        MinibufferCandidate {
            label,
            description,
            annotation,
        },
        offset,
    ))
}

fn decode_breadcrumb(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let count = bytes[1] as usize;
    let mut offset = 2;
    let mut segments = Vec::with_capacity(count);

    for _ in 0..count {
        segments.push(read_string16(bytes, &mut offset)?);
    }

    Ok(Command::Breadcrumb(Breadcrumb { segments }, size))
}

fn decode_completion(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "completion header")?;
    if bytes[1] == 0 {
        return Ok(Command::Completion(Completion::default(), 2));
    }

    let size = semantic_size(bytes)?;
    let anchor_row = read_u16(bytes, 2);
    let anchor_col = read_u16(bytes, 4);
    let selected_index = read_u16(bytes, 6);
    let count = read_u16(bytes, 8) as usize;
    let mut offset = 10;
    let mut items = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(bytes, offset + 1, "completion item kind")?;
        let kind = bytes[offset];
        offset += 1;
        let label = read_string16(bytes, &mut offset)?;
        let detail = read_string16(bytes, &mut offset)?;
        items.push(CompletionItem {
            kind,
            label,
            detail,
        });
    }

    Ok(Command::Completion(
        Completion {
            visible: true,
            anchor_row,
            anchor_col,
            selected_index,
            items,
        },
        size,
    ))
}

fn decode_which_key(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "which-key header")?;
    if bytes[1] == 0 {
        return Ok(Command::WhichKey(WhichKey::default(), 2));
    }

    let size = semantic_size(bytes)?;
    let mut offset = 2;
    let prefix = read_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 4, "which-key metadata")?;
    let page = bytes[offset];
    let page_count = bytes[offset + 1];
    let count = read_u16(bytes, offset + 2) as usize;
    offset += 4;
    let mut bindings = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(bytes, offset + 2, "which-key binding header")?;
        let kind = bytes[offset];
        offset += 1;
        let key = read_string8(bytes, &mut offset)?;
        let description = read_string16(bytes, &mut offset)?;
        let icon = read_string8(bytes, &mut offset)?;
        bindings.push(WhichKeyBinding {
            kind,
            key,
            description,
            icon,
        });
    }

    Ok(Command::WhichKey(
        WhichKey {
            visible: true,
            prefix,
            page,
            page_count,
            bindings,
        },
        size,
    ))
}

fn decode_signature_help(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "signature help header")?;
    if bytes[1] == 0 {
        return Ok(Command::SignatureHelp(SignatureHelp::default(), 2));
    }

    let size = semantic_size(bytes)?;
    let anchor_row = read_u16(bytes, 2);
    let anchor_col = read_u16(bytes, 4);
    let active_signature = bytes[6];
    let active_parameter = bytes[7];
    let count = bytes[8] as usize;
    let mut offset = 9;
    let mut signatures = Vec::with_capacity(count);

    for _ in 0..count {
        let label = read_string16(bytes, &mut offset)?;
        let documentation = read_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 1, "signature parameter count")?;
        let parameter_count = bytes[offset] as usize;
        offset += 1;
        let mut parameters = Vec::with_capacity(parameter_count);
        for _ in 0..parameter_count {
            parameters.push(SignatureParameter {
                label: read_string16(bytes, &mut offset)?,
                documentation: read_string16(bytes, &mut offset)?,
            });
        }
        signatures.push(Signature {
            label,
            documentation,
            parameters,
        });
    }

    Ok(Command::SignatureHelp(
        SignatureHelp {
            visible: true,
            anchor_row,
            anchor_col,
            active_signature,
            active_parameter,
            signatures,
        },
        size,
    ))
}

fn decode_float_popup(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "float popup header")?;
    if bytes[1] == 0 {
        return Ok(Command::FloatPopup(FloatPopup::default(), 2));
    }

    let size = semantic_size(bytes)?;
    let width = read_u16(bytes, 2);
    let height = read_u16(bytes, 4);
    let mut offset = 6;
    let title = read_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 2, "float popup line count")?;
    let count = read_u16(bytes, offset) as usize;
    offset += 2;
    let mut lines = Vec::with_capacity(count);

    for _ in 0..count {
        lines.push(read_string16(bytes, &mut offset)?);
    }

    Ok(Command::FloatPopup(
        FloatPopup {
            visible: true,
            width,
            height,
            title,
            lines,
        },
        size,
    ))
}

fn decode_hover_popup(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "hover popup header")?;
    if bytes[1] == 0 {
        return Ok(Command::HoverPopup(HoverPopup::default(), 2));
    }

    let size = semantic_size(bytes)?;
    let anchor_row = read_u16(bytes, 2);
    let anchor_col = read_u16(bytes, 4);
    let focused = bytes[6] != 0;
    let scroll_offset = read_u16(bytes, 7);
    let count = read_u16(bytes, 9) as usize;
    let mut offset = 11;
    let mut lines = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(bytes, offset + 3, "hover line")?;
        let line_type = bytes[offset];
        let segment_count = read_u16(bytes, offset + 1) as usize;
        offset += 3;
        let mut segments = Vec::with_capacity(segment_count);
        for _ in 0..segment_count {
            require_len(bytes, offset + 1, "hover segment style")?;
            let style = bytes[offset];
            offset += 1;
            let (fg, flags, text) = if style == 13 {
                require_len(bytes, offset + 6, "hover syntax segment")?;
                let fg = read_u24(bytes, offset);
                let flags = bytes[offset + 3];
                let len = read_u16(bytes, offset + 4) as usize;
                offset += 6;
                let text = read_string(bytes, offset, len)?;
                offset += len;
                (fg, flags, text)
            } else {
                require_len(bytes, offset + 2, "hover segment")?;
                let len = read_u16(bytes, offset) as usize;
                offset += 2;
                let text = read_string(bytes, offset, len)?;
                offset += len;
                (0, 0, text)
            };
            segments.push(HoverSegment {
                style,
                fg,
                flags,
                text,
            });
        }
        lines.push(HoverLine {
            line_type,
            segments,
        });
    }

    Ok(Command::HoverPopup(
        HoverPopup {
            visible: true,
            anchor_row,
            anchor_col,
            focused,
            scroll_offset,
            lines,
        },
        size,
    ))
}

fn decode_bottom_panel(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "bottom panel header")?;
    if bytes[1] == 0 {
        return Ok(Command::BottomPanel(BottomPanel::default(), 2));
    }

    let size = semantic_size(bytes)?;
    require_len(bytes, 6, "bottom panel visible header")?;
    let active_tab_index = bytes[2];
    let height_percent = bytes[3];
    let filter = bytes[4];
    let tab_count = bytes[5] as usize;
    let mut offset = 6;
    let mut tabs = Vec::with_capacity(tab_count);

    for _ in 0..tab_count {
        require_len(bytes, offset + 1, "bottom panel tab type")?;
        let tab_type = bytes[offset];
        offset += 1;
        let name = read_string8(bytes, &mut offset)?;
        tabs.push(BottomPanelTab { tab_type, name });
    }

    require_len(bytes, offset + 2, "bottom panel entry count")?;
    let entry_count = read_u16(bytes, offset) as usize;
    offset += 2;
    let mut entries = Vec::with_capacity(entry_count);

    for _ in 0..entry_count {
        require_len(bytes, offset + 10, "bottom panel entry")?;
        let id = read_u32(bytes, offset);
        let level = bytes[offset + 4];
        let subsystem = bytes[offset + 5];
        let timestamp_secs = read_u32(bytes, offset + 6);
        offset += 10;
        let file_path = read_string16(bytes, &mut offset)?;
        let text = read_string16(bytes, &mut offset)?;
        entries.push(BottomPanelEntry {
            id,
            level,
            subsystem,
            timestamp_secs,
            file_path,
            text,
        });
    }

    Ok(Command::BottomPanel(
        BottomPanel {
            visible: true,
            active_tab_index,
            height_percent,
            filter,
            tabs,
            entries,
        },
        size,
    ))
}

fn decode_change_summary(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 5, "change summary header")?;
    let visible = bytes[1] != 0;
    let selected_index = read_u16(bytes, 2);
    let count = read_u16(bytes, 4) as usize;
    let mut offset = 6;
    let mut entries = Vec::with_capacity(count);

    for _ in 0..count {
        let path = read_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 9, "change summary entry")?;
        let action = bytes[offset];
        let lines_added = read_u32(bytes, offset + 1);
        let lines_removed = read_u32(bytes, offset + 5);
        offset += 9;
        entries.push(ChangeSummaryEntry {
            path,
            action,
            lines_added,
            lines_removed,
        });
    }

    Ok(Command::ChangeSummary(
        ChangeSummary {
            visible,
            selected_index,
            entries,
        },
        size,
    ))
}

fn decode_git_status(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 9, "git status header")?;
    let repo_state = bytes[1];
    let syncing = bytes[2] != 0;
    let ahead = read_u16(bytes, 3);
    let behind = read_u16(bytes, 5);
    let mut offset = 7;
    let branch = read_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 2, "git status entry count")?;
    let count = read_u16(bytes, offset) as usize;
    offset += 2;
    let mut entries = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(bytes, offset + 6, "git status entry")?;
        let path_hash = read_u32(bytes, offset);
        let section = bytes[offset + 4];
        let status = bytes[offset + 5];
        offset += 6;
        let path = read_string16(bytes, &mut offset)?;
        entries.push(GitStatusEntry {
            path_hash,
            section,
            status,
            path,
        });
    }

    require_len(bytes, offset + 1, "git toast visibility")?;
    let toast = if bytes[offset] == 0 {
        offset += 1;
        None
    } else {
        require_len(bytes, offset + 5, "git toast")?;
        let level = bytes[offset + 1];
        let action = bytes[offset + 2];
        let len = read_u16(bytes, offset + 3) as usize;
        offset += 5;
        let message = read_string(bytes, offset, len)?;
        offset += len;
        Some(GitToast {
            level,
            action,
            message,
        })
    };

    let entry_base_path = read_string16(bytes, &mut offset)?;
    let last_commit_message = read_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 2, "git stash count")?;
    let stash_count = read_u16(bytes, offset);

    Ok(Command::GitStatus(
        GitStatus {
            repo_state,
            syncing,
            ahead,
            behind,
            branch,
            entries,
            toast,
            entry_base_path,
            last_commit_message,
            stash_count,
        },
        size,
    ))
}

fn decode_theme(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let count = bytes[1] as usize;
    let mut slots = Vec::with_capacity(count);
    let mut offset = 2;

    for _ in 0..count {
        slots.push(ThemeSlot {
            id: bytes[offset],
            rgb: read_u24(bytes, offset + 1),
        });
        offset += 4;
    }

    Ok(Command::Theme(Theme { slots }, size))
}

fn decode_gutter(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    let sections = sections(&bytes[..size])?;
    let mut gutter = Gutter::default();

    for (section_id, payload) in sections {
        match section_id {
            0x01 => {
                let (window, _) = semantic_decode::decode_gui_gutter_window(payload, 0)?;
                gutter.window_id = window.window_id;
                gutter.content_row = window.content_row;
                gutter.content_col = window.content_col;
                gutter.content_height = window.content_height;
                gutter.is_active = window.is_active != 0;
                gutter.content_width = window.content_width;
            }
            0x02 => {
                let (config, _) = semantic_decode::decode_gui_gutter_config(payload, 0)?;
                gutter.cursor_line = config.cursor_line;
                gutter.line_number_style = config.line_number_style;
                gutter.line_number_width = config.line_number_width;
                gutter.sign_col_width = config.sign_col_width;
            }
            0x03 => gutter.entries = decode_gutter_entries(payload)?,
            _ => {}
        }
    }

    Ok(Command::Gutter(gutter, size))
}

fn decode_gutter_entries(bytes: &[u8]) -> Result<Vec<GutterEntry>, DecodeError> {
    require_len(bytes, 2, "gutter entry count")?;
    let count = read_u16(bytes, 0) as usize;
    let mut offset = 2;
    let mut entries = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(bytes, offset + 10, "gutter entry")?;
        let buf_line = read_u32(bytes, offset);
        let display_type = bytes[offset + 4];
        let sign_type = bytes[offset + 5];
        let fold_end_line = read_u32(bytes, offset + 6);
        offset += 10;
        let (sign_fg, sign_text) = if sign_type == 8 {
            require_len(bytes, offset + 4, "gutter annotation")?;
            let fg = read_u24(bytes, offset);
            let len = bytes[offset + 3] as usize;
            offset += 4;
            let text = read_string(bytes, offset, len)?;
            offset += len;
            (fg, text)
        } else {
            (0, String::new())
        };

        entries.push(GutterEntry {
            buf_line,
            display_type,
            sign_type,
            fold_end_line,
            sign_fg,
            sign_text,
        });
    }

    Ok(entries)
}

fn decode_cursorline(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 6, "cursorline")?;
    Ok(Command::Cursorline(
        Cursorline {
            row: read_u16(bytes, 1),
            bg: read_u24(bytes, 3),
        },
        size,
    ))
}

fn decode_cursorline_payload(payload: &[u8]) -> Result<Cursorline, DecodeError> {
    require_len(payload, 5, "cursorline payload")?;
    Ok(Cursorline {
        row: read_u16(payload, 0),
        bg: read_u24(payload, 2),
    })
}

fn decode_gutter_separator(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 6, "gutter separator")?;
    Ok(Command::GutterSeparator(
        GutterSeparator {
            col: read_u16(bytes, 1),
            color: read_u24(bytes, 3),
        },
        size,
    ))
}

fn decode_split_separators(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 5, "split separators")?;
    let color = read_u24(bytes, 1);
    let vertical_count = bytes[4] as usize;
    let mut offset = 5;
    let mut verticals = Vec::with_capacity(vertical_count);

    for _ in 0..vertical_count {
        require_len(bytes, offset + 6, "split vertical")?;
        verticals.push(VerticalSeparator {
            col: read_u16(bytes, offset),
            start_row: read_u16(bytes, offset + 2),
            end_row: read_u16(bytes, offset + 4),
        });
        offset += 6;
    }

    require_len(bytes, offset + 1, "split horizontal count")?;
    let horizontal_count = bytes[offset] as usize;
    offset += 1;
    let mut horizontals = Vec::with_capacity(horizontal_count);

    for _ in 0..horizontal_count {
        require_len(bytes, offset + 8, "split horizontal")?;
        let row = read_u16(bytes, offset);
        let col = read_u16(bytes, offset + 2);
        let width = read_u16(bytes, offset + 4);
        let len = read_u16(bytes, offset + 6) as usize;
        offset += 8;
        let filename = read_string(bytes, offset, len)?;
        offset += len;
        horizontals.push(HorizontalSeparator {
            row,
            col,
            width,
            filename,
        });
    }

    Ok(Command::SplitSeparators(
        SplitSeparators {
            color,
            verticals,
            horizontals,
        },
        size,
    ))
}

fn decode_indent_guides(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 8, "indent guides")?;
    let payload_len = read_u16(bytes, 1) as usize;
    require_len(bytes, 3 + payload_len, "indent guides payload")?;
    let mut offset = 3;
    let window_id = read_u16(bytes, offset);
    let tab_width = bytes[offset + 2];
    let active_guide_col = read_u16(bytes, offset + 3);
    let guide_count = bytes[offset + 5] as usize;
    offset += 6;
    if guide_count == 0 && payload_len == 6 {
        return Ok(Command::IndentGuides(
            IndentGuides {
                window_id,
                tab_width,
                active_guide_col,
                guide_cols: Vec::new(),
                line_indent_levels: Vec::new(),
            },
            size,
        ));
    }

    require_len(bytes, offset + guide_count * 2 + 2, "indent guide columns")?;
    let mut guide_cols = Vec::with_capacity(guide_count);
    for _ in 0..guide_count {
        guide_cols.push(read_u16(bytes, offset));
        offset += 2;
    }
    let line_count = read_u16(bytes, offset) as usize;
    offset += 2;
    require_len(bytes, offset + line_count, "indent guide line levels")?;
    let line_indent_levels = bytes[offset..offset + line_count].to_vec();

    Ok(Command::IndentGuides(
        IndentGuides {
            window_id,
            tab_width,
            active_guide_col,
            guide_cols,
            line_indent_levels,
        },
        size,
    ))
}

fn decode_window_overlay_delta(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = semantic_size(bytes)?;
    require_len(bytes, 13, "window overlay delta")?;
    let flags = bytes[7];
    let cursorline = if flags & 0x02 != 0 {
        Some(decode_cursorline_payload(&bytes[13..size])?)
    } else {
        None
    };

    Ok(Command::WindowOverlayDelta(
        WindowOverlayDelta {
            window_id: read_u16(bytes, 1),
            content_epoch: read_u32(bytes, 3),
            cursor_visible: flags & 0x01 != 0,
            cursor_row: read_u16(bytes, 8),
            cursor_col: read_u16(bytes, 10),
            cursor_shape: bytes[12],
            cursorline,
        },
        size,
    ))
}

fn len16_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 3, "len16 header")?;
    Ok(3 + ((bytes[1] as usize) << 8 | bytes[2] as usize))
}

fn len32_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 5, "len32 header")?;
    Ok(5 + u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize)
}

fn decode_clipboard_write(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 4, "clipboard write target")?;
    let target = bytes[3];
    let text = read_string(bytes, 4, size - 4)?;
    Ok(Command::ClipboardWrite(ClipboardWrite { target, text }, size))
}

fn decode_line_spacing(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 5, "line spacing value")?;
    let value = read_u16(bytes, 3);
    Ok(Command::LineSpacing(LineSpacing { value }, size))
}

fn decode_cursor_animation(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 4, "cursor animation")?;
    let enabled = bytes[3];
    Ok(Command::CursorAnimation(CursorAnimation { enabled }, size))
}

fn decode_config_state(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    let payload = bytes[3..size].to_vec();
    Ok(Command::ConfigState(ConfigState { payload }, size))
}

fn decode_agent_context(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = agent_context_size(bytes)?;
    require_len(bytes, 2, "agent context visible")?;
    let visible = bytes[1];
    if visible == 0 {
        return Ok(Command::AgentContext(
            AgentContext {
                visible: 0,
                task: String::new(),
                timestamp: 0,
                status: 0,
                can_approve: 0,
            },
            size,
        ));
    }
    require_len(bytes, 4, "agent context task length")?;
    let task_len = read_u16(bytes, 2) as usize;
    let task = read_string(bytes, 4, task_len)?;
    let body_offset = 4 + task_len;
    require_len(bytes, body_offset + 10, "agent context body")?;
    let timestamp = u64::from_be_bytes([
        bytes[body_offset],
        bytes[body_offset + 1],
        bytes[body_offset + 2],
        bytes[body_offset + 3],
        bytes[body_offset + 4],
        bytes[body_offset + 5],
        bytes[body_offset + 6],
        bytes[body_offset + 7],
    ]);
    let status = bytes[body_offset + 8];
    let can_approve = bytes[body_offset + 9];
    Ok(Command::AgentContext(
        AgentContext {
            visible,
            task,
            timestamp,
            status,
            can_approve,
        },
        size,
    ))
}

fn decode_hover_action(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    let payload = bytes[3..size].to_vec();
    Ok(Command::HoverAction(HoverAction { payload }, size))
}

fn decode_search_state(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 9, "search state fields")?;
    let active = bytes[3];
    let match_count = read_u16(bytes, 4);
    let current_index = read_u16(bytes, 6);
    let flags = bytes[8];
    Ok(Command::SearchState(
        SearchState {
            active,
            match_count,
            current_index,
            flags,
        },
        size,
    ))
}

fn decode_workspaces(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 8, "workspaces fields")?;
    Ok(Command::Workspaces(
        Workspaces {
            visible: bytes[3],
            active_workspace_id: read_u16(bytes, 4),
            mode: bytes[6],
            flags: bytes[7],
            workspace_count: if size > 8 { bytes[8] } else { 0 },
        },
        size,
    ))
}

fn decode_notifications(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 6, "notifications fields")?;
    Ok(Command::Notifications(
        Notifications {
            visible: bytes[3],
            notification_count: read_u16(bytes, 4),
        },
        size,
    ))
}

fn decode_edit_timeline(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 7, "edit timeline fields")?;
    Ok(Command::EditTimeline(
        EditTimeline {
            visible: bytes[3],
            viewing_index: read_u16(bytes, 4),
            entry_count: bytes[6],
        },
        size,
    ))
}

fn decode_extension_overlay(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 4, "extension overlay fields")?;
    Ok(Command::ExtensionOverlay(
        ExtensionOverlay {
            entry_count: bytes[3],
        },
        size,
    ))
}

fn decode_extension_panel(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len16_size(bytes)?;
    require_len(bytes, 4, "extension panel fields")?;
    Ok(Command::ExtensionPanel(
        ExtensionPanel {
            panel_count: bytes[3],
        },
        size,
    ))
}

fn decode_observatory(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len32_size(bytes)?;
    let payload = bytes[5..size].to_vec();
    Ok(Command::Observatory(Observatory { payload }, size))
}

fn decode_sidebars(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = len32_size(bytes)?;
    require_len(bytes, 8, "sidebars fields")?;
    Ok(Command::Sidebars(
        Sidebars {
            visible: bytes[5],
            sidebar_count: read_u16(bytes, 6),
        },
        size,
    ))
}

fn decode_board(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = board_size(bytes)?;
    require_len(bytes, 2, "board visible")?;
    if bytes[1] == 0 {
        return Ok(Command::Board(
            Board {
                visible: 0,
                focused_card_id: 0,
                card_count: 0,
                filter_mode: 0,
            },
            size,
        ));
    }
    require_len(bytes, 9, "board fields")?;
    Ok(Command::Board(
        Board {
            visible: bytes[1],
            focused_card_id: read_u32(bytes, 2),
            card_count: read_u16(bytes, 6),
            filter_mode: bytes[8],
        },
        size,
    ))
}

fn decode_agent_chat(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = sectioned_size(bytes, "agent chat")?;
    require_len(bytes, 2, "agent chat header")?;
    let section_count = bytes[1] as usize;
    let visible = if section_count > 0 { 1 } else { 0 };
    Ok(Command::AgentChat(
        AgentChat {
            visible,
            flags: 0,
            message_count: 0,
        },
        size,
    ))
}

fn decode_tool_manager(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = tool_manager_size(bytes)?;
    require_len(bytes, 2, "tool manager visible")?;
    Ok(Command::ToolManager(
        ToolManager {
            visible: bytes[1],
        },
        size,
    ))
}

fn decode_file_tree_row(bytes: &[u8]) -> Result<(FileTreeRow, usize), DecodeError> {
    require_len(bytes, 17, "file tree row header")?;
    let flags = read_u16(bytes, 4);
    let depth = bytes[6];
    let git_status = bytes[7];
    let diagnostics = (
        read_u16(bytes, 8),
        read_u16(bytes, 10),
        read_u16(bytes, 12),
        read_u16(bytes, 14),
    );
    let guide_count = bytes[16] as usize;
    let mut offset = 17 + guide_count;
    require_len(bytes, offset, "file tree guides")?;
    let id = read_string16(bytes, &mut offset)?;
    let _path = read_string16(bytes, &mut offset)?;
    let _relative = read_string16(bytes, &mut offset)?;
    let name = read_string16(bytes, &mut offset)?;
    let icon = read_string8(bytes, &mut offset)?;
    require_len(bytes, offset + 1, "file tree editing type")?;
    offset += 1;
    let editing_text = read_string16(bytes, &mut offset)?;

    Ok((
        FileTreeRow {
            id,
            name,
            icon,
            depth,
            flags,
            git_status,
            diagnostics,
            editing_text,
        },
        offset,
    ))
}

fn decode_rows(bytes: &[u8]) -> Result<Vec<Row>, DecodeError> {
    let (rows, _consumed) = semantic_decode::decode_gui_window_content_rows(bytes, 0)?;
    Ok(rows)
}

fn sections(bytes: &[u8]) -> Result<Vec<(u8, &[u8])>, DecodeError> {
    require_len(bytes, 2, "sectioned command header")?;
    let count = bytes[1] as usize;
    let mut offset = 2;
    let mut sections = Vec::with_capacity(count);

    for _ in 0..count {
        require_len(bytes, offset + 3, "section header")?;
        let section_id = bytes[offset];
        let len = read_u16(bytes, offset + 1) as usize;
        offset += 3;
        require_len(bytes, offset + len, "section payload")?;
        sections.push((section_id, &bytes[offset..offset + len]));
        offset += len;
    }

    Ok(sections)
}

fn custom_semantic_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    let opcode = *bytes.first().ok_or(DecodeError::Empty)?;

    match opcode {
        opcodes::OP_GUI_TAB_BAR => tab_bar_size(bytes),
        opcodes::OP_GUI_WHICH_KEY => which_key_size(bytes),
        opcodes::OP_GUI_COMPLETION => completion_size(bytes),
        opcodes::OP_GUI_THEME => theme_size(bytes),
        opcodes::OP_GUI_BREADCRUMB => breadcrumb_size(bytes),
        opcodes::OP_GUI_PICKER => sectioned_size(bytes, "picker"),
        opcodes::OP_GUI_AGENT_CHAT => sectioned_size(bytes, "agent chat"),
        opcodes::OP_GUI_BOTTOM_PANEL => bottom_panel_size(bytes),
        opcodes::OP_GUI_PICKER_PREVIEW => sectioned_size(bytes, "picker preview"),
        opcodes::OP_GUI_MINIBUFFER => sectioned_size(bytes, "minibuffer"),
        opcodes::OP_GUI_HOVER_POPUP => hover_popup_size(bytes),
        opcodes::OP_GUI_SIGNATURE_HELP => signature_help_size(bytes),
        opcodes::OP_GUI_FLOAT_POPUP => float_popup_size(bytes),
        opcodes::OP_GUI_SPLIT_SEPARATORS => split_separators_size(bytes),
        opcodes::OP_GUI_GIT_STATUS => git_status_size(bytes),
        opcodes::OP_GUI_BOARD => board_size(bytes),
        opcodes::OP_GUI_AGENT_CONTEXT => agent_context_size(bytes),
        opcodes::OP_GUI_CHANGE_SUMMARY => change_summary_size(bytes),
        opcodes::OP_GUI_TOOL_MANAGER => tool_manager_size(bytes),
        opcodes::OP_GUI_WINDOW_OVERLAY_DELTA => overlay_delta_size(bytes),
        _ => Err(DecodeError::UnknownOpcode(opcode)),
    }
}

fn sectioned_size(bytes: &[u8], name: &'static str) -> Result<usize, DecodeError> {
    require_len(bytes, 2, name)?;
    let count = bytes[1] as usize;
    let mut offset = 2;

    for _ in 0..count {
        require_len(bytes, offset + 3, name)?;
        let len = read_u16(bytes, offset + 1) as usize;
        offset += 3;
        require_len(bytes, offset + len, name)?;
        offset += len;
    }

    Ok(offset)
}

fn overlay_delta_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 13, "window overlay delta")?;
    let flags = bytes[7];
    let mut offset = 13;

    if flags & 0x02 != 0 {
        require_len(bytes, offset + 5, "cursorline data")?;
        offset += 5;
    }

    Ok(offset)
}

fn fixed_size(bytes: &[u8], size: usize, name: &'static str) -> Result<usize, DecodeError> {
    require_len(bytes, size, name)?;
    Ok(size)
}

fn theme_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "theme")?;
    let count = bytes[1] as usize;
    fixed_size(bytes, 2 + count * 4, "theme")
}

fn tab_bar_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 3, "tab bar")?;
    let count = bytes[2] as usize;
    let mut offset = 3;

    for _ in 0..count {
        require_len(bytes, offset + 8, "tab entry header")?;
        let icon_len = bytes[offset + 7] as usize;
        offset += 8;
        require_len(bytes, offset + icon_len + 2, "tab entry icon")?;
        offset += icon_len;
        let label_len = read_u16(bytes, offset) as usize;
        offset += 2;
        require_len(bytes, offset + label_len + 4, "tab entry label")?;
        offset += label_len + 4;
    }

    Ok(offset)
}

fn split_separators_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 5, "split separators")?;
    let vertical_count = bytes[4] as usize;
    let mut offset = 5 + vertical_count * 6;
    require_len(bytes, offset + 1, "split horizontal count")?;
    let horizontal_count = bytes[offset] as usize;
    offset += 1;

    for _ in 0..horizontal_count {
        require_len(bytes, offset + 8, "split horizontal header")?;
        let label_len = read_u16(bytes, offset + 6) as usize;
        offset += 8;
        require_len(bytes, offset + label_len, "split horizontal label")?;
        offset += label_len;
    }

    Ok(offset)
}

fn breadcrumb_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "breadcrumb")?;
    let count = bytes[1] as usize;
    let mut offset = 2;
    for _ in 0..count {
        skip_string16(bytes, &mut offset)?;
    }
    Ok(offset)
}

fn which_key_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "which-key")?;
    if bytes[1] == 0 {
        return Ok(2);
    }

    let mut offset = 2;
    skip_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 4, "which-key metadata")?;
    let count = read_u16(bytes, offset + 2) as usize;
    offset += 4;
    for _ in 0..count {
        require_len(bytes, offset + 1, "which-key binding kind")?;
        offset += 1;
        skip_string8(bytes, &mut offset)?;
        skip_string16(bytes, &mut offset)?;
        skip_string8(bytes, &mut offset)?;
    }
    Ok(offset)
}

fn completion_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 10, "completion")?;
    let count = read_u16(bytes, 8) as usize;
    let mut offset = 10;
    for _ in 0..count {
        require_len(bytes, offset + 1, "completion item kind")?;
        offset += 1;
        skip_string16(bytes, &mut offset)?;
        skip_string16(bytes, &mut offset)?;
    }
    Ok(offset)
}

fn signature_help_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 9, "signature help")?;
    let count = bytes[8] as usize;
    let mut offset = 9;
    for _ in 0..count {
        skip_string16(bytes, &mut offset)?;
        skip_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 1, "signature parameter count")?;
        let parameter_count = bytes[offset] as usize;
        offset += 1;
        for _ in 0..parameter_count {
            skip_string16(bytes, &mut offset)?;
            skip_string16(bytes, &mut offset)?;
        }
    }
    Ok(offset)
}

fn float_popup_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 8, "float popup")?;
    let mut offset = 6;
    skip_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 2, "float popup line count")?;
    let line_count = read_u16(bytes, offset) as usize;
    offset += 2;
    for _ in 0..line_count {
        skip_string16(bytes, &mut offset)?;
    }
    Ok(offset)
}

fn hover_popup_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 11, "hover popup")?;
    let line_count = read_u16(bytes, 9) as usize;
    let mut offset = 11;
    for _ in 0..line_count {
        require_len(bytes, offset + 3, "hover line")?;
        let segment_count = read_u16(bytes, offset + 1) as usize;
        offset += 3;
        for _ in 0..segment_count {
            require_len(bytes, offset + 1, "hover segment style")?;
            if bytes[offset] == 13 {
                require_len(bytes, offset + 7, "hover syntax segment")?;
                let len = read_u16(bytes, offset + 5) as usize;
                offset += 7;
                require_len(bytes, offset + len, "hover syntax segment text")?;
                offset += len;
            } else {
                offset += 1;
                skip_string16(bytes, &mut offset)?;
            }
        }
    }
    Ok(offset)
}

fn agent_context_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "agent context")?;
    if bytes[1] == 0 {
        return Ok(2);
    }
    require_len(bytes, 4, "agent context task length")?;
    let len = read_u16(bytes, 2) as usize;
    let offset = 4 + len;
    require_len(bytes, offset + 10, "agent context body")?;
    Ok(offset + 10)
}

fn git_status_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 9, "git status")?;
    let mut offset = 7;
    skip_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 2, "git entry count")?;
    let entry_count = read_u16(bytes, offset) as usize;
    offset += 2;
    for _ in 0..entry_count {
        require_len(bytes, offset + 6, "git entry")?;
        offset += 6;
        skip_string16(bytes, &mut offset)?;
    }
    require_len(bytes, offset + 1, "git toast visibility")?;
    match bytes[offset] {
        0 => offset += 1,
        _ => {
            require_len(bytes, offset + 5, "git toast")?;
            let len = read_u16(bytes, offset + 3) as usize;
            offset += 5;
            require_len(bytes, offset + len, "git toast message")?;
            offset += len;
        }
    }
    skip_string16(bytes, &mut offset)?;
    skip_string16(bytes, &mut offset)?;
    require_len(bytes, offset + 2, "git stash count")?;
    Ok(offset + 2)
}

fn change_summary_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 6, "change summary")?;
    let count = read_u16(bytes, 4) as usize;
    let mut offset = 6;
    for _ in 0..count {
        skip_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 9, "change summary entry")?;
        offset += 9;
    }
    Ok(offset)
}

fn board_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "board")?;
    if bytes[1] == 0 {
        return Ok(2);
    }
    require_len(bytes, 11, "board visible")?;
    let card_count = read_u16(bytes, 6) as usize;
    let mut offset = 9;
    skip_string16(bytes, &mut offset)?;
    for _ in 0..card_count {
        require_len(bytes, offset + 6, "board card")?;
        offset += 6;
        skip_string16(bytes, &mut offset)?;
        skip_string8(bytes, &mut offset)?;
        require_len(bytes, offset + 5, "board card timestamp and recent files")?;
        offset += 4;
        let recent_count = bytes[offset] as usize;
        offset += 1;
        for _ in 0..recent_count {
            skip_string16(bytes, &mut offset)?;
        }
        require_len(bytes, offset + 1, "board sparkline count")?;
        let sparkline_count = bytes[offset] as usize;
        offset += 1;
        require_len(bytes, offset + sparkline_count * 2, "board sparkline")?;
        offset += sparkline_count * 2;
    }
    Ok(offset)
}

fn bottom_panel_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 6, "bottom panel")?;
    let tab_count = bytes[5] as usize;
    let mut offset = 6;
    for _ in 0..tab_count {
        require_len(bytes, offset + 2, "bottom panel tab")?;
        offset += 1;
        skip_string8(bytes, &mut offset)?;
    }
    require_len(bytes, offset + 2, "bottom panel entry count")?;
    let entry_count = read_u16(bytes, offset) as usize;
    offset += 2;
    for _ in 0..entry_count {
        require_len(bytes, offset + 10, "bottom panel entry")?;
        offset += 10;
        skip_string16(bytes, &mut offset)?;
        skip_string16(bytes, &mut offset)?;
    }
    Ok(offset)
}

fn tool_manager_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "tool manager")?;
    if bytes[1] == 0 {
        return Ok(2);
    }
    require_len(bytes, 7, "tool manager visible")?;
    let count = read_u16(bytes, 5) as usize;
    let mut offset = 7;
    for _ in 0..count {
        skip_string8(bytes, &mut offset)?;
        skip_string8(bytes, &mut offset)?;
        skip_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 4, "tool metadata")?;
        offset += 3;
        let language_count = bytes[offset] as usize;
        offset += 1;
        for _ in 0..language_count {
            skip_string8(bytes, &mut offset)?;
        }
        skip_string8(bytes, &mut offset)?;
        skip_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 1, "tool provides count")?;
        let provides_count = bytes[offset] as usize;
        offset += 1;
        for _ in 0..provides_count {
            skip_string8(bytes, &mut offset)?;
        }
        skip_string16(bytes, &mut offset)?;
    }
    Ok(offset)
}

fn skip_string8(bytes: &[u8], offset: &mut usize) -> Result<(), DecodeError> {
    require_len(bytes, *offset + 1, "string8 header")?;
    let len = bytes[*offset] as usize;
    *offset += 1;
    require_len(bytes, *offset + len, "string8 body")?;
    *offset += len;
    Ok(())
}

fn skip_string16(bytes: &[u8], offset: &mut usize) -> Result<(), DecodeError> {
    require_len(bytes, *offset + 2, "string16 header")?;
    let len = read_u16(bytes, *offset) as usize;
    *offset += 2;
    require_len(bytes, *offset + len, "string16 body")?;
    *offset += len;
    Ok(())
}

fn require_len(bytes: &[u8], needed: usize, message: &'static str) -> Result<(), DecodeError> {
    if bytes.len() < needed {
        Err(DecodeError::Malformed(message))
    } else {
        Ok(())
    }
}

fn read_string(bytes: &[u8], offset: usize, len: usize) -> Result<String, DecodeError> {
    require_len(bytes, offset + len, "string body")?;
    std::str::from_utf8(&bytes[offset..offset + len])
        .map(str::to_owned)
        .map_err(|_| DecodeError::Utf8)
}

fn read_string8(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
    require_len(bytes, *offset + 1, "string8 header")?;
    let len = bytes[*offset] as usize;
    *offset += 1;
    let value = read_string(bytes, *offset, len)?;
    *offset += len;
    Ok(value)
}

fn read_string16(bytes: &[u8], offset: &mut usize) -> Result<String, DecodeError> {
    require_len(bytes, *offset + 2, "string16 header")?;
    let len = read_u16(bytes, *offset) as usize;
    *offset += 2;
    let value = read_string(bytes, *offset, len)?;
    *offset += len;
    Ok(value)
}

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_u24(bytes: &[u8], offset: usize) -> u32 {
    ((bytes[offset] as u32) << 16) | ((bytes[offset + 1] as u32) << 8) | bytes[offset + 2] as u32
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_window_content_rows() {
        let header = section(0x01, &[0, 1, 0x03, 0, 4, 0, 5, 2, 0, 0, 0, 0, 0, 7]);
        let row = [
            vec![
                0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0x12, 0, 0, 0, 2,
            ],
            b"hi".to_vec(),
            vec![0, 1, 0, 0, 0, 2, 0xAA, 0xBB, 0xCC, 0, 0, 0, 1, 0, 0],
        ]
        .concat();
        let rows = section(0x02, &[vec![0, 1], row].concat());
        let payload = [vec![opcodes::OP_GUI_WINDOW_CONTENT, 2], header, rows].concat();

        let command = decode(&payload).unwrap();

        assert_eq!(semantic_size(&payload).unwrap(), payload.len());
        assert!(matches!(
            command,
            Command::WindowContent(WindowContent {
                window_id: 1,
                origin_row: 0,
                origin_col: 0,
                cursor_row: 4,
                cursor_col: 5,
                cursor_shape: 2,
                content_epoch: 7,
                rows,
                ..
            }, _) if rows[0].text == "hi" && rows[0].spans[0].fg == 0xAABBCC
        ));
    }

    #[test]
    fn rejects_window_content_geometry_without_hit_region_bytes() {
        let header = section(0x01, &[0, 1, 0x03, 0, 4, 0, 5, 2, 0, 0, 0, 0, 0, 7]);
        let rows = section(0x02, &[0, 0]);
        let mut geometry_payload = vec![0; 67];
        geometry_payload[1] = 7;
        geometry_payload[63] = 3;
        geometry_payload[65] = 2;
        geometry_payload[66] = 1;
        let geometry = section(0x08, &geometry_payload);
        let payload = [
            vec![opcodes::OP_GUI_WINDOW_CONTENT, 3],
            header,
            rows,
            geometry,
        ]
        .concat();

        assert!(decode(&payload).is_err());
    }

    #[test]
    fn decodes_tab_bar_labels() {
        let payload = [
            vec![opcodes::OP_GUI_TAB_BAR, 0, 2],
            tab_entry(0x01, "main.ex", 0x11223344),
            tab_entry(0x02, "router.ex", 0),
        ]
        .concat();

        let command = decode(&payload).unwrap();

        assert!(matches!(
            command,
            Command::TabBar(TabBar { active_index: 0, tabs }, _) if tabs[0].active && tabs[1].dirty && tabs[1].label == "router.ex"
        ));
    }

    #[test]
    fn decodes_status_bar_file_and_segments() {
        let identity = section(0x01, &[0, 1, 0x06]);
        let cursor = section(0x02, &[0, 0, 0, 12, 0, 0, 0, 4, 0, 0, 0, 99]);
        let git = section(
            0x05,
            &[vec![4], b"main".to_vec(), vec![0, 0, 0, 0, 0, 0]].concat(),
        );
        let file = section(
            0x06,
            &[
                vec![0, 0, 0, 0, 0, 7],
                b"main.ex".to_vec(),
                vec![6],
                b"elixir".to_vec(),
            ]
            .concat(),
        );
        let modeline = section(
            0x0B,
            &[vec![2, 0, 1, 0, 0], status_segment("NORMAL")].concat(),
        );
        let payload = [
            vec![opcodes::OP_GUI_STATUS_BAR, 5],
            identity,
            cursor,
            git,
            file,
            modeline,
        ]
        .concat();

        let command = decode(&payload).unwrap();

        assert!(matches!(
            command,
            Command::StatusBar(StatusBar { mode: 1, line: 12, col: 4, filename, branch, left_segments, .. }, _)
                if filename == "main.ex" && branch == "main" && left_segments[0].text == "NORMAL"
        ));
    }

    #[test]
    fn decodes_file_tree_and_selection() {
        let row = [
            vec![0, 0, 0, 1, 0, 0x15, 1, 3, 0, 1, 0, 2, 0, 0, 0, 0, 0],
            string16("id-1"),
            string16("/tmp/main.ex"),
            string16("main.ex"),
            string16("main.ex"),
            string8("rs"),
            vec![0xFF],
            string16(""),
        ]
        .concat();
        let payload = [
            vec![2, 0x03, 3],
            string16("id-1"),
            string16("/tmp"),
            vec![0, 24, 0, 1],
            string16(""),
            row,
        ]
        .concat();
        let mut packet = vec![opcodes::OP_GUI_FILE_TREE];
        packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        packet.extend_from_slice(&payload);

        let command = decode(&packet).unwrap();

        assert!(matches!(
            command,
            Command::FileTree(FileTree { visible: true, focused: true, width: 24, selected_id, rows, .. }, _)
                if selected_id == "id-1" && rows[0].name == "main.ex" && rows[0].flags == 0x15
        ));

        let selection_payload = [vec![1], string16("id-2")].concat();
        let mut selection = vec![opcodes::OP_GUI_FILE_TREE_SELECTION];
        selection.extend_from_slice(&(selection_payload.len() as u16).to_be_bytes());
        selection.extend_from_slice(&selection_payload);

        assert!(matches!(
            decode(&selection).unwrap(),
            Command::FileTreeSelection(FileTreeSelection { focused: true, selected_id }, _)
                if selected_id == "id-2"
        ));
    }

    #[test]
    fn decodes_picker_and_preview() {
        let header = section(
            0x01,
            &[vec![1, 0, 1, 0, 4, 0, 9, 1], string16("Files"), vec![0, 2]].concat(),
        );
        let query = section(0x02, &string16("src"));
        let item = [
            vec![0xAA, 0xBB, 0xCC, 0x02],
            string16("main.ex"),
            string16("lib/minga"),
            string16("modified"),
            vec![0],
        ]
        .concat();
        let items = section(0x03, &[vec![0, 1], item].concat());
        let mode_prefix = section(0x05, &string16(">"));
        let load = section(0x06, &[0]);
        let packet = [
            vec![opcodes::OP_GUI_PICKER, 5],
            header,
            query,
            items,
            mode_prefix,
            load,
        ]
        .concat();

        assert!(matches!(
            decode(&packet).unwrap(),
            Command::Picker(Picker { visible: true, selected_index: 1, title, query, marked_count: 2, items, .. }, _)
                if title == "Files" && query == "src" && items[0].marked
        ));

        let preview = [
            vec![
                opcodes::OP_GUI_PICKER_PREVIEW,
                1,
                0,
                1,
                1,
                0x11,
                0x22,
                0x33,
                1,
            ],
            string16("preview"),
        ]
        .concat();

        assert!(matches!(
            decode(&preview).unwrap(),
            Command::PickerPreview(PickerPreview { visible: true, lines }, _)
                if lines[0][0].text == "preview" && lines[0][0].bold
        ));
    }

    #[test]
    fn decodes_minibuffer() {
        let candidate = [
            vec![42],
            string16("write"),
            string16("Save file"),
            string16(":w"),
            vec![0],
        ]
        .concat();
        let packet = [
            vec![opcodes::OP_GUI_MINIBUFFER, 1, 0, 0, 2],
            string8(":"),
            string16("w"),
            string16("command"),
            vec![0, 0, 0, 1, 0, 4],
            candidate,
        ]
        .concat();

        assert!(matches!(
            decode(&packet).unwrap(),
            Command::Minibuffer(Minibuffer { visible: true, prompt, input, candidates, total_candidates: 4, .. }, _)
                if prompt == ":" && input == "w" && candidates[0].label == "write"
        ));
    }

    #[test]
    fn decodes_breadcrumb_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_BREADCRUMB, 3],
            string16("lib"),
            string16("minga"),
            string16("editor.ex"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::Breadcrumb(Breadcrumb { segments }, _) if segments == vec!["lib", "minga", "editor.ex"]
        ));
    }

    #[test]
    fn decodes_completion_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_COMPLETION, 1, 0, 4, 0, 12, 0, 1, 0, 2],
            vec![1],
            string16("write"),
            string16("Save file"),
            vec![5],
            string16("Minga"),
            string16("module"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::Completion(Completion { visible: true, anchor_row: 4, anchor_col: 12, selected_index: 1, items }, _)
                if items[0].kind == 1 && items[0].label == "write" && items[1].detail == "module"
        ));
    }

    #[test]
    fn decodes_which_key_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_WHICH_KEY, 1],
            string16("SPC"),
            vec![0, 2, 0, 2, 0],
            string8("f"),
            string16("Find file"),
            string8(""),
            vec![1],
            string8("b"),
            string16("Buffers"),
            string8(">"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::WhichKey(WhichKey { visible: true, prefix, page: 0, page_count: 2, bindings }, _)
                if prefix == "SPC" && bindings[0].key == "f" && bindings[1].kind == 1
        ));
    }

    #[test]
    fn decodes_signature_help_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_SIGNATURE_HELP, 1, 0, 8, 0, 12, 0, 1, 1],
            string16("open(path, opts)"),
            string16("Open a file"),
            vec![2],
            string16("path"),
            string16("File path"),
            string16("opts"),
            string16("Options"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::SignatureHelp(SignatureHelp { visible: true, anchor_row: 8, anchor_col: 12, active_parameter: 1, signatures, .. }, _)
                if signatures[0].label == "open(path, opts)" && signatures[0].parameters[1].label == "opts"
        ));
    }

    #[test]
    fn decodes_float_popup_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_FLOAT_POPUP, 1, 0, 24, 0, 5],
            string16("Docs"),
            vec![0, 2],
            string16("line one"),
            string16("line two"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::FloatPopup(FloatPopup { visible: true, width: 24, height: 5, title, lines }, _)
                if title == "Docs" && lines == vec!["line one", "line two"]
        ));
    }

    #[test]
    fn decodes_hover_popup_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_HOVER_POPUP, 1, 0, 3, 0, 9, 1, 0, 2, 0, 1],
            vec![0, 0, 2],
            vec![0],
            string16("plain"),
            vec![13, 0xAA, 0xBB, 0xCC, 0x05],
            string16("syntax"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::HoverPopup(HoverPopup { visible: true, anchor_row: 3, anchor_col: 9, focused: true, scroll_offset: 2, lines }, _)
                if lines[0].segments[0].text == "plain"
                    && lines[0].segments[1].fg == 0xAABBCC
                    && lines[0].segments[1].flags == 0x05
        ));
    }

    #[test]
    fn decodes_bottom_panel_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_BOTTOM_PANEL, 1, 1, 30, 2, 2],
            vec![0],
            string8("Logs"),
            vec![1],
            string8("Tasks"),
            vec![0, 1],
            vec![0, 0, 0, 7, 4, 2, 0, 0, 0, 42],
            string16("lib/minga.ex"),
            string16("failed to compile"),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::BottomPanel(BottomPanel { visible: true, active_tab_index: 1, height_percent: 30, filter: 2, tabs, entries }, _)
                if tabs[0].name == "Logs"
                    && tabs[1].tab_type == 1
                    && entries[0].id == 7
                    && entries[0].text == "failed to compile"
        ));
    }

    #[test]
    fn decodes_change_summary_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_CHANGE_SUMMARY, 1, 0, 1, 0, 2],
            string16("lib/a.ex"),
            vec![0, 0, 0, 0, 12, 0, 0, 0, 3],
            string16("lib/b.ex"),
            vec![1, 0, 0, 0, 5, 0, 0, 0, 0],
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::ChangeSummary(ChangeSummary { visible: true, selected_index: 1, entries }, _)
                if entries[0].path == "lib/a.ex"
                    && entries[0].lines_added == 12
                    && entries[1].action == 1
        ));
    }

    #[test]
    fn decodes_git_status_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_GIT_STATUS, 0, 1, 0, 2, 0, 1],
            string16("main"),
            vec![0, 1],
            vec![0x12, 0x34, 0x56, 0x78, 1, 1],
            string16("lib/minga.ex"),
            vec![1, 0, 0],
            string16("Pulled"),
            string16("lib"),
            string16("Initial commit"),
            vec![0, 3],
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();

        let command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::GitStatus(GitStatus { repo_state: 0, syncing: true, ahead: 2, behind: 1, branch, entries, toast: Some(toast), entry_base_path, last_commit_message, stash_count }, _)
                if branch == "main"
                    && entries[0].path_hash == 0x12345678
                    && entries[0].path == "lib/minga.ex"
                    && toast.message == "Pulled"
                    && entry_base_path == "lib"
                    && last_commit_message == "Initial commit"
                    && stash_count == 3
        ));
    }

    #[test]
    fn decodes_theme_slots() {
        let packet = vec![
            opcodes::OP_GUI_THEME,
            2,
            0x20,
            0x11,
            0x22,
            0x33,
            0x23,
            0xAA,
            0xBB,
            0xCC,
        ];

        assert!(matches!(
            decode(&packet).unwrap(),
            Command::Theme(Theme { slots }, 10)
                if slots[0] == ThemeSlot { id: 0x20, rgb: 0x112233 }
                    && slots[1] == ThemeSlot { id: 0x23, rgb: 0xAABBCC }
        ));
    }

    #[test]
    fn decodes_visible_legacy_commands_without_consuming_following_commands() {
        let agent_context = vec![
            opcodes::OP_GUI_AGENT_CONTEXT,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
        ];
        let packet = [agent_context, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(command, Command::AgentContext(AgentContext { visible: 1, .. }, _)));

        let board = vec![opcodes::OP_GUI_BOARD, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let packet = [board, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(command, Command::Board(Board { visible: 1, .. }, _)));

        let agent_chat = vec![opcodes::OP_GUI_AGENT_CHAT, 1, 1, 0, 0];
        let packet = [agent_chat, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(command, Command::AgentChat(AgentChat { visible: 1, .. }, _)));

        let tool_manager = vec![opcodes::OP_GUI_TOOL_MANAGER, 1, 0, 0, 0, 0, 0];
        let packet = [tool_manager, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(command, Command::ToolManager(ToolManager { visible: 1 }, _)));
    }

    #[test]
    fn decodes_editor_chrome_without_consuming_following_commands() {
        fn assert_theme_tail(packet: &[u8], size: usize) {
            assert_eq!(size, packet.len() - 2);
            assert!(matches!(
                decode(&packet[size..]).unwrap(),
                Command::Theme(Theme { slots }, _) if slots.is_empty()
            ));
        }

        let gutter = [
            vec![opcodes::OP_GUI_GUTTER, 3],
            section(0x01, &[0, 1, 0, 2, 0, 3, 0, 4, 1, 0, 5]),
            section(0x02, &[0, 0, 0, 12, 0, 3, 1]),
            section(
                0x03,
                &[
                    0, 1, 0, 0, 0, 12, 0, 8, 0, 0, 0, 0, 0x11, 0x22, 0x33, 1, b'!',
                ],
            ),
        ]
        .concat();
        let packet = [gutter, vec![opcodes::OP_GUI_THEME, 0]].concat();
        let size = semantic_size(&packet).unwrap();
        match decode(&packet).unwrap() {
            Command::Gutter(
                Gutter {
                    window_id,
                    content_row,
                    content_col,
                    content_height,
                    is_active,
                    content_width,
                    cursor_line,
                    line_number_style,
                    line_number_width,
                    sign_col_width,
                    entries,
                },
                _,
            ) => {
                assert_eq!(window_id, 1);
                assert_eq!(content_row, 2);
                assert_eq!(content_col, 3);
                assert_eq!(content_height, 4);
                assert!(is_active);
                assert_eq!(content_width, 5);
                assert_eq!(cursor_line, 12);
                assert_eq!(line_number_style, 0);
                assert_eq!(line_number_width, 3);
                assert_eq!(sign_col_width, 1);
                assert_eq!(entries.len(), 1);
                assert_eq!(entries[0].buf_line, 12);
                assert_eq!(entries[0].sign_type, 8);
                assert_eq!(entries[0].sign_fg, 0x112233);
                assert_eq!(entries[0].sign_text, "!");
            }
            other => panic!("expected gutter command, got {other:?}"),
        }
        assert_theme_tail(&packet, size);

        let packet = [
            vec![opcodes::OP_GUI_CURSORLINE, 0, 9, 0x11, 0x22, 0x33],
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();
        let size = semantic_size(&packet).unwrap();
        match decode(&packet).unwrap() {
            Command::Cursorline(Cursorline { row, bg }, _) => {
                assert_eq!(row, 9);
                assert_eq!(bg, 0x112233);
            }
            other => panic!("expected cursorline command, got {other:?}"),
        }
        assert_theme_tail(&packet, size);

        let packet = [
            vec![opcodes::OP_GUI_GUTTER_SEP, 0, 6, 0x44, 0x55, 0x66],
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();
        let size = semantic_size(&packet).unwrap();
        match decode(&packet).unwrap() {
            Command::GutterSeparator(GutterSeparator { col, color }, _) => {
                assert_eq!(col, 6);
                assert_eq!(color, 0x445566);
            }
            other => panic!("expected gutter separator command, got {other:?}"),
        }
        assert_theme_tail(&packet, size);

        let packet = [
            vec![opcodes::OP_GUI_SPLIT_SEPARATORS, 0x11, 0x22, 0x33, 1],
            vec![0, 2, 0, 1, 0, 3],
            vec![1, 0, 4, 0, 2, 0, 6, 0, 3],
            b"tab".to_vec(),
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();
        let size = semantic_size(&packet).unwrap();
        match decode(&packet).unwrap() {
            Command::SplitSeparators(
                SplitSeparators {
                    color,
                    verticals,
                    horizontals,
                },
                _,
            ) => {
                assert_eq!(color, 0x112233);
                assert_eq!(
                    verticals,
                    vec![VerticalSeparator {
                        col: 2,
                        start_row: 1,
                        end_row: 3
                    }]
                );
                assert_eq!(
                    horizontals,
                    vec![HorizontalSeparator {
                        row: 4,
                        col: 2,
                        width: 6,
                        filename: "tab".to_owned(),
                    }]
                );
            }
            other => panic!("expected split separators command, got {other:?}"),
        }
        assert_theme_tail(&packet, size);

        let packet = [
            vec![
                opcodes::OP_GUI_INDENT_GUIDES,
                0,
                14,
                0,
                1,
                2,
                0,
                2,
                2,
                0,
                2,
                0,
                4,
                0,
                2,
                1,
                2,
            ],
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();
        let size = semantic_size(&packet).unwrap();
        match decode(&packet).unwrap() {
            Command::IndentGuides(
                IndentGuides {
                    window_id,
                    tab_width,
                    active_guide_col,
                    guide_cols,
                    line_indent_levels,
                },
                _,
            ) => {
                assert_eq!(window_id, 1);
                assert_eq!(tab_width, 2);
                assert_eq!(active_guide_col, 2);
                assert_eq!(guide_cols, vec![2, 4]);
                assert_eq!(line_indent_levels, vec![1, 2]);
            }
            other => panic!("expected indent guides command, got {other:?}"),
        }
        assert_theme_tail(&packet, size);

        let packet = [
            vec![
                opcodes::OP_GUI_WINDOW_OVERLAY_DELTA,
                0,
                1,
                0,
                0,
                0,
                7,
                3,
                0,
                2,
                0,
                5,
                1,
                0,
                2,
                0xAA,
                0xBB,
                0xCC,
            ],
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();
        let size = semantic_size(&packet).unwrap();
        match decode(&packet).unwrap() {
            Command::WindowOverlayDelta(
                WindowOverlayDelta {
                    window_id,
                    content_epoch,
                    cursor_visible,
                    cursor_row,
                    cursor_col,
                    cursor_shape,
                    cursorline,
                },
                _,
            ) => {
                assert_eq!(window_id, 1);
                assert_eq!(content_epoch, 7);
                assert!(cursor_visible);
                assert_eq!(cursor_row, 2);
                assert_eq!(cursor_col, 5);
                assert_eq!(cursor_shape, 1);
                assert_eq!(
                    cursorline,
                    Some(Cursorline {
                        row: 2,
                        bg: 0xAABBCC
                    })
                );
            }
            other => panic!("expected overlay delta command, got {other:?}"),
        }
        assert_theme_tail(&packet, size);
    }
    #[test]
    fn decodes_hidden_tool_manager_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_GUI_TOOL_MANAGER, 0],
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();
        let command = decode(&packet).unwrap();
        let size = semantic_size(&packet).unwrap();

        assert_eq!(size, 2);
        assert!(matches!(
            command,
            Command::ToolManager(ToolManager { visible: 0 }, 2)
        ));
        assert!(matches!(
            decode(&packet[size..]).unwrap(),
            Command::Theme(Theme { slots }, _) if slots.is_empty()
        ));
    }

    #[test]
    fn decodes_config_state() {
        let bytes = [opcodes::OP_GUI_CONFIG_STATE, 0, 3, 1, 2, 3];
        let command = decode(&bytes).unwrap();
        assert_eq!(semantic_size(&bytes).unwrap(), 6);
        assert!(matches!(
            command,
            Command::ConfigState(ConfigState { ref payload }, 6) if payload == &[1, 2, 3]
        ));
    }

    #[test]
    fn decodes_notifications() {
        let bytes = [opcodes::OP_GUI_NOTIFICATIONS, 0, 3, 1, 0, 5];
        let command = decode(&bytes).unwrap();
        assert_eq!(semantic_size(&bytes).unwrap(), 6);
        assert!(matches!(
            command,
            Command::Notifications(Notifications { visible: 1, notification_count: 5 }, 6)
        ));
    }

    #[test]
    fn decodes_typed_gui_commands_without_consuming_following_commands() {
        let clipboard_payload = vec![opcodes::OP_CLIPBOARD_WRITE, 0, 2, 0, b'x'];
        let packet = [clipboard_payload, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::ClipboardWrite(ClipboardWrite { target: 0, ref text }, _) if text == "x"
        ));

        let spacing_payload = vec![opcodes::OP_GUI_LINE_SPACING, 0, 2, 0, 120];
        let packet = [spacing_payload, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::LineSpacing(LineSpacing { value: 120 }, _)
        ));

        let anim_payload = vec![opcodes::OP_GUI_CURSOR_ANIMATION, 0, 1, 1];
        let packet = [anim_payload, vec![opcodes::OP_BATCH_END]].concat();
        let command = decode(&packet).unwrap();
        assert_eq!(semantic_size(&packet).unwrap(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::CursorAnimation(CursorAnimation { enabled: 1 }, _)
        ));
    }

    fn section(id: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![id];
        out.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        out.extend_from_slice(payload);
        out
    }

    fn tab_entry(flags: u8, label: &str, tint: u32) -> Vec<u8> {
        let mut out = vec![flags, 0, 0, 0, 1, 0, 0, 0];
        out.extend_from_slice(&(label.len() as u16).to_be_bytes());
        out.extend_from_slice(label.as_bytes());
        out.extend_from_slice(&tint.to_be_bytes());
        out
    }

    fn status_segment(text: &str) -> Vec<u8> {
        let mut out = vec![4];
        out.extend_from_slice(b"mode");
        out.extend_from_slice(&[0xFF, 0xFF, 0xFF, 0, 0, 0, 1]);
        out.extend_from_slice(&(text.len() as u16).to_be_bytes());
        out.extend_from_slice(text.as_bytes());
        out.extend_from_slice(&[0, 0]);
        out
    }

    fn string8(text: &str) -> Vec<u8> {
        let mut out = vec![text.len() as u8];
        out.extend_from_slice(text.as_bytes());
        out
    }

    fn string16(text: &str) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&(text.len() as u16).to_be_bytes());
        out.extend_from_slice(text.as_bytes());
        out
    }

    #[test]
    fn overlay_delta_without_cursorline() {
        let bytes = [
            opcodes::OP_GUI_WINDOW_OVERLAY_DELTA,
            0,
            1,
            0,
            0,
            0,
            2,
            0x00,
            0,
            5,
            0,
            3,
            1,
        ];

        match decode(&bytes).unwrap() {
            Command::WindowOverlayDelta(
                WindowOverlayDelta {
                    window_id,
                    content_epoch,
                    cursor_visible,
                    cursor_row,
                    cursor_col,
                    cursor_shape,
                    cursorline,
                },
                size,
            ) => {
                assert_eq!(size, 13);
                assert_eq!(window_id, 1);
                assert_eq!(content_epoch, 2);
                assert!(!cursor_visible);
                assert_eq!(cursor_row, 5);
                assert_eq!(cursor_col, 3);
                assert_eq!(cursor_shape, 1);
                assert_eq!(cursorline, None);
            }
            other => panic!("expected window overlay delta, got {other:?}"),
        }
    }

    #[test]
    fn overlay_delta_with_cursorline_does_not_consume_following_commands() {
        let packet = [
            vec![
                opcodes::OP_GUI_WINDOW_OVERLAY_DELTA,
                0,
                1,
                0,
                0,
                0,
                2,
                0x02,
                0,
                5,
                0,
                3,
                1,
                0,
                4,
                0x2d,
                0x2d,
                0x3f,
            ],
            vec![opcodes::OP_GUI_THEME, 0],
        ]
        .concat();

        let _command = decode(&packet).unwrap();

        assert_eq!(semantic_size(&packet).unwrap(), 18);
        assert!(matches!(
            decode(&packet[semantic_size(&packet).unwrap()..]).unwrap(),
            Command::Theme(Theme { slots }, _) if slots.is_empty()
        ));
    }
}
