use crate::protocol::{DecodeError, opcodes};

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
    Theme(Theme, usize),
    Unsupported { opcode: u8, size: usize },
}

impl Command {
    pub fn size(&self) -> usize {
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
            Self::Theme(_, size) => *size,
            Self::Unsupported { size, .. } => *size,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowContent {
    pub origin_row: u16,
    pub origin_col: u16,
    pub cursor_row: u16,
    pub cursor_col: u16,
    pub cursor_shape: u8,
    pub rows: Vec<Row>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub text: String,
    pub spans: Vec<Span>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start_col: u16,
    pub end_col: u16,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
}

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub slots: Vec<ThemeSlot>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThemeSlot {
    pub id: u8,
    pub rgb: u32,
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
        opcodes::OP_GUI_THEME => decode_theme(bytes),
        opcodes::OP_GUI_WINDOW_VIEWPORT_DELTA | opcodes::OP_GUI_WINDOW_ROWS_DELTA => {
            sectioned_size(bytes, "semantic row delta")
                .map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_WINDOW_OVERLAY_DELTA => {
            overlay_delta_size(bytes).map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_GUTTER => sectioned_size(bytes, "semantic sectioned command")
            .map(|size| Command::Unsupported { opcode, size }),
        opcodes::OP_GUI_INDENT_GUIDES
        | opcodes::OP_GUI_HOVER_ACTION
        | opcodes::OP_GUI_WORKSPACES
        | opcodes::OP_GUI_NOTIFICATIONS
        | opcodes::OP_GUI_EDIT_TIMELINE
        | opcodes::OP_GUI_EXTENSION_OVERLAY
        | opcodes::OP_GUI_EXTENSION_PANEL
        | opcodes::OP_GUI_SEARCH_STATE
        | opcodes::OP_GUI_CONFIG_STATE => len16_size(bytes, "semantic length16 command")
            .map(|size| Command::Unsupported { opcode, size }),
        opcodes::OP_GUI_OBSERVATORY | opcodes::OP_GUI_SIDEBARS => {
            len32_size(bytes, "semantic length32 command")
                .map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_GUTTER_SEP => fixed_size(bytes, 6, "gutter separator")
            .map(|size| Command::Unsupported { opcode, size }),
        opcodes::OP_GUI_SPLIT_SEPARATORS => {
            split_separators_size(bytes).map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_AGENT_CONTEXT
        | opcodes::OP_GUI_GIT_STATUS
        | opcodes::OP_GUI_CHANGE_SUMMARY
        | opcodes::OP_GUI_BOARD
        | opcodes::OP_GUI_AGENT_CHAT
        | opcodes::OP_GUI_BOTTOM_PANEL
        | opcodes::OP_GUI_TOOL_MANAGER => {
            legacy_visible_size(bytes).map(|size| Command::Unsupported { opcode, size })
        }
        _ => Err(DecodeError::UnknownOpcode(opcode)),
    }
}

fn decode_window_content(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = sectioned_size(bytes, "window content")?;
    let sections = sections(&bytes[..size])?;
    let mut cursor_row = 0;
    let mut cursor_col = 0;
    let mut cursor_shape = 0;
    let mut origin_row = 0;
    let mut origin_col = 0;
    let mut rows = Vec::new();

    for (section_id, payload) in sections {
        match section_id {
            0x01 => {
                require_len(payload, 14, "window content header")?;
                cursor_row = read_u16(payload, 3);
                cursor_col = read_u16(payload, 5);
                cursor_shape = payload[7];
            }
            0x02 => rows = decode_rows(payload)?,
            0x08 if payload.len() >= 26 => {
                origin_row = read_u16(payload, 18);
                origin_col = read_u16(payload, 20);
            }
            _ => {}
        }
    }

    Ok(Command::WindowContent(
        WindowContent {
            origin_row,
            origin_col,
            cursor_row,
            cursor_col,
            cursor_shape,
            rows,
        },
        size,
    ))
}

fn decode_status_bar(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = sectioned_size(bytes, "status bar")?;
    let sections = sections(&bytes[..size])?;
    let mut status = StatusBar::default();

    for (section_id, payload) in sections {
        match section_id {
            0x01 => {
                require_len(payload, 3, "status identity")?;
                status.mode = payload[1];
                status.flags = payload[2];
            }
            0x02 => {
                require_len(payload, 12, "status cursor")?;
                status.line = read_u32(payload, 0);
                status.col = read_u32(payload, 4);
                status.line_count = read_u32(payload, 8);
            }
            0x05 => {
                require_len(payload, 1, "status git")?;
                let len = payload[0] as usize;
                require_len(payload, 1 + len, "status git branch")?;
                status.branch = read_string(payload, 1, len)?;
            }
            0x06 => status_file(payload, &mut status)?,
            0x07 => {
                require_len(payload, 2, "status message")?;
                let len = read_u16(payload, 0) as usize;
                status.message = read_string(payload, 2, len)?;
            }
            0x0B => status_segments(payload, &mut status)?,
            _ => {}
        }
    }

    Ok(Command::StatusBar(status, size))
}

fn status_file(payload: &[u8], status: &mut StatusBar) -> Result<(), DecodeError> {
    require_len(payload, 1, "status file icon")?;
    let icon_len = payload[0] as usize;
    let mut offset = 1 + icon_len + 3;
    require_len(payload, offset + 2, "status file name header")?;
    let filename_len = read_u16(payload, offset) as usize;
    offset += 2;
    status.filename = read_string(payload, offset, filename_len)?;
    offset += filename_len;
    require_len(payload, offset + 1, "status filetype header")?;
    let filetype_len = payload[offset] as usize;
    status.filetype = read_string(payload, offset + 1, filetype_len)?;
    Ok(())
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
    let size = tab_bar_size(bytes)?;
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
    let size = len32_size(bytes, "file tree")?;
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
    let size = len16_size(bytes, "file tree selection")?;
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

    let size = sectioned_size(bytes, "picker")?;
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
    let size = breadcrumb_size(bytes)?;
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

    let size = completion_size(bytes)?;
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

    let size = which_key_size(bytes)?;
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

    let size = signature_help_size(bytes)?;
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

    let size = float_popup_size(bytes)?;
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

    let size = hover_popup_size(bytes)?;
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

fn decode_theme(bytes: &[u8]) -> Result<Command, DecodeError> {
    let size = theme_size(bytes)?;
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
    require_len(bytes, 2, "row count")?;
    let count = read_u16(bytes, 0) as usize;
    let mut offset = 2;
    let mut rows = Vec::with_capacity(count);

    for _ in 0..count {
        let (row, used) = decode_row(&bytes[offset..])?;
        offset += used;
        rows.push(row);
    }

    Ok(rows)
}

fn decode_row(bytes: &[u8]) -> Result<(Row, usize), DecodeError> {
    require_len(bytes, 21, "row header")?;
    let text_len = read_u32(bytes, 17) as usize;
    require_len(bytes, 21 + text_len + 2, "row text")?;
    let text_start = 21;
    let span_count_offset = text_start + text_len;
    let text = std::str::from_utf8(&bytes[text_start..span_count_offset])
        .map(str::to_owned)
        .map_err(|_| DecodeError::Utf8)?;
    let span_count = read_u16(bytes, span_count_offset) as usize;
    let mut offset = span_count_offset + 2;
    let mut spans = Vec::with_capacity(span_count);

    for _ in 0..span_count {
        require_len(bytes, offset + 11, "row span")?;
        spans.push(Span {
            start_col: read_u16(bytes, offset),
            end_col: read_u16(bytes, offset + 2),
            fg: read_u24(bytes, offset + 4),
            bg: read_u24(bytes, offset + 7),
            attrs: bytes[offset + 10] as u16,
        });
        offset += 11;
    }

    Ok((Row { text, spans }, offset))
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
        require_len(bytes, offset + 3, "cursorline section")?;
        let len = read_u16(bytes, offset + 1) as usize;
        offset += 3;
        require_len(bytes, offset + len, "cursorline payload")?;
        offset += len;
    }

    Ok(offset)
}

fn len16_size(bytes: &[u8], name: &'static str) -> Result<usize, DecodeError> {
    require_len(bytes, 3, name)?;
    let len = read_u16(bytes, 1) as usize;
    require_len(bytes, 3 + len, name)?;
    Ok(3 + len)
}

fn len32_size(bytes: &[u8], name: &'static str) -> Result<usize, DecodeError> {
    require_len(bytes, 5, name)?;
    let len = read_u32(bytes, 1) as usize;
    require_len(bytes, 5 + len, name)?;
    Ok(5 + len)
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

fn legacy_visible_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 2, "legacy semantic visibility")?;

    if bytes[1] == 0 {
        return Ok(2);
    }

    match bytes[0] {
        opcodes::OP_GUI_BREADCRUMB => breadcrumb_size(bytes),
        opcodes::OP_GUI_COMPLETION => completion_size(bytes),
        opcodes::OP_GUI_SIGNATURE_HELP => signature_help_size(bytes),
        opcodes::OP_GUI_FLOAT_POPUP => float_popup_size(bytes),
        opcodes::OP_GUI_HOVER_POPUP => hover_popup_size(bytes),
        opcodes::OP_GUI_AGENT_CONTEXT => agent_context_size(bytes),
        opcodes::OP_GUI_GIT_STATUS => git_status_size(bytes),
        opcodes::OP_GUI_CHANGE_SUMMARY => change_summary_size(bytes),
        opcodes::OP_GUI_BOARD => board_size(bytes),
        opcodes::OP_GUI_AGENT_CHAT => sectioned_size(bytes, "agent chat"),
        opcodes::OP_GUI_BOTTOM_PANEL => bottom_panel_size(bytes),
        opcodes::OP_GUI_TOOL_MANAGER => tool_manager_size(bytes),
        _ => Err(DecodeError::Malformed(
            "unsupported legacy semantic command",
        )),
    }
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
    require_len(bytes, 4, "agent context")?;
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
    require_len(bytes, 5, "change summary")?;
    let count = read_u16(bytes, 3) as usize;
    let mut offset = 5;
    for _ in 0..count {
        skip_string16(bytes, &mut offset)?;
        require_len(bytes, offset + 9, "change summary entry")?;
        offset += 9;
    }
    Ok(offset)
}

fn board_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    require_len(bytes, 11, "board")?;
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
    require_len(bytes, 7, "tool manager")?;
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
            vec![0, 1, 0, 0, 0, 2, 0xAA, 0xBB, 0xCC, 0, 0, 0, 1],
        ]
        .concat();
        let rows = section(0x02, &[vec![0, 1], row].concat());
        let payload = [vec![opcodes::OP_GUI_WINDOW_CONTENT, 2], header, rows].concat();

        let command = decode(&payload).unwrap();

        assert_eq!(command.size(), payload.len());
        assert!(matches!(
            command,
            Command::WindowContent(WindowContent {
                origin_row: 0,
                origin_col: 0,
                cursor_row: 4,
                cursor_col: 5,
                cursor_shape: 2,
                rows,
            }, _) if rows[0].text == "hi" && rows[0].spans[0].fg == 0xAABBCC
        ));
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

        assert_eq!(command.size(), packet.len() - 1);
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

        assert_eq!(command.size(), packet.len() - 1);
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

        assert_eq!(command.size(), packet.len() - 1);
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

        assert_eq!(command.size(), packet.len() - 1);
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

        assert_eq!(command.size(), packet.len() - 1);
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

        assert_eq!(command.size(), packet.len() - 1);
        assert!(matches!(
            command,
            Command::HoverPopup(HoverPopup { visible: true, anchor_row: 3, anchor_col: 9, focused: true, scroll_offset: 2, lines }, _)
                if lines[0].segments[0].text == "plain"
                    && lines[0].segments[1].fg == 0xAABBCC
                    && lines[0].segments[1].flags == 0x05
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
    fn skips_remaining_visible_legacy_commands_without_consuming_following_commands() {
        let cases = [
            (
                opcodes::OP_GUI_AGENT_CONTEXT,
                vec![
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
                ],
            ),
            (
                opcodes::OP_GUI_GIT_STATUS,
                vec![
                    opcodes::OP_GUI_GIT_STATUS,
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
                    0,
                    0,
                    0,
                    0,
                ],
            ),
            (
                opcodes::OP_GUI_CHANGE_SUMMARY,
                vec![opcodes::OP_GUI_CHANGE_SUMMARY, 1, 0, 0, 0],
            ),
            (
                opcodes::OP_GUI_BOARD,
                vec![opcodes::OP_GUI_BOARD, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            ),
            (
                opcodes::OP_GUI_AGENT_CHAT,
                vec![opcodes::OP_GUI_AGENT_CHAT, 1, 1, 0, 0],
            ),
            (
                opcodes::OP_GUI_BOTTOM_PANEL,
                vec![opcodes::OP_GUI_BOTTOM_PANEL, 1, 0, 0, 0, 0, 0, 0],
            ),
            (
                opcodes::OP_GUI_TOOL_MANAGER,
                vec![opcodes::OP_GUI_TOOL_MANAGER, 1, 0, 0, 0, 0, 0],
            ),
        ];

        for (opcode, payload) in cases {
            let packet = [payload.clone(), vec![opcodes::OP_BATCH_END]].concat();
            let command = decode(&packet).unwrap();

            assert_eq!(command.size(), packet.len() - 1);
            assert!(matches!(
                command,
                Command::Unsupported {
                    opcode: decoded,
                    size
                } if decoded == opcode && size == packet.len() - 1
            ));
        }
    }

    #[test]
    fn skips_length_prefixed_config_state() {
        let command = decode(&[opcodes::OP_GUI_CONFIG_STATE, 0, 3, 1, 2, 3]).unwrap();

        assert_eq!(command.size(), 6);
    }

    #[test]
    fn skips_length_wrapped_semantic_commands() {
        let command = decode(&[opcodes::OP_GUI_NOTIFICATIONS, 0, 3, 1, 2, 3]).unwrap();

        assert_eq!(command.size(), 6);
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
}
