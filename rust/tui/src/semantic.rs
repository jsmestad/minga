use crate::protocol::{DecodeError, opcodes};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    WindowContent(WindowContent, usize),
    Unsupported { opcode: u8, size: usize },
}

impl Command {
    pub fn size(&self) -> usize {
        match self {
            Self::WindowContent(_, size) => *size,
            Self::Unsupported { size, .. } => *size,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WindowContent {
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

pub fn decode(bytes: &[u8]) -> Result<Command, DecodeError> {
    let opcode = *bytes.first().ok_or(DecodeError::Empty)?;

    match opcode {
        opcodes::OP_GUI_WINDOW_CONTENT => decode_window_content(bytes),
        opcodes::OP_GUI_WINDOW_VIEWPORT_DELTA | opcodes::OP_GUI_WINDOW_ROWS_DELTA => {
            sectioned_size(bytes, "semantic row delta")
                .map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_WINDOW_OVERLAY_DELTA => {
            overlay_delta_size(bytes).map(|size| Command::Unsupported { opcode, size })
        }
        opcodes::OP_GUI_GUTTER
        | opcodes::OP_GUI_STATUS_BAR
        | opcodes::OP_GUI_PICKER
        | opcodes::OP_GUI_WHICH_KEY => sectioned_size(bytes, "semantic sectioned command")
            .map(|size| Command::Unsupported { opcode, size }),
        opcodes::OP_GUI_INDENT_GUIDES
        | opcodes::OP_GUI_FILE_TREE_SELECTION
        | opcodes::OP_GUI_HOVER_ACTION
        | opcodes::OP_GUI_WORKSPACES
        | opcodes::OP_GUI_NOTIFICATIONS
        | opcodes::OP_GUI_EDIT_TIMELINE
        | opcodes::OP_GUI_EXTENSION_OVERLAY
        | opcodes::OP_GUI_EXTENSION_PANEL
        | opcodes::OP_GUI_SEARCH_STATE => len16_size(bytes, "semantic length16 command")
            .map(|size| Command::Unsupported { opcode, size }),
        opcodes::OP_GUI_FILE_TREE | opcodes::OP_GUI_OBSERVATORY | opcodes::OP_GUI_SIDEBARS => {
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
        opcodes::OP_GUI_TAB_BAR => {
            tab_bar_size(bytes).map(|size| Command::Unsupported { opcode, size })
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
            _ => {}
        }
    }

    Ok(Command::WindowContent(
        WindowContent {
            cursor_row,
            cursor_col,
            cursor_shape,
            rows,
        },
        size,
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
                cursor_row: 4,
                cursor_col: 5,
                cursor_shape: 2,
                rows,
            }, _) if rows[0].text == "hi" && rows[0].spans[0].fg == 0xAABBCC
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
}
