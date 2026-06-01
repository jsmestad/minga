use crate::protocol;

const ESC: u8 = 0x1B;
const PASTE_START: &[u8] = b"\x1b[200~";
const PASTE_END: &[u8] = b"\x1b[201~";

const ARROW_LEFT: u32 = 57_350;
const ARROW_RIGHT: u32 = 57_351;
const ARROW_UP: u32 = 57_352;
const ARROW_DOWN: u32 = 57_353;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Key { codepoint: u32, modifiers: u8 },
    Paste(Vec<u8>),
}

#[derive(Debug, Default)]
pub struct Parser {
    pending: Vec<u8>,
    paste: Vec<u8>,
    in_paste: bool,
}

impl Parser {
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Event> {
        self.pending.extend_from_slice(bytes);
        self.drain(false)
    }

    pub fn flush_escape(&mut self) -> Vec<Event> {
        self.drain(true)
    }

    fn drain(&mut self, flush_escape: bool) -> Vec<Event> {
        let mut events = Vec::new();

        loop {
            if self.in_paste {
                match find_bytes(&self.pending, PASTE_END) {
                    Some(pos) => {
                        self.paste.extend_from_slice(&self.pending[..pos]);
                        self.pending.drain(..pos + PASTE_END.len());
                        if !self.paste.is_empty() {
                            events.push(Event::Paste(std::mem::take(&mut self.paste)));
                        }
                        self.in_paste = false;
                    }
                    None => {
                        let keep = paste_end_prefix_suffix(&self.pending);
                        let paste_len = self.pending.len().saturating_sub(keep);
                        self.paste.extend_from_slice(&self.pending[..paste_len]);
                        self.pending.drain(..paste_len);
                        break;
                    }
                }
                continue;
            }

            if self.pending.is_empty() {
                break;
            }

            if self.pending.starts_with(PASTE_START) {
                self.pending.drain(..PASTE_START.len());
                self.paste.clear();
                self.in_paste = true;
                continue;
            }

            if self.pending[0] == ESC {
                match parse_escape(&self.pending, flush_escape) {
                    ParseResult::Event(event, used) => {
                        self.pending.drain(..used);
                        events.push(event);
                    }
                    ParseResult::NeedMore => break,
                    ParseResult::Ignore(used) => {
                        self.pending.drain(..used);
                    }
                }
                continue;
            }

            let byte = self.pending[0];
            match std::str::from_utf8(&self.pending) {
                Ok(text) => {
                    if let Some(ch) = text.chars().next() {
                        let len = ch.len_utf8();
                        self.pending.drain(..len);
                        events.push(Event::Key {
                            codepoint: ch as u32,
                            modifiers: 0,
                        });
                    } else {
                        break;
                    }
                }
                Err(error) if error.valid_up_to() > 0 => {
                    let valid = error.valid_up_to();
                    let first = std::str::from_utf8(&self.pending[..valid])
                        .ok()
                        .and_then(|text| text.chars().next());
                    if let Some(ch) = first {
                        let len = ch.len_utf8();
                        self.pending.drain(..len);
                        events.push(Event::Key {
                            codepoint: ch as u32,
                            modifiers: 0,
                        });
                    } else {
                        self.pending.drain(..valid);
                    }
                }
                Err(error) if error.error_len().is_none() => break,
                Err(_) => {
                    self.pending.drain(..1);
                    events.push(Event::Key {
                        codepoint: byte as u32,
                        modifiers: 0,
                    });
                }
            }
        }

        events
    }
}

enum ParseResult {
    Event(Event, usize),
    NeedMore,
    Ignore(usize),
}

fn parse_escape(bytes: &[u8], flush_escape: bool) -> ParseResult {
    if bytes.len() == 1 {
        if flush_escape {
            return ParseResult::Event(
                Event::Key {
                    codepoint: ESC as u32,
                    modifiers: 0,
                },
                1,
            );
        }
        return ParseResult::NeedMore;
    }

    match bytes[1] {
        b'[' => parse_csi(bytes),
        b'O' => parse_ss3(bytes),
        _ => ParseResult::Event(
            Event::Key {
                codepoint: bytes[1] as u32,
                modifiers: protocol::MOD_ALT,
            },
            2,
        ),
    }
}

