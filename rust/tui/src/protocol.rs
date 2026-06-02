pub mod opcodes {
    #![allow(dead_code)]

    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/src/generated/opcodes.rs"
    ));
}

pub mod command_size {
    #![allow(dead_code)]

    include!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/src/generated/command_size.rs"
    ));
}

use crate::semantic;
use command_size::CommandSize;
use std::fmt;
use std::io::{self, Write};

#[allow(dead_code)]
pub const MOD_SHIFT: u8 = 0x01;
#[allow(dead_code)]
pub const MOD_CTRL: u8 = 0x02;
#[allow(dead_code)]
pub const MOD_ALT: u8 = 0x04;
#[allow(dead_code)]
pub const MOD_SUPER: u8 = 0x08;

pub const ATTR_BOLD: u16 = 0x01;
pub const ATTR_UNDERLINE: u16 = 0x02;
pub const ATTR_ITALIC: u16 = 0x04;
pub const ATTR_REVERSE: u16 = 0x08;
pub const ATTR_STRIKETHROUGH: u16 = 0x10;
pub const UL_STYLE_SHIFT: u16 = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Clear,
    BatchEnd,
    DrawText(DrawText),
    DrawStyledText(DrawStyledText),
    SetCursor { row: u16, col: u16 },
    SetCursorShape(u8),
    SetTitle(String),
    SetWindowBg(u32),
    DefineRegion(Region),
    ClearRegion(u16),
    DestroyRegion(u16),
    SetActiveRegion(u16),
    ScrollRegion { top: u16, bottom: u16, delta: i16 },
    MeasureText { request_id: u32, text: String },
    Semantic(semantic::Command),
    Noop(usize),
}

impl Command {
    pub fn custom_size(&self) -> usize {
        match self {
            Self::DrawText(draw) => 14 + draw.text.len(),
            Self::DrawStyledText(draw) => 21 + draw.text.len(),
            Self::MeasureText { text, .. } => 7 + text.len(),
            Self::Semantic(command) => command.custom_size(),
            Self::Noop(size) => *size,
            Self::Clear
            | Self::BatchEnd
            | Self::SetCursor { .. }
            | Self::SetCursorShape(_)
            | Self::SetTitle(_)
            | Self::SetWindowBg(_)
            | Self::DefineRegion(_)
            | Self::ClearRegion(_)
            | Self::DestroyRegion(_)
            | Self::SetActiveRegion(_)
            | Self::ScrollRegion { .. } => 0,
        }
    }
}

pub fn command_byte_size(bytes: &[u8]) -> Result<usize, DecodeError> {
    match generated_command_byte_size(bytes)? {
        Some(size) => Ok(size),
        None => decode_command(bytes).map(|command| command.custom_size()),
    }
}

