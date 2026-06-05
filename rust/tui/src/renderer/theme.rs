use crate::semantic;
use ratatui::style::{Color, Modifier, Style};

const EDITOR_BG: u8 = 0x01;
const EDITOR_FG: u8 = 0x02;
const TREE_BG: u8 = 0x03;
const TREE_FG: u8 = 0x04;
const TREE_SELECTION_BG: u8 = 0x05;
const TREE_DIR_FG: u8 = 0x06;
// Reserved protocol color slots whose Palette accessors are defined ahead of
// the renderer surfaces that will consume them; allowed dead until then.
#[allow(dead_code)]
const TREE_HEADER_BG: u8 = 0x08;
#[allow(dead_code)]
const TREE_HEADER_FG: u8 = 0x09;
const TREE_SELECTION_FG: u8 = 0x0E;
const TAB_BG: u8 = 0x10;
const TAB_ACTIVE_BG: u8 = 0x11;
const TAB_ACTIVE_FG: u8 = 0x12;
const TAB_INACTIVE_FG: u8 = 0x13;
const TAB_MODIFIED_FG: u8 = 0x14;
const TAB_ATTENTION_FG: u8 = 0x17;
const POPUP_BG: u8 = 0x20;
const POPUP_FG: u8 = 0x21;
const POPUP_BORDER: u8 = 0x22;
const POPUP_SEL_BG: u8 = 0x23;
#[allow(dead_code)]
const POPUP_KEY_FG: u8 = 0x24;
const POPUP_DESC_FG: u8 = 0x26;
const BREADCRUMB_BG: u8 = 0x27;
const POPUP_SEL_FG: u8 = 0x2A;
const MODELINE_BAR_BG: u8 = 0x30;
const MODELINE_BAR_FG: u8 = 0x31;
const ACCENT: u8 = 0x40;
const GUTTER_FG: u8 = 0x50;
#[allow(dead_code)]
const GUTTER_CURRENT_FG: u8 = 0x51;
const GUTTER_ERROR_FG: u8 = 0x52;
const GUTTER_WARNING_FG: u8 = 0x53;
const GUTTER_INFO_FG: u8 = 0x54;
const GUTTER_HINT_FG: u8 = 0x55;
const HIGHLIGHT_READ_BG: u8 = 0x59;
const HIGHLIGHT_WRITE_BG: u8 = 0x5A;
const SELECTION_BG: u8 = 0x5B;

#[derive(Debug, Clone, Copy)]
pub struct Palette<'a> {
    theme: Option<&'a semantic::Theme>,
}

impl<'a> Palette<'a> {
    pub fn new(theme: Option<&'a semantic::Theme>) -> Self {
        Self { theme }
    }

    pub fn editor_surface(&self) -> Style {
        Style::default()
            .fg(self.slot(EDITOR_FG, 0xBBC2CF))
            .bg(self.slot(EDITOR_BG, 0x282C34))
    }

    pub fn editor_text(&self) -> Color {
        self.slot(EDITOR_FG, 0xBBC2CF)
    }

    pub fn editor_bg(&self) -> Color {
        self.slot(EDITOR_BG, 0x282C34)
    }

    #[allow(dead_code)]
    pub fn base(&self) -> Style {
        Style::default()
            .fg(self.slot(MODELINE_BAR_FG, 0xBBC2CF))
            .bg(self.slot(MODELINE_BAR_BG, 0x22252D))
    }

    #[allow(dead_code)]
    pub fn surface(&self) -> Style {
        Style::default()
            .fg(self.slot(EDITOR_FG, 0xBBC2CF))
            .bg(self.slot(TAB_BG, 0x282C34))
    }

    #[allow(dead_code)]
    pub fn surface_alt(&self) -> Style {
        Style::default()
            .fg(self.slot(EDITOR_FG, 0xBBC2CF))
            .bg(self.slot(BREADCRUMB_BG, 0x21242B))
    }

    pub fn muted(&self) -> Style {
        Style::default()
            .fg(self.slot(POPUP_DESC_FG, 0x8A93A5))
            .bg(self.slot(EDITOR_BG, 0x282C34))
    }

    pub fn accent(&self) -> Color {
        self.slot(ACCENT, 0x51AFEF)
    }

    pub fn status_bar(&self) -> Style {
        Style::default()
            .fg(self.slot(MODELINE_BAR_FG, 0xBBC2CF))
            .bg(self.slot(MODELINE_BAR_BG, 0x22252D))
    }

    pub fn minibuffer(&self) -> Style {
        self.popup()
    }

    pub fn overlay(&self) -> Style {
        self.popup()
    }

    pub fn gutter(&self) -> Style {
        Style::default()
            .fg(self.slot(GUTTER_FG, 0x5B6268))
            .bg(self.slot(EDITOR_BG, 0x282C34))
    }

    pub fn gutter_fg(&self) -> Color {
        self.slot(GUTTER_FG, 0x5B6268)
    }

    #[allow(dead_code)]
    pub fn gutter_current(&self) -> Style {
        Style::default()
            .fg(self.slot(GUTTER_CURRENT_FG, 0xBBC2CF))
            .bg(self.slot(EDITOR_BG, 0x282C34))
    }

