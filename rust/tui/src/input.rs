use crate::parity::{InputPolicy, PassiveMouseMotionPolicy};
use crate::protocol;
use crossterm::event::{
    Event as CrosstermEvent, KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};

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
    Key {
        codepoint: u32,
        modifiers: u8,
    },
    Paste(Vec<u8>),
    Resize {
        cols: u16,
        rows: u16,
    },
    Mouse {
        row: i16,
        col: i16,
        button: u8,
        modifiers: u8,
        event_type: u8,
        click_count: u8,
    },
}

pub fn map_crossterm_event_with_policy(
    event: CrosstermEvent,
    policy: InputPolicy,
) -> Option<Event> {
    match event {
        CrosstermEvent::Key(key) => map_key_event(key),
        CrosstermEvent::Paste(text) => Some(Event::Paste(text.into_bytes())),
        CrosstermEvent::Resize(cols, rows) => Some(Event::Resize { cols, rows }),
        CrosstermEvent::Mouse(mouse) => map_mouse_event(mouse, policy),
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
    if matches!(event.code, KeyCode::Char(_)) {
        modifiers &= !protocol::MOD_SHIFT;
    }
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

fn map_mouse_event(event: MouseEvent, policy: InputPolicy) -> Option<Event> {
    let (button, event_type) = match event.kind {
        MouseEventKind::Down(button) => (map_mouse_button(button), 0),
        MouseEventKind::Up(button) => (map_mouse_button(button), 1),
        MouseEventKind::Drag(button) => (map_mouse_button(button), 3),
        MouseEventKind::Moved => match policy.passive_mouse_motion {
            PassiveMouseMotionPolicy::Drop => return None,
        },
        MouseEventKind::ScrollUp => (0x40, 0),
        MouseEventKind::ScrollDown => (0x41, 0),
        MouseEventKind::ScrollLeft => (0x42, 0),
        MouseEventKind::ScrollRight => (0x43, 0),
    };

    Some(Event::Mouse {
        row: event.row as i16,
        col: event.column as i16,
        button,
        modifiers: map_modifiers(event.modifiers),
        event_type,
        click_count: 1,
    })
}

fn map_mouse_button(button: MouseButton) -> u8 {
    match button {
        MouseButton::Left => 0,
        MouseButton::Middle => 1,
        MouseButton::Right => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parity::GO_ZIG_PARITY;

    fn map(event: CrosstermEvent) -> Option<Event> {
        map_crossterm_event_with_policy(event, GO_ZIG_PARITY.input)
    }

    fn key(code: KeyCode, modifiers: KeyModifiers) -> Option<Event> {
        map(CrosstermEvent::Key(KeyEvent::new(code, modifiers)))
    }

    fn mouse(kind: MouseEventKind, modifiers: KeyModifiers) -> Option<Event> {
        map(CrosstermEvent::Mouse(MouseEvent {
            kind,
            column: 7,
            row: 5,
            modifiers,
        }))
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
            key(KeyCode::Char('T'), KeyModifiers::SHIFT),
            Some(Event::Key {
                codepoint: 'T' as u32,
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
    fn maps_logged_insert_sentence_without_printable_shift_modifiers() {
        let typed = "This is the thing that we're doing";

        for ch in typed.chars() {
            let modifiers = if ch.is_ascii_uppercase() {
                KeyModifiers::SHIFT
            } else {
                KeyModifiers::empty()
            };
            assert_eq!(
                key(KeyCode::Char(ch), modifiers),
                Some(Event::Key {
                    codepoint: ch as u32,
                    modifiers: 0
                }),
                "typed char {ch:?}"
            );
        }
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
            map(CrosstermEvent::Paste("hello".to_owned())),
            Some(Event::Paste(b"hello".to_vec()))
        );
    }

    #[test]
    fn maps_mouse_buttons_drag_wheel_and_modifiers() {
        assert_eq!(
            mouse(
                MouseEventKind::Down(MouseButton::Left),
                KeyModifiers::empty()
            ),
            Some(Event::Mouse {
                row: 5,
                col: 7,
                button: 0,
                modifiers: 0,
                event_type: 0,
                click_count: 1
            })
        );
        assert_eq!(
            mouse(MouseEventKind::Up(MouseButton::Right), KeyModifiers::SHIFT),
            Some(Event::Mouse {
                row: 5,
                col: 7,
                button: 2,
                modifiers: protocol::MOD_SHIFT,
                event_type: 1,
                click_count: 1
            })
        );
        assert_eq!(
            mouse(
                MouseEventKind::Drag(MouseButton::Middle),
                KeyModifiers::CONTROL
            ),
            Some(Event::Mouse {
                row: 5,
                col: 7,
                button: 1,
                modifiers: protocol::MOD_CTRL,
                event_type: 3,
                click_count: 1
            })
        );
        assert_eq!(
            mouse(MouseEventKind::ScrollDown, KeyModifiers::ALT),
            Some(Event::Mouse {
                row: 5,
                col: 7,
                button: 0x41,
                modifiers: protocol::MOD_ALT,
                event_type: 0,
                click_count: 1
            })
        );
    }

    #[test]
    fn drops_passive_mouse_motion() {
        assert_eq!(mouse(MouseEventKind::Moved, KeyModifiers::empty()), None);
    }
}