fn generated_command_byte_size(bytes: &[u8]) -> Result<Option<usize>, DecodeError> {
    match command_size::command_size(bytes) {
        CommandSize::Sized(size) => Ok(Some(size)),
        CommandSize::Custom => Ok(None),
        CommandSize::Incomplete => Err(DecodeError::Malformed("incomplete command")),
        CommandSize::Unknown => Ok(None),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DrawText {
    pub row: u16,
    pub col: u16,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DrawStyledText {
    pub row: u16,
    pub col: u16,
    pub fg: u32,
    pub bg: u32,
    pub attrs: u16,
    pub ul_color: u32,
    pub blend: u8,
    pub font_weight: u8,
    pub font_id: u8,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Region {
    pub id: u16,
    pub parent_id: u16,
    pub role: u8,
    pub row: u16,
    pub col: u16,
    pub width: u16,
    pub height: u16,
    pub z_order: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    Empty,
    Malformed(&'static str),
    Utf8,
    UnknownOpcode(u8),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(formatter, "empty command"),
            Self::Malformed(message) => write!(formatter, "malformed command: {message}"),
            Self::Utf8 => write!(formatter, "invalid utf-8"),
            Self::UnknownOpcode(opcode) => write!(formatter, "unknown opcode 0x{opcode:02X}"),
        }
    }
}

pub fn decode_command(bytes: &[u8]) -> Result<Command, DecodeError> {
    let opcode = *bytes.first().ok_or(DecodeError::Empty)?;

    match opcode {
        opcodes::OP_CLEAR => Ok(Command::Clear),
        opcodes::OP_BATCH_END => Ok(Command::BatchEnd),
        opcodes::OP_DRAW_TEXT => decode_draw_text(bytes),
        opcodes::OP_DRAW_STYLED_TEXT => decode_draw_styled_text(bytes),
        opcodes::OP_SET_CURSOR => {
            require_len(bytes, 5, "set_cursor")?;
            Ok(Command::SetCursor {
                row: read_u16(bytes, 1),
                col: read_u16(bytes, 3),
            })
        }
        opcodes::OP_SET_CURSOR_SHAPE => {
            require_len(bytes, 2, "set_cursor_shape")?;
            Ok(Command::SetCursorShape(bytes[1]))
        }
        opcodes::OP_SET_TITLE => {
            require_len(bytes, 3, "set_title header")?;
            let len = read_u16(bytes, 1) as usize;
            let text = read_string(bytes, 3, len)?;
            Ok(Command::SetTitle(text))
        }
        opcodes::OP_SET_WINDOW_BG => {
            require_len(bytes, 4, "set_window_bg")?;
            Ok(Command::SetWindowBg(read_u24(bytes, 1)))
        }
        opcodes::OP_DEFINE_REGION => {
            require_len(bytes, 15, "define_region")?;
            Ok(Command::DefineRegion(Region {
                id: read_u16(bytes, 1),
                parent_id: read_u16(bytes, 3),
                role: bytes[5],
                row: read_u16(bytes, 6),
                col: read_u16(bytes, 8),
                width: read_u16(bytes, 10),
                height: read_u16(bytes, 12),
                z_order: bytes[14],
            }))
        }
        opcodes::OP_CLEAR_REGION => {
            decode_region_id(bytes, "clear_region").map(Command::ClearRegion)
        }
        opcodes::OP_DESTROY_REGION => {
            decode_region_id(bytes, "destroy_region").map(Command::DestroyRegion)
        }
        opcodes::OP_SET_ACTIVE_REGION => {
            decode_region_id(bytes, "set_active_region").map(Command::SetActiveRegion)
        }
        opcodes::OP_SCROLL_REGION => {
            require_len(bytes, 7, "scroll_region")?;
            Ok(Command::ScrollRegion {
                top: read_u16(bytes, 1),
                bottom: read_u16(bytes, 3),
                delta: read_i16(bytes, 5),
            })
        }
        opcodes::OP_MEASURE_TEXT => {
            require_len(bytes, 7, "measure_text header")?;
            let request_id = read_u32(bytes, 1);
            let len = read_u16(bytes, 5) as usize;
            let text = read_string(bytes, 7, len)?;
            Ok(Command::MeasureText { request_id, text })
        }
        opcodes::OP_SET_LANGUAGE => skip_len_at(bytes, 5),
        opcodes::OP_PARSE_BUFFER => skip_len32_at(bytes, 9),
        opcodes::OP_SET_HIGHLIGHT_QUERY
        | opcodes::OP_SET_INJECTION_QUERY
        | opcodes::OP_SET_FOLD_QUERY
        | opcodes::OP_SET_INDENT_QUERY
        | opcodes::OP_SET_TEXTOBJECT_QUERY
        | opcodes::OP_SET_TAGS_QUERY => skip_len32_at(bytes, 5),
        opcodes::OP_LOAD_GRAMMAR => skip_load_grammar(bytes),
        opcodes::OP_QUERY_LANGUAGE_AT | opcodes::OP_REQUEST_INDENT => {
            fixed_noop(bytes, 13, "fixed parser request")
        }
        opcodes::OP_REQUEST_TEXTOBJECT => skip_len_at(bytes, 17),
        opcodes::OP_CLOSE_BUFFER => fixed_noop(bytes, 5, "close_buffer"),
        opcodes::OP_REQUEST_MATCH_ITEM => fixed_noop(bytes, 17, "request_match_item"),
        opcodes::OP_REQUEST_STRUCTURAL_NAV => fixed_noop(bytes, 18, "request_structural_nav"),
        opcodes::OP_EDIT_BUFFER => skip_edit_buffer(bytes),
        opcodes::OP_SET_FONT => skip_len_at(bytes, 5),
        opcodes::OP_SET_FONT_FALLBACK => skip_font_fallback(bytes),
        opcodes::OP_REGISTER_FONT => skip_len_at(bytes, 2),
        _ if opcode >= 0x70 => match semantic::decode(bytes) {
            Ok(command) => Ok(Command::Semantic(command)),
            Err(DecodeError::UnknownOpcode(_)) => match generated_command_byte_size(bytes)? {
                Some(size) => Ok(Command::Noop(size)),
                None => Err(DecodeError::UnknownOpcode(opcode)),
            },
            Err(error) => Err(error),
        },
        _ => Err(DecodeError::UnknownOpcode(opcode)),
    }
}

pub fn write_packet(writer: &mut impl Write, payload: &[u8]) -> io::Result<()> {
    writer.write_all(&(payload.len() as u32).to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()
}

pub fn encode_ready_with_caps(width: u16, height: u16, image_support: u8) -> [u8; 14] {
    [
        opcodes::OP_READY,
        (width >> 8) as u8,
        width as u8,
        (height >> 8) as u8,
        height as u8,
        1,
        7,
        0,
        2,
        0,
        image_support,
        0,
        0,
        1,
    ]
}

pub fn encode_text_width(request_id: u32, width: u16) -> [u8; 7] {
    let req = request_id.to_be_bytes();
    [
        opcodes::OP_TEXT_WIDTH,
        req[0],
        req[1],
        req[2],
        req[3],
        (width >> 8) as u8,
        width as u8,
    ]
}

pub fn encode_key_press(codepoint: u32, modifiers: u8) -> [u8; 6] {
    let codepoint = codepoint.to_be_bytes();
    [
        opcodes::OP_KEY_PRESS,
        codepoint[0],
        codepoint[1],
        codepoint[2],
        codepoint[3],
        modifiers,
    ]
}

pub fn encode_resize(width: u16, height: u16) -> [u8; 5] {
    [
        opcodes::OP_RESIZE,
        (width >> 8) as u8,
        width as u8,
        (height >> 8) as u8,
        height as u8,
    ]
}

#[allow(dead_code)]
pub const LOG_LEVEL_ERR: u8 = 0;
pub const LOG_LEVEL_WARN: u8 = 1;
pub const LOG_LEVEL_INFO: u8 = 2;

pub fn encode_log_message(level: u8, msg: &str) -> Vec<u8> {
    let len = msg.len().min(u16::MAX as usize);
    let mut payload = Vec::with_capacity(4 + len);
    payload.push(opcodes::OP_LOG_MESSAGE);
    payload.push(level);
    payload.extend_from_slice(&(len as u16).to_be_bytes());
    payload.extend_from_slice(&msg.as_bytes()[..len]);
    payload
}

pub fn encode_paste_event(text: &[u8]) -> Vec<u8> {
    let len = text.len().min(u16::MAX as usize);
    let mut payload = Vec::with_capacity(3 + len);
    payload.push(opcodes::OP_PASTE_EVENT);
    payload.extend_from_slice(&(len as u16).to_be_bytes());
    payload.extend_from_slice(&text[..len]);
    payload
}

fn decode_draw_text(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 14, "draw_text header")?;
    let len = read_u16(bytes, 12) as usize;
    Ok(Command::DrawText(DrawText {
        row: read_u16(bytes, 1),
        col: read_u16(bytes, 3),
        fg: read_u24(bytes, 5),
        bg: read_u24(bytes, 8),
        attrs: bytes[11] as u16,
        text: read_string(bytes, 14, len)?,
    }))
}

fn decode_draw_styled_text(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 21, "draw_styled_text header")?;
    let len = read_u16(bytes, 19) as usize;
    Ok(Command::DrawStyledText(DrawStyledText {
        row: read_u16(bytes, 1),
        col: read_u16(bytes, 3),
        fg: read_u24(bytes, 5),
        bg: read_u24(bytes, 8),
        attrs: read_u16(bytes, 11),
        ul_color: read_u24(bytes, 13),
        blend: bytes[16],
        font_weight: bytes[17],
        font_id: bytes[18],
        text: read_string(bytes, 21, len)?,
    }))
}

fn decode_region_id(bytes: &[u8], name: &'static str) -> Result<u16, DecodeError> {
    require_len(bytes, 3, name)?;
    Ok(read_u16(bytes, 1))
}

fn skip_len_at(bytes: &[u8], len_offset: usize) -> Result<Command, DecodeError> {
    require_len(bytes, len_offset + 2, "length-prefixed command header")?;
    let len = read_u16(bytes, len_offset) as usize;
    require_len(bytes, len_offset + 2 + len, "length-prefixed command body")?;
    Ok(Command::Noop(len_offset + 2 + len))
}

fn skip_len32_at(bytes: &[u8], len_offset: usize) -> Result<Command, DecodeError> {
    require_len(bytes, len_offset + 4, "length32-prefixed command header")?;
    let len = read_u32(bytes, len_offset) as usize;
    require_len(
        bytes,
        len_offset + 4 + len,
        "length32-prefixed command body",
    )?;
    Ok(Command::Noop(len_offset + 4 + len))
}

fn fixed_noop(bytes: &[u8], size: usize, name: &'static str) -> Result<Command, DecodeError> {
    require_len(bytes, size, name)?;
    Ok(Command::Noop(size))
}

fn skip_font_fallback(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 2, "font fallback header")?;
    let count = bytes[1] as usize;
    let mut offset = 2;

    for _ in 0..count {
        require_len(bytes, offset + 2, "font fallback entry header")?;
        let len = read_u16(bytes, offset) as usize;
        offset += 2;
        require_len(bytes, offset + len, "font fallback entry body")?;
        offset += len;
    }

    Ok(Command::Noop(offset))
}

fn skip_load_grammar(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 3, "load_grammar name header")?;
    let name_len = read_u16(bytes, 1) as usize;
    let mut offset = 3 + name_len;
    require_len(bytes, offset + 2, "load_grammar path header")?;
    let path_len = read_u16(bytes, offset) as usize;
    offset += 2;
    require_len(bytes, offset + path_len, "load_grammar path body")?;
    Ok(Command::Noop(offset + path_len))
}

