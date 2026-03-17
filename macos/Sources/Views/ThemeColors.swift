/// Observable theme colors driven by the BEAM via the gui_theme protocol message.
///
/// All SwiftUI chrome views reference this shared instance for their colors.
/// Defaults to Doom One colors so the app looks correct before the BEAM sends
/// a theme. Updated by CommandDispatcher when a gui_theme message arrives.

import SwiftUI

/// Thread-safe observable theme colors for SwiftUI chrome.
@MainActor
@Observable
final class ThemeColors {
    // ── Editor ──
    var editorBg: Color = color(0x282C34)
    var editorFg: Color = color(0xBBC2CF)

    // ── File tree ──
    var treeBg: Color = color(0x21242B)
    var treeFg: Color = color(0xBBC2CF)
    var treeSelectionBg: Color = color(0x2257A0)
    var treeDirFg: Color = color(0x51AFEF)
    var treeActiveFg: Color = color(0x51AFEF)
    var treeHeaderBg: Color = color(0x21242B)
    var treeHeaderFg: Color = color(0x51AFEF)
    var treeSeparatorFg: Color = color(0x3F444A)
    var treeGitModified: Color = color(0xECBE7B)
    var treeGitStaged: Color = color(0x98BE65)
    var treeGitUntracked: Color = color(0x98BE65)
    var treeSelectionFg: Color = color(0xBBC2CF)
    var treeGuideFg: Color = color(0x3F444A)

    // ── Tab bar ──
    var tabBg: Color = color(0x21242B)
    var tabActiveBg: Color = color(0x282C34)
    var tabActiveFg: Color = color(0xBBC2CF)
    var tabInactiveFg: Color = color(0x5B6268)
    var tabModifiedFg: Color = color(0xECBE7B)
    var tabSeparatorFg: Color = color(0x3F444A)
    var tabCloseHoverFg: Color = color(0xFF6C6B)
    var tabAttentionFg: Color = color(0xFF6C6B)

    // ── Popup (which-key, completion) ──
    var popupBg: Color = color(0x21242B)
    var popupFg: Color = color(0xBBC2CF)
    var popupBorder: Color = color(0x3F444A)
    var popupSelBg: Color = color(0x2257A0)
    var popupKeyFg: Color = color(0x51AFEF)
    var popupGroupFg: Color = color(0xC678DD)
    var popupDescFg: Color = color(0xBBC2CF)

    // ── Breadcrumb ──
    var breadcrumbBg: Color = color(0x21242B)
    var breadcrumbFg: Color = color(0xBBC2CF)
    var breadcrumbSeparatorFg: Color = color(0x3F444A)

    // ── Modeline / status bar ──
    var modelineBarBg: Color = color(0x21242B)
    var modelineBarFg: Color = color(0xBBC2CF)
    var modelineInfoBg: Color = color(0x3F444A)
    var modelineInfoFg: Color = color(0xBBC2CF)
    var modeNormalBg: Color = color(0x51AFEF)
    var modeNormalFg: Color = color(0x21242B)
    var modeInsertBg: Color = color(0x98BE65)
    var modeInsertFg: Color = color(0x21242B)
    var modeVisualBg: Color = color(0xC678DD)
    var modeVisualFg: Color = color(0x21242B)
    var statusbarAccentFg: Color = color(0x51AFEF)

    // ── Accent ──
    var accent: Color = color(0x51AFEF)

    /// Apply a batch of color slot updates from the gui_theme protocol message.
    func applySlots(_ slots: [(UInt8, UInt8, UInt8, UInt8)]) {
        for (slotId, r, g, b) in slots {
            let c = Color(
                red: Double(r) / 255.0,
                green: Double(g) / 255.0,
                blue: Double(b) / 255.0
            )
            applySlot(slotId, color: c)
        }
    }

