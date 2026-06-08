const types = @import("types.zig");
const Theme = types.Theme;
const StatusSegment = types.StatusSegment;

pub const theme_editor_bg: u8 = 0x01;
pub const theme_editor_fg: u8 = 0x02;
pub const theme_tree_bg: u8 = 0x03;
pub const theme_tree_fg: u8 = 0x04;
pub const theme_tree_selection_bg: u8 = 0x05;
pub const theme_tree_dir_fg: u8 = 0x06;
pub const theme_tree_selection_fg: u8 = 0x0e;
pub const theme_tab_bg: u8 = 0x10;
pub const theme_tab_active_bg: u8 = 0x11;
pub const theme_tab_active_fg: u8 = 0x12;
pub const theme_tab_inactive_fg: u8 = 0x13;
pub const theme_tab_modified_fg: u8 = 0x14;
pub const theme_tab_attention_fg: u8 = 0x17;
pub const theme_popup_bg: u8 = 0x20;
pub const theme_popup_fg: u8 = 0x21;
pub const theme_popup_selection_bg: u8 = 0x23;
pub const theme_breadcrumb_bg: u8 = 0x27;
pub const theme_popup_selection_fg: u8 = 0x2a;
pub const theme_modeline_bar_bg: u8 = 0x30;
pub const theme_modeline_bar_fg: u8 = 0x31;
pub const theme_accent: u8 = 0x40;
pub const theme_popup_desc_fg: u8 = 0x26;
pub const theme_gutter_fg: u8 = 0x50;
pub const theme_gutter_current_fg: u8 = 0x51;
pub const theme_gutter_error_fg: u8 = 0x52;
pub const theme_gutter_warning_fg: u8 = 0x53;
pub const theme_gutter_info_fg: u8 = 0x54;
pub const theme_gutter_hint_fg: u8 = 0x55;
pub const theme_highlight_read_bg: u8 = 0x59;
pub const theme_highlight_write_bg: u8 = 0x5a;
pub const theme_selection_bg: u8 = 0x5b;

pub const default_selection_bg: u24 = 0x264f78;
pub const default_editor_bg: u24 = 0x282c34;
pub const default_editor_fg: u24 = 0xbbc2cf;
pub const default_tree_bg: u24 = 0x21242b;
pub const default_tree_fg: u24 = 0xbbc2cf;
pub const default_tree_selection_bg: u24 = 0x3e4451;
pub const default_tree_selection_fg: u24 = 0xbbc2cf;
pub const default_tree_dir_fg: u24 = 0x61afef;
pub const default_tab_bg: u24 = 0x282c34;
pub const default_tab_active_bg: u24 = 0x3e4451;
pub const default_tab_active_fg: u24 = 0xffffff;
pub const default_tab_inactive_fg: u24 = 0x5b6268;
pub const default_tab_modified_fg: u24 = 0xff6c6b;
pub const default_tab_attention_fg: u24 = 0xecbe7b;
pub const default_popup_bg: u24 = 0x252a38;
pub const default_popup_fg: u24 = 0xd7ddf0;
pub const default_popup_selection_bg: u24 = 0x2f3650;
pub const default_popup_selection_fg: u24 = 0xf2f5ff;
pub const default_modeline_bar_bg: u24 = 0x22252d;
pub const default_modeline_bar_fg: u24 = 0xbbc2cf;
pub const default_accent_fg: u24 = 0x51afef;
pub const default_muted_fg: u24 = 0x8a93a5;
pub const default_gutter_fg: u24 = 0x5b6268;
pub const default_gutter_current_fg: u24 = 0xbbc2cf;
pub const default_document_highlight_read_bg: u24 = 0x3a3f4b;
pub const default_document_highlight_write_bg: u24 = 0x4a3f2b;
pub const default_search_match_bg: u24 = 0x21242b;
pub const default_current_search_match_bg: u24 = 0x3e4451;
pub const default_diagnostic_error_fg: u24 = 0xff6c6b;
pub const default_diagnostic_warning_fg: u24 = 0xecbe7b;
pub const default_diagnostic_info_fg: u24 = 0x51afef;
pub const default_diagnostic_hint_fg: u24 = 0x98be65;