fn skip_edit_buffer(bytes: &[u8]) -> Result<Command, DecodeError> {
    require_len(bytes, 11, "edit_buffer header")?;
    let edit_count = read_u16(bytes, 9) as usize;
    let mut offset = 11;

    for _ in 0..edit_count {
        require_len(bytes, offset + 40, "edit_buffer edit header")?;
        let text_len = read_u32(bytes, offset + 36) as usize;
        offset += 40;
        require_len(bytes, offset + text_len, "edit_buffer edit text")?;
        offset += text_len;
    }

    Ok(Command::Noop(offset))
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

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_i16(bytes: &[u8], offset: usize) -> i16 {
    i16::from_be_bytes([bytes[offset], bytes[offset + 1]])
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
    fn decodes_draw_text() {
        let bytes = [
            opcodes::OP_DRAW_TEXT,
            0,
            1,
            0,
            2,
            0xAA,
            0xBB,
            0xCC,
            0,
            0,
            0,
            3,
            0,
            2,
            b'h',
            b'i',
        ];
        let command = decode_command(&bytes).unwrap();

        assert_eq!(
            command,
            Command::DrawText(DrawText {
                row: 1,
                col: 2,
                fg: 0xAABBCC,
                bg: 0,
                attrs: 3,
                text: "hi".to_owned(),
            })
        );
        assert_eq!(command_byte_size(&bytes).unwrap(), bytes.len());
    }

    #[test]
    fn encodes_extended_ready() {
        assert_eq!(
            encode_ready_with_caps(80, 24, 0),
            [opcodes::OP_READY, 0, 80, 0, 24, 1, 7, 0, 2, 0, 0, 0, 0, 1]
        );
    }

    #[test]
    fn decodes_draw_styled_text_size() {
        let bytes = [
            opcodes::OP_DRAW_STYLED_TEXT,
            0,
            1,
            0,
            2,
            0xAA,
            0xBB,
            0xCC,
            0,
            0,
            0,
            0,
            0x10,
            1,
            2,
            3,
            42,
            5,
            7,
            0,
            2,
            b'h',
            b'i',
        ];
        let command = decode_command(&bytes).unwrap();

        assert_eq!(command_byte_size(&bytes).unwrap(), bytes.len());
        assert!(
            matches!(command, Command::DrawStyledText(DrawStyledText { font_id: 7, text, .. }) if text == "hi")
        );
    }

    #[test]
    fn decodes_define_region_size() {
        let bytes = [
            opcodes::OP_DEFINE_REGION,
            0,
            1,
            0,
            0,
            4,
            0,
            2,
            0,
            3,
            0,
            80,
            0,
            12,
            9,
        ];
        let command = decode_command(&bytes).unwrap();

        assert_eq!(command_byte_size(&bytes).unwrap(), bytes.len());
        assert!(matches!(
            command,
            Command::DefineRegion(Region {
                id: 1,
                role: 4,
                row: 2,
                col: 3,
                width: 80,
                height: 12,
                z_order: 9,
                ..
            })
        ));
    }

    #[test]
    fn encodes_input_events() {
        assert_eq!(
            encode_key_press(57_352, MOD_CTRL),
            [opcodes::OP_KEY_PRESS, 0, 0, 224, 8, 2]
        );
        assert_eq!(encode_resize(120, 40), [opcodes::OP_RESIZE, 0, 120, 0, 40]);
        assert_eq!(
            encode_paste_event(b"hello"),
            vec![opcodes::OP_PASTE_EVENT, 0, 5, b'h', b'e', b'l', b'l', b'o']
        );
    }

    #[test]
    fn skips_parser_commands_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_SET_LANGUAGE, 0, 0, 0, 7, 0, 6],
            b"elixir".to_vec(),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();
        let command = decode_command(&packet).unwrap();

        let size = command_byte_size(&packet).unwrap();
        assert_eq!(size, packet.len() - 1);
        assert!(matches!(command, Command::Noop(_)));
        assert_eq!(decode_command(&packet[size..]).unwrap(), Command::BatchEnd);
    }

    #[test]
    fn skips_edit_buffer_without_consuming_following_commands() {
        let packet = [
            vec![opcodes::OP_EDIT_BUFFER, 0, 0, 0, 7, 0, 0, 0, 9, 0, 1],
            vec![0; 36],
            vec![0, 0, 0, 3],
            b"abc".to_vec(),
            vec![opcodes::OP_BATCH_END],
        ]
        .concat();
        let command = decode_command(&packet).unwrap();

        let size = command_byte_size(&packet).unwrap();
        assert_eq!(size, packet.len() - 1);
        assert!(matches!(command, Command::Noop(_)));
        assert_eq!(decode_command(&packet[size..]).unwrap(), Command::BatchEnd);
    }

    #[test]
    fn skips_generated_sized_unrendered_opcode_without_consuming_following_commands() {
        let packet = [vec![0xB7, 0, 2, 0xAA, 0xBB], vec![opcodes::OP_BATCH_END]].concat();
        let command = decode_command(&packet).unwrap();

        let size = command_byte_size(&packet).unwrap();
        assert_eq!(size, packet.len() - 1);
        assert!(matches!(command, Command::Noop(_)));
        assert_eq!(decode_command(&packet[size..]).unwrap(), Command::BatchEnd);
    }
}