    pub fn selection(&self) -> Color {
        self.slot(SELECTION_BG, 0x264F78)
    }

    #[allow(dead_code)]
    pub fn selection_text(&self) -> Color {
        self.slot(POPUP_SEL_FG, 0xF2F5FF)
    }

    pub fn popup(&self) -> Style {
        Style::default()
            .fg(self.slot(POPUP_FG, 0xD7DDF0))
            .bg(self.slot(POPUP_BG, 0x252A38))
    }

    pub fn popup_border(&self) -> Color {
        self.slot(POPUP_BORDER, 0x7A849B)
    }

    pub fn popup_selection(&self) -> Style {
        Style::default()
            .fg(self.slot(POPUP_SEL_FG, 0xF2F5FF))
            .bg(self.slot(POPUP_SEL_BG, 0x2F3650))
    }

    #[allow(dead_code)]
    pub fn popup_key(&self) -> Style {
        Style::default()
            .fg(self.slot(POPUP_KEY_FG, 0x56B6C2))
            .add_modifier(Modifier::BOLD)
    }

    pub fn tree(&self) -> Style {
        Style::default()
            .fg(self.slot(TREE_FG, 0xBBC2CF))
            .bg(self.slot(TREE_BG, 0x21242B))
    }

    pub fn tree_dir(&self) -> Style {
        self.tree().fg(self.slot(TREE_DIR_FG, 0x61AFEF))
    }

    pub fn tree_selection(&self) -> Style {
        Style::default()
            .fg(self.slot(TREE_SELECTION_FG, 0xBBC2CF))
            .bg(self.slot(TREE_SELECTION_BG, 0x3E4451))
    }

    #[allow(dead_code)]
    pub fn tree_header(&self) -> Style {
        Style::default()
            .fg(self.slot(TREE_HEADER_FG, 0xBBC2CF))
            .bg(self.slot(TREE_HEADER_BG, 0x282C34))
    }

    pub fn tab_active(&self) -> Style {
        Style::default()
            .fg(self.slot(TAB_ACTIVE_FG, 0xFFFFFF))
            .bg(self.slot(TAB_ACTIVE_BG, 0x3E4451))
            .add_modifier(Modifier::BOLD)
    }

    pub fn tab_inactive(&self) -> Style {
        Style::default()
            .fg(self.slot(TAB_INACTIVE_FG, 0x5B6268))
            .bg(self.slot(TAB_BG, 0x282C34))
    }

    pub fn tab_dirty(&self) -> Color {
        self.slot(TAB_MODIFIED_FG, 0xFF6C6B)
    }

    pub fn tab_attention(&self) -> Color {
        self.slot(TAB_ATTENTION_FG, 0xECBE7B)
    }

    pub fn diagnostic_style(&self) -> Style {
        Style::default()
            .fg(self.slot(GUTTER_ERROR_FG, 0xFF6C6B))
            .bg(self.slot(EDITOR_BG, 0x282C34))
            .add_modifier(Modifier::BOLD)
    }

    pub fn diagnostic_fg(&self, severity: u8) -> Color {
        match severity {
            0 => self.slot(GUTTER_ERROR_FG, 0xFF6C6B),
            1 => self.slot(GUTTER_WARNING_FG, 0xECBE7B),
            2 => self.slot(GUTTER_INFO_FG, 0x51AFEF),
            3 => self.slot(GUTTER_HINT_FG, 0x98BE65),
            _ => self.slot(GUTTER_WARNING_FG, 0xECBE7B),
        }
    }

    pub fn warning(&self) -> Color {
        self.slot(GUTTER_WARNING_FG, 0xECBE7B)
    }

    pub fn document_highlight(&self, kind: u8) -> Color {
        match kind {
            3 => self.slot(HIGHLIGHT_WRITE_BG, 0x4A3F2B),
            2 => self.slot(HIGHLIGHT_READ_BG, 0x3A3F4B),
            _ => self.slot(SELECTION_BG, 0x264F78),
        }
    }

    pub fn search_match(&self, current: bool) -> Color {
        if current {
            self.slot(TREE_SELECTION_BG, 0x3E4451)
        } else {
            self.slot(BREADCRUMB_BG, 0x21242B)
        }
    }

    fn slot(&self, id: u8, fallback: u32) -> Color {
        self.theme
            .and_then(|theme| theme.slots.iter().find(|s| s.id == id).map(|s| rgb(s.rgb)))
            .unwrap_or_else(|| rgb(fallback))
    }
}

pub fn selection_bg(theme: Option<&semantic::Theme>) -> Color {
    Palette::new(theme).selection()
}

pub fn document_highlight_bg(theme: Option<&semantic::Theme>, kind: u8) -> Color {
    Palette::new(theme).document_highlight(kind)
}

pub fn search_match_bg(theme: Option<&semantic::Theme>, current: bool) -> Color {
    Palette::new(theme).search_match(current)
}

pub fn diagnostic_fg(theme: Option<&semantic::Theme>, severity: u8) -> Color {
    Palette::new(theme).diagnostic_fg(severity)
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
        style = style.add_modifier(Modifier::UNDERLINED);
    }
    if attrs & 0x04 != 0 {
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