    private func applySlot(_ slot: UInt8, color c: Color) {
        switch slot {
        case GUI_COLOR_EDITOR_BG: editorBg = c
        case GUI_COLOR_EDITOR_FG: editorFg = c
        case GUI_COLOR_TREE_BG: treeBg = c
        case GUI_COLOR_TREE_FG: treeFg = c
        case GUI_COLOR_TREE_SELECTION_BG: treeSelectionBg = c
        case GUI_COLOR_TREE_DIR_FG: treeDirFg = c
        case GUI_COLOR_TREE_ACTIVE_FG: treeActiveFg = c
        case GUI_COLOR_TREE_HEADER_BG: treeHeaderBg = c
        case GUI_COLOR_TREE_HEADER_FG: treeHeaderFg = c
        case GUI_COLOR_TREE_SEPARATOR_FG: treeSeparatorFg = c
        case GUI_COLOR_TREE_GIT_MODIFIED: treeGitModified = c
        case GUI_COLOR_TREE_GIT_STAGED: treeGitStaged = c
        case GUI_COLOR_TREE_GIT_UNTRACKED: treeGitUntracked = c
        case GUI_COLOR_TREE_SELECTION_FG: treeSelectionFg = c
        case GUI_COLOR_TREE_GUIDE_FG: treeGuideFg = c
        case GUI_COLOR_TAB_BG: tabBg = c
        case GUI_COLOR_TAB_ACTIVE_BG: tabActiveBg = c
        case GUI_COLOR_TAB_ACTIVE_FG: tabActiveFg = c
        case GUI_COLOR_TAB_INACTIVE_FG: tabInactiveFg = c
        case GUI_COLOR_TAB_MODIFIED_FG: tabModifiedFg = c
        case GUI_COLOR_TAB_SEPARATOR_FG: tabSeparatorFg = c
        case GUI_COLOR_TAB_CLOSE_HOVER_FG: tabCloseHoverFg = c
        case GUI_COLOR_TAB_ATTENTION_FG: tabAttentionFg = c
        case GUI_COLOR_POPUP_BG: popupBg = c
        case GUI_COLOR_POPUP_FG: popupFg = c
        case GUI_COLOR_POPUP_BORDER: popupBorder = c
        case GUI_COLOR_POPUP_SEL_BG: popupSelBg = c
        case GUI_COLOR_POPUP_KEY_FG: popupKeyFg = c
        case GUI_COLOR_POPUP_GROUP_FG: popupGroupFg = c
        case GUI_COLOR_POPUP_DESC_FG: popupDescFg = c
        case GUI_COLOR_BREADCRUMB_BG: breadcrumbBg = c
        case GUI_COLOR_BREADCRUMB_FG: breadcrumbFg = c
        case GUI_COLOR_BREADCRUMB_SEPARATOR_FG: breadcrumbSeparatorFg = c
        case GUI_COLOR_MODELINE_BAR_BG: modelineBarBg = c
        case GUI_COLOR_MODELINE_BAR_FG: modelineBarFg = c
        case GUI_COLOR_MODELINE_INFO_BG: modelineInfoBg = c
        case GUI_COLOR_MODELINE_INFO_FG: modelineInfoFg = c
        case GUI_COLOR_MODE_NORMAL_BG: modeNormalBg = c
        case GUI_COLOR_MODE_NORMAL_FG: modeNormalFg = c
        case GUI_COLOR_MODE_INSERT_BG: modeInsertBg = c
        case GUI_COLOR_MODE_INSERT_FG: modeInsertFg = c
        case GUI_COLOR_MODE_VISUAL_BG: modeVisualBg = c
        case GUI_COLOR_MODE_VISUAL_FG: modeVisualFg = c
        case GUI_COLOR_STATUSBAR_ACCENT_FG: statusbarAccentFg = c
        case GUI_COLOR_ACCENT: accent = c
        default: break
        }
    }

    /// Helper to create a Color from a 24-bit RGB integer.
    private static func color(_ rgb: UInt32) -> Color {
        Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

/// Module-level helper matching the static method for use in default values.
private func color(_ rgb: UInt32) -> Color {
    Color(
        red: Double((rgb >> 16) & 0xFF) / 255.0,
        green: Double((rgb >> 8) & 0xFF) / 255.0,
        blue: Double(rgb & 0xFF) / 255.0
    )
}