#[cfg(test)]
mod command_size_conformance {
    use super::command_size::{CommandSize, command_size};
    use super::{command_byte_size, decode_command, opcodes};

    // Each case is a fully framed command. The generated command_size is the
    // reader's authority for schema-framed opcodes. The indent_guides (0x91)
    // case is the regression that desynced the Go reader.
    #[test]
    fn generated_size_matches_decoder() {
        let cases: &[(Vec<u8>, usize)] = &[
            (vec![opcodes::OP_CLEAR], 1),
            (vec![opcodes::OP_SET_CURSOR, 0, 0, 0, 0], 5),
            (vec![opcodes::OP_GUI_GUTTER_SEP, 0, 0, 0, 0, 0], 6),
            (
                vec![opcodes::OP_GUI_INDENT_GUIDES, 0x00, 0x06, 1, 2, 3, 4, 5, 0],
                9,
            ),
            (
                {
                    let mut v = vec![opcodes::OP_SET_TITLE, 0x00, 0x03];
                    v.extend_from_slice(b"abc");
                    v
                },
                6,
            ),
        ];

        for (bytes, expected) in cases {
            assert_eq!(
                command_size(bytes),
                CommandSize::Sized(*expected),
                "command_size mismatch for opcode 0x{:02X}",
                bytes[0]
            );
            let _decoded = decode_command(bytes).expect("decoder accepts framed command");
            assert_eq!(
                command_byte_size(bytes).unwrap(),
                *expected,
                "reader size disagrees with command_size for opcode 0x{:02X}",
                bytes[0]
            );
        }
    }

    #[test]
    fn custom_opcodes_defer_to_decoder() {
        assert_eq!(
            command_size(&[opcodes::OP_GUI_GIT_STATUS, 0, 0, 0, 0]),
            CommandSize::Custom
        );
    }

    #[test]
    fn unknown_high_opcode_is_forward_compatible_len16() {
        // A future 0x90+ opcode must still be skippable as len16.
        assert_eq!(
            command_size(&[0xB7, 0x00, 0x02, 0xAA, 0xBB]),
            CommandSize::Sized(5)
        );
    }
}
