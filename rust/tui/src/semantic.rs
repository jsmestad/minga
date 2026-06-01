use crate::protocol::{DecodeError, opcodes};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    WindowContent(WindowContent, usize),
    StatusBar(StatusBar, usize),
    TabBar(TabBar, usize),
    FileTree(FileTree, usize),
    FileTreeSelection(FileTreeSelection, usize),
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

pub fn decode(bytes: &[u8]) -> Result<Command, DecodeError> {
    let opcode = *bytes.first().ok_or(DecodeError::Empty)?;

    match opcode {
        opcodes::OP_GUI_WINDOW_CONTENT => decode_window_content(bytes),
        opcodes::OP_GUI_STATUS_BAR => decode_status_bar(bytes),
        opcodes::OP_GUI_TAB_BAR => decode_tab_bar(bytes),
        opcodes::OP_GUI_FILE_TREE => decode_file_tree(bytes),
        opcodes::OP_GUI_FILE_TREE_SELECTION => decode_file_tree_selection(bytes),
        opcodes::OP_GUI_WINDOW_VIEWPORT_DELTA | opcodes::OP_GUI_WINDOW_ROWS_DELTA => {
            sectioned_size(bytes, "semantic row delta")
                .map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_WINDOW_OVERLAY_DELTA => {
            overlay_delta_size(bytes).map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_GUTTER | opcodes::OP_GUI_PICKER | opcodes::OP_GUI_WHICH_KEY => {
            sectioned_size(bytes, "semantic sectioned command")
                .map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_INDENT_GUIDES
        | opcodes::OP_GUI_HOVER_ACTION
        | opcodes::OP_GUI_WORKSPACES
        | opcodes::OP_GUI_NOTIFICATIONS
        | opcodes::OP_GUI_EDIT_TIMELINE
        | opcodes::OP_GUI_EXTENSION_OVERLAY
        | opcodes::OP_GUI_EXTENSION_PANEL
        | opcodes::OP_GUI_SEARCH_STATE => len16_size(bytes, "semantic length16 command")
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
        opcodes::OP_GUI_THEME => {
            theme_size(bytes).map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_BREADCRUMB
        | opcodes::OP_GUI_COMPLETION
        | opcodes::OP_GUI_SIGNATURE_HELP
        | opcodes::OP_GUI_FLOAT_POPUP
        | opcodes::OP_GUI_MINIBUFFER
        | opcodes::OP_GUI_HOVER_POPUP
        | opcodes::OP_GUI_AGENT_CONTEXT
        | opcodes::OP_GUI_GIT_STATUS
        | opcodes::OP_GUI_CHANGE_SUMMARY
        | opcodes::OP_GUI_BOARD
        | opcodes::OP_GUI_AGENT_CHAT
        | opcodes::OP_GUI_BOTTOM_PANEL
        | opcodes::OP_GUI_PICKER_PREVIEW
        | opcodes::OP_GUI_TOOL_MANAGER
        | opcodes::OP_GUI_CONFIG_STATE => {
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
    match bytes[1] {
        0 => Ok(2),
        _ => Err(DecodeError::Malformed(
            "unsupported legacy semantic command",
        )),
    }
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
