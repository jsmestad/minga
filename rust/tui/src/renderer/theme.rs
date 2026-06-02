use crate::protocol;
use crate::semantic;
use crate::terminal::CellStyle;
use std::collections::HashMap;

pub(super) const SLOT_EDITOR_BG: u8 = 0x01;
const SLOT_EDITOR_FG: u8 = 0x02;
const SLOT_TREE_BG: u8 = 0x03;
const SLOT_TREE_FG: u8 = 0x04;
const SLOT_TREE_SELECTION_BG: u8 = 0x05;
const SLOT_TREE_ACTIVE_FG: u8 = 0x07;
const SLOT_TAB_BG: u8 = 0x10;
const SLOT_TAB_ACTIVE_BG: u8 = 0x11;
const SLOT_TAB_ACTIVE_FG: u8 = 0x12;
const SLOT_TAB_INACTIVE_FG: u8 = 0x13;
pub(super) const SLOT_POPUP_BG: u8 = 0x20;
pub(super) const SLOT_POPUP_FG: u8 = 0x21;
const SLOT_POPUP_BORDER: u8 = 0x22;
pub(super) const SLOT_POPUP_SEL_BG: u8 = 0x23;
const SLOT_POPUP_DESC_FG: u8 = 0x26;
const SLOT_BREADCRUMB_BG: u8 = 0x27;
const SLOT_BREADCRUMB_FG: u8 = 0x28;
const SLOT_BREADCRUMB_SEPARATOR_FG: u8 = 0x29;
pub(super) const SLOT_POPUP_SEL_FG: u8 = 0x2A;
pub(super) const SLOT_MODELINE_BAR_BG: u8 = 0x30;
const SLOT_MODELINE_BAR_FG: u8 = 0x31;

#[derive(Debug, Clone, Default)]
pub(super) struct ThemePalette {
    slots: HashMap<u8, u32>,
}

impl ThemePalette {
    pub(super) fn from_theme(theme: semantic::Theme) -> Self {
        let slots = theme
            .slots
            .into_iter()
            .map(|slot| (slot.id, slot.rgb))
            .collect();
        Self { slots }
    }

    pub(super) fn color(&self, slot: u8, fallback: u32) -> u32 {
        self.slots.get(&slot).copied().unwrap_or(fallback)
    }

    pub(super) fn status_bar_style(&self) -> CellStyle {
        CellStyle {
            fg: self.color(SLOT_MODELINE_BAR_FG, 0xD8DEE9),
            bg: self.color(SLOT_MODELINE_BAR_BG, 0x2E3440),
            attrs: protocol::ATTR_BOLD,
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn tab_style(&self, active: bool, tint: u32) -> CellStyle {
        CellStyle {
            fg: if tint != 0 {
                tint & 0x00FF_FFFF
            } else if active {
                self.color(SLOT_TAB_ACTIVE_FG, 0xD8DEE9)
            } else {
                self.color(SLOT_TAB_INACTIVE_FG, 0xC7CED9)
            },
            bg: if active {
                self.color(SLOT_TAB_ACTIVE_BG, 0x3B4252)
            } else {
                self.color(SLOT_TAB_BG, 0x242933)
            },
            attrs: if active { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn file_tree_style(&self, selected: bool, focused: bool) -> CellStyle {
        CellStyle {
            fg: if selected {
                self.color(SLOT_TREE_ACTIVE_FG, 0xECEFF4)
            } else {
                self.color(SLOT_TREE_FG, 0xC7CED9)
            },
            bg: if selected {
                self.color(
                    SLOT_TREE_SELECTION_BG,
                    if focused { 0x4C566A } else { 0x3B4252 },
                )
            } else {
                self.color(SLOT_TREE_BG, 0x20242D)
            },
            attrs: if selected { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn picker_style(&self, selected: bool) -> CellStyle {
        CellStyle {
            fg: if selected {
                self.color(SLOT_POPUP_SEL_FG, 0xECEFF4)
            } else {
                self.color(SLOT_POPUP_FG, 0xD8DEE9)
            },
            bg: if selected {
                self.color(SLOT_POPUP_SEL_BG, 0x3B4252)
            } else {
                self.color(SLOT_POPUP_BG, 0x151A21)
            },
            attrs: if selected { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn picker_header_style(&self) -> CellStyle {
        CellStyle {
            fg: self.color(SLOT_POPUP_BORDER, 0xF8FAFC),
            bg: self.color(SLOT_POPUP_BG, 0x273142),
            attrs: protocol::ATTR_BOLD,
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn picker_query_style(&self) -> CellStyle {
        CellStyle {
            fg: self.color(SLOT_POPUP_DESC_FG, 0xB7C7E3),
            bg: self.color(SLOT_POPUP_BG, 0x1F2632),
            attrs: 0,
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn picker_preview_style(&self, bold: bool, fg: u32) -> CellStyle {
        CellStyle {
            fg: if fg == 0 {
                self.color(SLOT_POPUP_FG, 0xCAD3DF)
            } else {
                fg
            },
            bg: self.color(SLOT_EDITOR_BG, 0x11161D),
            attrs: if bold { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn minibuffer_style(&self, selected: bool) -> CellStyle {
        CellStyle {
            fg: if selected {
                self.color(SLOT_POPUP_SEL_FG, 0xF8FAFC)
            } else {
                self.color(SLOT_EDITOR_FG, 0xD8DEE9)
            },
            bg: if selected {
                self.color(SLOT_POPUP_SEL_BG, 0x4C566A)
            } else {
                self.color(SLOT_MODELINE_BAR_BG, 0x20242D)
            },
            attrs: if selected { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn minibuffer_context_style(&self) -> CellStyle {
        CellStyle {
            fg: self.color(SLOT_POPUP_DESC_FG, 0x9AA7B5),
            bg: self.color(SLOT_MODELINE_BAR_BG, 0x1A1F28),
            attrs: 0,
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn breadcrumb_style(&self) -> CellStyle {
        CellStyle {
            fg: self.color(SLOT_BREADCRUMB_FG, 0xBBC2CF),
            bg: self.color(SLOT_BREADCRUMB_BG, 0x21242B),
            attrs: 0,
            ul_color: self.color(SLOT_BREADCRUMB_SEPARATOR_FG, 0x3F444A),
            blend: 100,
        }
    }

    pub(super) fn completion_style(&self, selected: bool) -> CellStyle {
        CellStyle {
            fg: if selected {
                self.color(SLOT_POPUP_SEL_FG, 0xF8FAFC)
            } else {
                self.color(SLOT_POPUP_FG, 0xD8DEE9)
            },
            bg: if selected {
                self.color(SLOT_POPUP_SEL_BG, 0x3B4252)
            } else {
                self.color(SLOT_POPUP_BG, 0x151A21)
            },
            attrs: if selected { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn which_key_style(&self, group: bool) -> CellStyle {
        CellStyle {
            fg: if group {
                self.color(SLOT_POPUP_BORDER, 0xF8FAFC)
            } else {
                self.color(SLOT_POPUP_FG, 0xD8DEE9)
            },
            bg: self.color(SLOT_POPUP_BG, 0x151A21),
            attrs: if group { protocol::ATTR_BOLD } else { 0 },
            ul_color: 0,
            blend: 100,
        }
    }

    pub(super) fn which_key_header_style(&self) -> CellStyle {
        CellStyle {
            fg: self.color(SLOT_POPUP_DESC_FG, 0xB7C7E3),
            bg: self.color(SLOT_POPUP_BG, 0x1F2632),
            attrs: protocol::ATTR_BOLD,
            ul_color: 0,
            blend: 100,
        }
    }
}
