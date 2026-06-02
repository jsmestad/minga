// Generated semantic wire types.
//
// Generated from `docs/protocol_schema.toml` by `mix protocol.gen`. Do not edit by hand.

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Rect {
    pub row: u16,
    pub col: u16,
    pub width: u16,
    pub height: u16,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Span {
    pub start_col: u16,
    pub end_col: u16,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u8,
    pub font_weight: u8,
    pub font_id: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Row {
    pub row_type: u8,
    pub row_id: u64,
    pub buf_line: u32,
    pub content_hash: u32,
    pub text: String,
    pub spans: Vec<Span>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SearchMatch {
    pub row: u16,
    pub start_col: u16,
    pub end_col: u16,
    pub is_current: u8,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DiagnosticRange {
    pub start_row: u16,
    pub start_col: u16,
    pub end_row: u16,
    pub end_col: u16,
    pub severity: u8,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DocumentHighlight {
    pub start_row: u16,
    pub start_col: u16,
    pub end_row: u16,
    pub end_col: u16,
    pub kind: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Annotation {
    pub row: u16,
    pub kind: u8,
    pub fg: u32,
    pub bg: u32,
    pub text: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct HitRegion {
    pub kind: u8,
    pub rect: Rect,
    pub id: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GutterEntry {
    pub buf_line: u32,
    pub display_type: u8,
    pub sign_type: u8,
    pub fold_end_line: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ModelineSegment {
    pub text: String,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u8,
}


pub const RECT_SIZE: usize = 8;
pub const SPAN_SIZE: usize = 13;
pub const SEARCH_MATCH_SIZE: usize = 7;
pub const DIAGNOSTIC_RANGE_SIZE: usize = 9;
pub const DOCUMENT_HIGHLIGHT_SIZE: usize = 9;
pub const HIT_REGION_SIZE: usize = 13;
pub const GUTTER_ENTRY_SIZE: usize = 10;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiWindowContentHeader {
    pub window_id: u16,
    pub flags: u8,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub cursor_shape: u8,
    pub scroll_left: u16,
    pub content_epoch: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiWindowContentSelection {
    pub r#type: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiWindowContentGeometry {
    pub window_id: u16,
    pub total_rect: Rect,
    pub content_rect: Rect,
    pub text_rect: Rect,
    pub gutter_rect: Rect,
    pub clip_rect: Rect,
    pub viewport_top: u32,
    pub viewport_left: u16,
    pub viewport_rows: u16,
    pub viewport_cols: u16,
    pub viewport_total_lines: u32,
    pub viewport_visual_row_offset: u16,
    pub viewport_total_visual_rows: u32,
    pub line_number_width: u16,
    pub sign_col_width: u16,
    pub hit_regions: Vec<HitRegion>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiWindowContentCursorline {
    pub row: u16,
    pub bg: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiStatusBarIdentity {
    pub content_kind: u8,
    pub mode: u8,
    pub flags: u8,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiStatusBarCursor {
    pub line: u32,
    pub col: u32,
    pub line_count: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiStatusBarDiagnostics {
    pub errors: u16,
    pub warnings: u16,
    pub info: u16,
    pub hints: u16,
    pub hint_text: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiStatusBarLanguage {
    pub lsp_status: u8,
    pub parser_status: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiStatusBarGit {
    pub branch: String,
    pub added: u16,
    pub modified: u16,
    pub deleted: u16,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiStatusBarFile {
    pub icon: String,
    pub icon_color: u32,
    pub filename: String,
    pub filetype: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiStatusBarMessage {
    pub text: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiStatusBarRecording {
    pub macro_register: u8,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiStatusBarIndent {
    pub indent_type: u8,
    pub indent_size: u8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiStatusBarModeline {
    pub format: u8,
    pub left_segments: Vec<ModelineSegment>,
    pub right_segments: Vec<ModelineSegment>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiStatusBarSelection {
    pub selection_mode: u8,
    pub selection_size: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuiStatusBarWorkspace {
    pub workspace_id: u16,
    pub kind: u8,
    pub status: u8,
    pub flags: u16,
    pub draft_count: u16,
    pub conflict_count: u16,
    pub running_background_count: u16,
    pub attention_count: u16,
    pub label: String,
    pub icon: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiGutterWindow {
    pub window_id: u16,
    pub content_row: u16,
    pub content_col: u16,
    pub content_height: u16,
    pub is_active: u8,
    pub content_width: u16,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GuiGutterConfig {
    pub cursor_line: u32,
    pub line_number_style: u8,
    pub line_number_width: u8,
    pub sign_col_width: u8,
}

