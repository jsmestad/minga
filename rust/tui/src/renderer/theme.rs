use crate::semantic;
use ratatui::style::{Color, Modifier, Style};

const EDITOR_BG: u8 = 0x01;
const EDITOR_FG: u8 = 0x02;
const TREE_BG: u8 = 0x03;
const TREE_FG: u8 = 0x04;
const TREE_SELECTION_BG: u8 = 0x05;
const TREE_DIR_FG: u8 = 0x06;
const TREE_SELECTION_FG: u8 = 0x0E;
const TAB_BG: u8 = 0x10;
const TAB_ACTIVE_BG: u8 = 0x11;
const TAB_ACTIVE_FG: u8 = 0x12;
const TAB_INACTIVE_FG: u8 = 0x13;
const POPUP_BG: u8 = 0x20;
const POPUP_FG: u8 = 0x21;
const POPUP_SEL_BG: u8 = 0x23;
const POPUP_SEL_FG: u8 = 0x2A;
const POPUP_KEY_FG: u8 = 0x24;
const POPUP_DESC_FG: u8 = 0x26;
const MODELINE_BAR_BG: u8 = 0x30;
const MODELINE_BAR_FG: u8 = 0x31;
const GUTTER_FG: u8 = 0x50;
const GUTTER_ERROR_FG: u8 = 0x52;
const GUTTER_WARNING_FG: u8 = 0x53;
const GUTTER_INFO_FG: u8 = 0x54;
const GUTTER_HINT_FG: u8 = 0x55;
const HIGHLIGHT_READ_BG: u8 = 0x59;
const HIGHLIGHT_WRITE_BG: u8 = 0x5A;
const SELECTION_BG: u8 = 0x5B;
const ACCENT: u8 = 0x40;

pub fn canvas(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, EDITOR_FG, 0xBBC2CF))
        .bg(slot(theme, EDITOR_BG, 0x282C34))
}

pub fn status_bar(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, MODELINE_BAR_FG, 0xBBC2CF))
        .bg(slot(theme, MODELINE_BAR_BG, 0x5B6268))
}

pub fn minibuffer(theme: Option<&semantic::Theme>) -> Style {
    popup(theme)
}

pub fn overlay(theme: Option<&semantic::Theme>) -> Style {
    popup(theme)
}

pub fn muted(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, POPUP_DESC_FG, 0x8A93A5))
        .bg(slot(theme, EDITOR_BG, 0x282C34))
}

pub fn gutter(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, GUTTER_FG, 0x5B6268))
        .bg(slot(theme, EDITOR_BG, 0x282C34))
}

pub fn selected(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, POPUP_SEL_FG, 0xFFFFFF))
        .bg(slot(theme, POPUP_SEL_BG, 0x3E4451))
}

pub fn tree(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, TREE_FG, 0xBBC2CF))
        .bg(slot(theme, TREE_BG, 0x282C34))
}

pub fn tree_dir(theme: Option<&semantic::Theme>) -> Style {
    tree(theme).fg(slot(theme, TREE_DIR_FG, 0x61AFEF))
}

pub fn tree_selected(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, TREE_SELECTION_FG, 0xBBC2CF))
        .bg(slot(theme, TREE_SELECTION_BG, 0x3E4451))
}

pub fn tab(theme: Option<&semantic::Theme>, active: bool) -> Style {
    if active {
        Style::default()
            .fg(slot(theme, TAB_ACTIVE_FG, 0x282C34))
            .bg(slot(theme, TAB_ACTIVE_BG, 0x61AFEF))
            .add_modifier(Modifier::BOLD)
    } else {
        Style::default()
            .fg(slot(theme, TAB_INACTIVE_FG, 0x8A93A5))
            .bg(slot(theme, TAB_BG, 0x282C34))
    }
}

pub fn binding_key(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, POPUP_KEY_FG, 0x56B6C2))
        .add_modifier(Modifier::BOLD)
}

pub fn diagnostic(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, GUTTER_ERROR_FG, 0xE06C75))
        .bg(slot(theme, EDITOR_BG, 0x282C34))
        .add_modifier(Modifier::BOLD)
}

pub fn selection_bg(theme: Option<&semantic::Theme>) -> Color {
    slot(theme, SELECTION_BG, 0x3E4451)
}

pub fn document_highlight_bg(theme: Option<&semantic::Theme>, kind: u8) -> Color {
    match kind {
        2 => slot(theme, HIGHLIGHT_WRITE_BG, 0x3F4834),
        3 => slot(theme, HIGHLIGHT_READ_BG, 0x314158),
        _ => slot(theme, HIGHLIGHT_READ_BG, 0x2D3A4A),
    }
}

pub fn search_match_bg(theme: Option<&semantic::Theme>, current: bool) -> Color {
    if current {
        slot(theme, ACCENT, 0x785222)
    } else {
        slot(theme, HIGHLIGHT_READ_BG, 0x4E4026)
    }
}

pub fn diagnostic_fg(theme: Option<&semantic::Theme>, severity: u8) -> Color {
    match severity {
        0 | 1 => slot(theme, GUTTER_ERROR_FG, 0xE06C75),
        2 => slot(theme, GUTTER_WARNING_FG, 0xE5C07B),
        3 => slot(theme, GUTTER_INFO_FG, 0x61AFEF),
        _ => slot(theme, GUTTER_HINT_FG, 0x8A93A5),
    }
}

pub fn semantic(fg: u32, bg: u32, attrs: u16) -> Style {
    let mut style = Style::default();
    if fg != 0 {
        style = style.fg(rgb(fg));
    }
    if bg != 0 {
        style = style.bg(rgb(bg));
    }
    if attrs & 0x01 != 0 {
        style = style.add_modifier(Modifier::BOLD);
    }
    if attrs & 0x02 != 0 {
        style = style.add_modifier(Modifier::ITALIC);
    }
    style
}

pub fn rgb(value: u32) -> Color {
    Color::Rgb(
        ((value >> 16) & 0xFF) as u8,
        ((value >> 8) & 0xFF) as u8,
        (value & 0xFF) as u8,
    )
}

fn popup(theme: Option<&semantic::Theme>) -> Style {
    Style::default()
        .fg(slot(theme, POPUP_FG, 0xBBC2CF))
        .bg(slot(theme, POPUP_BG, 0x21252B))
}

fn slot(theme: Option<&semantic::Theme>, id: u8, fallback: u32) -> Color {
    theme
        .and_then(|theme| {
            theme
                .slots
                .iter()
                .find(|slot| slot.id == id)
                .map(|slot| rgb(slot.rgb))
        })
        .unwrap_or_else(|| rgb(fallback))
}
