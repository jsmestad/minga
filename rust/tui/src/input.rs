use crate::protocol;
use crossterm::event::{Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers};

const ESC: u8 = 0x1B;
const ARROW_LEFT: u32 = 57_350;
const ARROW_RIGHT: u32 = 57_351;
const ARROW_UP: u32 = 57_352;
const ARROW_DOWN: u32 = 57_353;
const FORWARD_DELETE: u32 = 0xF728;
const HOME: u32 = 0xF729;
const END: u32 = 0xF72B;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Key { codepoint: u32, modifiers: u8 },
    Paste(Vec<u8>),
    Resize { cols: u16, rows: u16 },
}

pub fn map_crossterm_event(event: CrosstermEvent) -> Option<Event> {
    match event {
        CrosstermEvent::Key(key) => map_key_event(key),
        CrosstermEvent::Paste(text) => Some(Event::Paste(text.into_bytes())),
        CrosstermEvent::Resize(cols, rows) => Some(Event::Resize { cols, rows }),
        _ => None,
    }
}

fn map_key_event(event: KeyEvent) -> Option<Event> {
    let codepoint = match event.code {
        KeyCode::Char(ch) => ch as u32,
        KeyCode::Esc => ESC as u32,
        KeyCode::Backspace => 127,
        KeyCode::Enter => 13,
        KeyCode::Tab => 9,
        KeyCode::BackTab => 9,
        KeyCode::Left => ARROW_LEFT,
        KeyCode::Right => ARROW_RIGHT,
        KeyCode::Up => ARROW_UP,
        KeyCode::Down => ARROW_DOWN,
        KeyCode::Home => HOME,
        KeyCode::End => END,
        KeyCode::Delete => FORWARD_DELETE,
        _ => return None,
    };

    let mut modifiers = map_modifiers(event.modifiers);
    if matches!(event.code, KeyCode::BackTab) {
        modifiers |= protocol::MOD_SHIFT;
    }

    Some(Event::Key {
        codepoint,
        modifiers,
    })
}

fn map_modifiers(crossterm: KeyModifiers) -> u8 {
    let mut modifiers = 0;

    if crossterm.contains(KeyModifiers::SHIFT) {
        modifiers |= protocol::MOD_SHIFT;
    }
    if crossterm.contains(KeyModifiers::ALT) {
        modifiers |= protocol::MOD_ALT;
    }
    if crossterm.contains(KeyModifiers::CONTROL) {
        modifiers |= protocol::MOD_CTRL;
    }
    if crossterm.contains(KeyModifiers::SUPER) {
        modifiers |= protocol::MOD_SUPER;
    }

    modifiers
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode, modifiers: KeyModifiers) -> Option<Event> {
        map_crossterm_event(CrosstermEvent::Key(KeyEvent::new(code, modifiers)))
    }

    #[test]
    fn maps_plain_utf8_keys() {
        assert_eq!(
            key(KeyCode::Char('a'), KeyModifiers::empty()),
            Some(Event::Key {
                codepoint: b'a' as u32,
                modifiers: 0
            })
        );
        assert_eq!(
            key(KeyCode::Char('©'), KeyModifiers::empty()),
            Some(Event::Key {
                codepoint: '©' as u32,
                modifiers: 0
            })
        );
    }

    #[test]
    fn maps_arrow_keys_and_modifiers() {
        assert_eq!(
            key(KeyCode::Up, KeyModifiers::empty()),
            Some(Event::Key {
                codepoint: ARROW_UP,
                modifiers: 0
            })
        );
        assert_eq!(
            key(KeyCode::Down, KeyModifiers::CONTROL),
            Some(Event::Key {
                codepoint: ARROW_DOWN,
                modifiers: protocol::MOD_CTRL
            })
        );
    }

    #[test]
    fn maps_home_and_end_to_line_navigation_codepoints() {
        assert_eq!(
            key(KeyCode::Home, KeyModifiers::empty()),
            Some(Event::Key {
                codepoint: HOME,
                modifiers: 0
            })
        );
        assert_eq!(
            key(KeyCode::End, KeyModifiers::SHIFT),
            Some(Event::Key {
                codepoint: END,
                modifiers: protocol::MOD_SHIFT
            })
        );
    }

    #[test]
    fn maps_tab_enter_delete_and_paste() {
        assert_eq!(
            key(KeyCode::Tab, KeyModifiers::empty()),
            Some(Event::Key {
                codepoint: 9,
                modifiers: 0
            })
        );
        assert_eq!(
            key(KeyCode::Enter, KeyModifiers::ALT),
            Some(Event::Key {
                codepoint: 13,
                modifiers: protocol::MOD_ALT
            })
        );
        assert_eq!(
            key(KeyCode::Delete, KeyModifiers::empty()),
            Some(Event::Key {
                codepoint: FORWARD_DELETE,
                modifiers: 0
            })
        );
        assert_eq!(
            map_crossterm_event(CrosstermEvent::Paste("hello".to_owned())),
            Some(Event::Paste(b"hello".to_vec()))
        );
    }
}
