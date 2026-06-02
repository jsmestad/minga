use crate::protocol;
use termwiz::input::{InputEvent as TermwizInputEvent, InputParser, KeyCode, KeyEvent, Modifiers};

const ESC: u8 = 0x1B;
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
    inner: InputParser,
}

impl Parser {
    pub fn push(&mut self, bytes: &[u8]) -> Vec<Event> {
        self.inner
            .parse_as_vec(bytes, true)
            .into_iter()
            .filter_map(map_termwiz_event)
            .collect()
    }

    pub fn flush_escape(&mut self) -> Vec<Event> {
        self.inner
            .parse_as_vec(&[], false)
            .into_iter()
            .filter_map(map_termwiz_event)
            .collect()
    }
}

fn map_termwiz_event(event: TermwizInputEvent) -> Option<Event> {
    match event {
        TermwizInputEvent::Key(key) => map_key_event(key),
        TermwizInputEvent::Paste(text) => Some(Event::Paste(text.into_bytes())),
        _ => None,
    }
}

fn map_key_event(event: KeyEvent) -> Option<Event> {
    let codepoint = match event.key {
        KeyCode::Char(ch) => ch as u32,
        KeyCode::Escape => ESC as u32,
        KeyCode::Backspace => 127,
        KeyCode::Enter => 13,
        KeyCode::Tab => 9,
        KeyCode::LeftArrow | KeyCode::ApplicationLeftArrow => ARROW_LEFT,
        KeyCode::RightArrow | KeyCode::ApplicationRightArrow => ARROW_RIGHT,
        KeyCode::UpArrow | KeyCode::ApplicationUpArrow => ARROW_UP,
        KeyCode::DownArrow | KeyCode::ApplicationDownArrow => ARROW_DOWN,
        KeyCode::Home => ARROW_UP,
        KeyCode::End => ARROW_DOWN,
        _ => return None,
    };

    Some(Event::Key {
        codepoint,
        modifiers: map_modifiers(event.modifiers),
    })
}

fn map_modifiers(termwiz: Modifiers) -> u8 {
    let mut modifiers = 0;

    if termwiz.contains(Modifiers::SHIFT) {
        modifiers |= protocol::MOD_SHIFT;
    }
    if termwiz.contains(Modifiers::ALT) {
        modifiers |= protocol::MOD_ALT;
    }
    if termwiz.contains(Modifiers::CTRL) {
        modifiers |= protocol::MOD_CTRL;
    }

    modifiers
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
