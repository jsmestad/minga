//! Extension-owned Board payload support moved out of the Rust TUI core parity path.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Board {
    pub visible: u8,
    pub focused_card_id: u32,
    pub filter_mode: u8,
    pub filter_text: String,
    pub cards: Vec<BoardCard>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BoardCard {
    pub id: u32,
    pub status: u8,
    pub flags: u8,
    pub task: String,
    pub model: String,
    pub timestamp: u32,
    pub recent_files: Vec<String>,
}

pub fn decode_board(bytes: &[u8]) -> Result<(Board, usize), &'static str> {
    if bytes.len() < 11 {
        return Err("short board");
    }

    let visible = bytes[1];
    let focused_card_id = u32::from_be_bytes([bytes[2], bytes[3], bytes[4], bytes[5]]);
    let card_count = u16::from_be_bytes([bytes[6], bytes[7]]) as usize;
    let filter_mode = bytes[8];
    let (filter_text, mut offset) = read_string16(bytes, 9)?;
    let mut cards = Vec::with_capacity(card_count);

    for _ in 0..card_count {
        if bytes.len() < offset + 6 {
            return Err("short board card");
        }
        let id = u32::from_be_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]);
        let status = bytes[offset + 4];
        let flags = bytes[offset + 5];
        offset += 6;

        let (task, next) = read_string16(bytes, offset)?;
        offset = next;
        if bytes.len() < offset + 5 {
            return Err("short board card metadata");
        }
        let model_len = bytes[offset] as usize;
        offset += 1;
        if bytes.len() < offset + model_len + 5 {
            return Err("short board card model");
        }
        let model = String::from_utf8_lossy(&bytes[offset..offset + model_len]).to_string();
        offset += model_len;
        let timestamp = u32::from_be_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]);
        offset += 4;
        let file_count = bytes[offset] as usize;
        offset += 1;
        let mut recent_files = Vec::with_capacity(file_count);
        for _ in 0..file_count {
            let (file, next) = read_string16(bytes, offset)?;
            recent_files.push(file);
            offset = next;
        }
        if bytes.len() < offset + 1 {
            return Err("short board sparkline count");
        }
        let sparkline_count = bytes[offset] as usize;
        offset += 1;
        if bytes.len() < offset + sparkline_count * 2 {
            return Err("short board sparkline");
        }
        offset += sparkline_count * 2;

        cards.push(BoardCard {
            id,
            status,
            flags,
            task,
            model,
            timestamp,
            recent_files,
        });
    }

    Ok((
        Board {
            visible,
            focused_card_id,
            filter_mode,
            filter_text,
            cards,
        },
        offset,
    ))
}

pub fn render_lines(board: &Board, max_height: usize) -> Vec<String> {
    if board.visible == 0 || board.cards.is_empty() || max_height == 0 {
        return Vec::new();
    }

    let mut lines = vec![format!("Board  {} cards", board.cards.len())];
    for card in &board.cards {
        let marker = if card.id == board.focused_card_id || card.flags & 0x02 != 0 {
            ">"
        } else {
            " "
        };
        lines.push(format!(
            "{} {}  {}",
            marker,
            status_name(card.status),
            card.task
        ));
        if lines.len() >= max_height {
            break;
        }
    }
    lines
}

fn read_string16(bytes: &[u8], offset: usize) -> Result<(String, usize), &'static str> {
    if bytes.len() < offset + 2 {
        return Err("short string length");
    }
    let len = u16::from_be_bytes([bytes[offset], bytes[offset + 1]]) as usize;
    let start = offset + 2;
    let end = start + len;
    if bytes.len() < end {
        return Err("short string");
    }
    Ok((String::from_utf8_lossy(&bytes[start..end]).to_string(), end))
}

fn status_name(status: u8) -> &'static str {
    match status {
        0 => "idle",
        1 => "working",
        2 => "iterating",
        3 => "needs you",
        4 => "done",
        5 => "errored",
        _ => "unknown",
    }
}