fn parse_csi(bytes: &[u8]) -> ParseResult {
    let Some(relative_end) = bytes[2..]
        .iter()
        .position(|byte| (0x40..=0x7E).contains(byte))
    else {
        return ParseResult::NeedMore;
    };
    let end = relative_end + 2;
    let final_byte = bytes[end];
    let params = std::str::from_utf8(&bytes[2..end]).unwrap_or("");
    let modifiers = csi_modifiers(params);

    let codepoint = match final_byte {
        b'A' => ARROW_UP,
        b'B' => ARROW_DOWN,
        b'C' => ARROW_RIGHT,
        b'D' => ARROW_LEFT,
        b'~' => match params.split(';').next().unwrap_or("") {
            "1" | "7" => ARROW_UP,
            "4" | "8" => ARROW_DOWN,
            _ => return ParseResult::Ignore(end + 1),
        },
        _ => return ParseResult::Ignore(end + 1),
    };

    ParseResult::Event(
        Event::Key {
            codepoint,
            modifiers,
        },
        end + 1,
    )
}

fn parse_ss3(bytes: &[u8]) -> ParseResult {
    if bytes.len() < 3 {
        return ParseResult::NeedMore;
    }

    let codepoint = match bytes[2] {
        b'A' => ARROW_UP,
        b'B' => ARROW_DOWN,
        b'C' => ARROW_RIGHT,
        b'D' => ARROW_LEFT,
        _ => return ParseResult::Ignore(3),
    };

    ParseResult::Event(
        Event::Key {
            codepoint,
            modifiers: 0,
        },
        3,
    )
}

fn csi_modifiers(params: &str) -> u8 {
    let raw = params
        .split(';')
        .filter_map(|part| part.parse::<u8>().ok())
        .next_back()
        .unwrap_or(1);
    let bits = raw.saturating_sub(1);
    let mut modifiers = 0;

    if bits & 0x01 != 0 {
        modifiers |= protocol::MOD_SHIFT;
    }
    if bits & 0x02 != 0 {
        modifiers |= protocol::MOD_ALT;
    }
    if bits & 0x04 != 0 {
        modifiers |= protocol::MOD_CTRL;
    }

    modifiers
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn paste_end_prefix_suffix(bytes: &[u8]) -> usize {
    let max = bytes.len().min(PASTE_END.len().saturating_sub(1));
    (1..=max)
        .rev()
        .find(|len| bytes[bytes.len() - len..] == PASTE_END[..*len])
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_utf8_keys() {
        let mut parser = Parser::default();

        assert_eq!(
            parser.push("a©".as_bytes()),
            vec![
                Event::Key {
                    codepoint: b'a' as u32,
                    modifiers: 0
                },
                Event::Key {
                    codepoint: '©' as u32,
                    modifiers: 0
                }
            ]
        );
    }

    #[test]
    fn parses_arrow_keys_and_modifiers() {
        let mut parser = Parser::default();

        assert_eq!(
            parser.push(b"\x1b[A\x1b[1;5B"),
            vec![
                Event::Key {
                    codepoint: ARROW_UP,
                    modifiers: 0
                },
                Event::Key {
                    codepoint: ARROW_DOWN,
                    modifiers: protocol::MOD_CTRL
                }
            ]
        );
    }

    #[test]
    fn accumulates_bracketed_paste_across_chunks() {
        let mut parser = Parser::default();

        assert_eq!(parser.push(b"\x1b[200~hello"), Vec::<Event>::new());
        assert_eq!(
            parser.push(b" world\x1b[201~a"),
            vec![
                Event::Paste(b"hello world".to_vec()),
                Event::Key {
                    codepoint: b'a' as u32,
                    modifiers: 0
                }
            ]
        );
    }

    #[test]
    fn recognizes_paste_end_split_across_chunks() {
        let mut parser = Parser::default();

        assert_eq!(parser.push(b"\x1b[200~hello\x1b[20"), Vec::<Event>::new());
        assert_eq!(parser.push(b"1~"), vec![Event::Paste(b"hello".to_vec())]);
    }

    #[test]
    fn flushes_standalone_escape_after_timeout() {
        let mut parser = Parser::default();

        assert_eq!(parser.push(b"\x1b"), Vec::<Event>::new());
        assert_eq!(
            parser.flush_escape(),
            vec![Event::Key {
                codepoint: ESC as u32,
                modifiers: 0
            }]
        );
    }
}