pub fn themeColor(maybe_theme: ?Theme, id: u8, fallback: u24) u24 {
    if (maybe_theme) |theme| {
        const color = theme.color(id);
        if (color != 0) return color;
    }
    return fallback;
}

pub fn tabBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tab_bg, default_tab_bg);
}

pub fn editorBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_editor_bg, default_editor_bg);
}

pub fn editorFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_editor_fg, default_editor_fg);
}

pub fn mutedFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_popup_desc_fg, default_muted_fg);
}

pub fn treeBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tree_bg, default_tree_bg);
}

pub fn treeFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tree_fg, default_tree_fg);
}

pub fn treeDirFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tree_dir_fg, default_tree_dir_fg);
}

pub fn treeSelectionBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tree_selection_bg, default_tree_selection_bg);
}

pub fn treeSelectionFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tree_selection_fg, default_tree_selection_fg);
}

pub fn gutterFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_gutter_fg, default_gutter_fg);
}

pub fn gutterCurrentFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_gutter_current_fg, default_gutter_current_fg);
}

pub fn popupBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_popup_bg, default_popup_bg);
}

pub fn popupFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_popup_fg, default_popup_fg);
}

pub fn popupSelectionBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_popup_selection_bg, default_popup_selection_bg);
}

pub fn popupSelectionFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_popup_selection_fg, default_popup_selection_fg);
}

pub fn accentFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_accent, default_accent_fg);
}

pub fn tabActiveBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tab_active_bg, default_tab_active_bg);
}

pub fn tabActiveFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tab_active_fg, default_tab_active_fg);
}

pub fn tabInactiveFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tab_inactive_fg, default_tab_inactive_fg);
}

pub fn tabDirtyFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tab_modified_fg, default_tab_modified_fg);
}

pub fn tabAttentionFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_tab_attention_fg, default_tab_attention_fg);
}

pub fn modelineBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_modeline_bar_bg, default_modeline_bar_bg);
}

pub fn modelineFg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_modeline_bar_fg, default_modeline_bar_fg);
}

pub fn themedSegmentFg(segment: StatusSegment, maybe_theme: ?Theme) u24 {
    return if (segment.fg != 0) segment.fg else modelineFg(maybe_theme);
}

pub fn themedSegmentBg(segment: StatusSegment, maybe_theme: ?Theme) u24 {
    return if (segment.bg != 0) segment.bg else modelineBg(maybe_theme);
}

pub fn selectionBg(maybe_theme: ?Theme) u24 {
    return themeColor(maybe_theme, theme_selection_bg, default_selection_bg);
}

pub fn documentHighlightBg(maybe_theme: ?Theme, kind: u8) u24 {
    return switch (kind) {
        3 => themeColor(maybe_theme, theme_highlight_write_bg, default_document_highlight_write_bg),
        2 => themeColor(maybe_theme, theme_highlight_read_bg, default_document_highlight_read_bg),
        else => selectionBg(maybe_theme),
    };
}

pub fn searchMatchBg(maybe_theme: ?Theme, current: bool) u24 {
    return if (current)
        themeColor(maybe_theme, theme_tree_selection_bg, default_current_search_match_bg)
    else
        themeColor(maybe_theme, theme_breadcrumb_bg, default_search_match_bg);
}

pub fn diagnosticColor(maybe_theme: ?Theme, severity: u8) u24 {
    return switch (severity) {
        0 => themeColor(maybe_theme, theme_gutter_error_fg, default_diagnostic_error_fg),
        1 => themeColor(maybe_theme, theme_gutter_warning_fg, default_diagnostic_warning_fg),
        2 => themeColor(maybe_theme, theme_gutter_info_fg, default_diagnostic_info_fg),
        3 => themeColor(maybe_theme, theme_gutter_hint_fg, default_diagnostic_hint_fg),
        else => themeColor(maybe_theme, theme_gutter_warning_fg, default_diagnostic_warning_fg),
    };
}
