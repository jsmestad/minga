/// Observable theme colors driven by the BEAM via the gui_theme protocol message.
///
/// All SwiftUI chrome views reference this shared instance for their colors. Initial values are neutral bootstrap colors used only before the first BEAM gui_theme command arrives. Theme selection belongs to the BEAM.

import SwiftUI
import MingaProtocol

/// Thread-safe observable theme colors for SwiftUI chrome.
@MainActor
@Observable
final class ThemeColors {
    // ── Editor ──
    var editorBg: Color = color(0x000000)
    var editorFg: Color = color(0xFFFFFF)

    // ── File tree ──
    var treeBg: Color = color(0x000000)
    var treeFg: Color = color(0xFFFFFF)
    var treeSelectionBg: Color = color(0x333333)
    var treeDirFg: Color = color(0xFFFFFF)
    var treeActiveFg: Color = color(0xFFFFFF)
    var treeHeaderBg: Color = color(0x000000)
    var treeHeaderFg: Color = color(0xFFFFFF)
    var treeSeparatorFg: Color = color(0x666666)
    var treeGitModified: Color = color(0xFFAA00)
    var treeGitStaged: Color = color(0x00AA00)
    var treeGitUntracked: Color = color(0x00AA00)
    var treeSelectionFg: Color = color(0xFFFFFF)
    var treeGuideFg: Color = color(0x666666)

    // ── Tab bar ──
    var tabBg: Color = color(0x000000)
    var tabActiveBg: Color = color(0x333333)
    var tabActiveFg: Color = color(0xFFFFFF)
    var tabInactiveFg: Color = color(0x999999)
    var tabModifiedFg: Color = color(0xFFAA00)
    var tabSeparatorFg: Color = color(0x666666)
    var tabCloseHoverFg: Color = color(0xFF0000)
    var tabAttentionFg: Color = color(0xFFAA00)

    // ── Popup (which-key, completion) ──
    var popupBg: Color = color(0x000000)
    var popupFg: Color = color(0xFFFFFF)
    var popupBorder: Color = color(0x666666)
    var popupSelBg: Color = color(0x333333)
    var popupSelFg: Color = color(0xFFFFFF)
    var popupKeyFg: Color = color(0xFFFFFF)
    var popupGroupFg: Color = color(0xFFFFFF)
    var popupDescFg: Color = color(0xFFFFFF)

    // ── Breadcrumb ──
    var breadcrumbBg: Color = color(0x000000)
    var breadcrumbFg: Color = color(0xFFFFFF)
    var breadcrumbSeparatorFg: Color = color(0x666666)

    // ── Modeline / status bar ──
    var modelineBarBg: Color = color(0x000000)
    var modelineBarFg: Color = color(0xFFFFFF)
    var modelineInfoBg: Color = color(0x333333)
    var modelineInfoFg: Color = color(0xFFFFFF)
    var modeNormalBg: Color = color(0xFFFFFF)
    var modeNormalFg: Color = color(0x000000)
    var modeInsertBg: Color = color(0xFFFFFF)
    var modeInsertFg: Color = color(0x000000)
    var modeVisualBg: Color = color(0xFFFFFF)
    var modeVisualFg: Color = color(0x000000)
    var statusbarAccentFg: Color = color(0xFFFFFF)

    // ── Gutter ──
    var gutterFg: Color = color(0x999999)
    var gutterCurrentFg: Color = color(0xFFFFFF)
    var gutterErrorFg: Color = color(0xFF0000)
    var gutterWarningFg: Color = color(0xFFAA00)
    var gutterInfoFg: Color = color(0x00AAFF)
    var gutterHintFg: Color = color(0x999999)
    var gutterFoldFg: Color = color(0x999999)
    var gitAddedFg: Color = color(0x00AA00)
    var gitModifiedFg: Color = color(0x00AAFF)
    var gitDeletedFg: Color = color(0xFF0000)

    // ── Document highlights + Selection ──
    var highlightReadBg: Color = color(0x333333)
    var highlightWriteBg: Color = color(0x333333)
    var selectionBg: Color = color(0x333333)

    // Raw SIMD3 values for Metal renderer (highlight + selection).
    var highlightReadBgSIMD: SIMD3<Float> = SIMD3<Float>(
        Float((0x333333 >> 16) & 0xFF) / 255.0,
        Float((0x333333 >> 8) & 0xFF) / 255.0,
        Float(0x333333 & 0xFF) / 255.0
    )
    var highlightWriteBgSIMD: SIMD3<Float> = SIMD3<Float>(
        Float((0x333333 >> 16) & 0xFF) / 255.0,
        Float((0x333333 >> 8) & 0xFF) / 255.0,
        Float(0x333333 & 0xFF) / 255.0
    )
    var selectionBgSIMD: SIMD3<Float> = SIMD3<Float>(
        Float((0x333333 >> 16) & 0xFF) / 255.0,
        Float((0x333333 >> 8) & 0xFF) / 255.0,
        Float(0x333333 & 0xFF) / 255.0
    )

    // Raw 24-bit RGB values for Metal renderer.
    // Updated alongside the Color properties when gui_theme slots arrive.
    var editorFgRGB: UInt32 = 0xFFFFFF
    var gutterFgRGB: UInt32 = 0x999999
    var gutterCurrentFgRGB: UInt32 = 0xFFFFFF
    var gutterErrorFgRGB: UInt32 = 0xFF0000
    var gutterWarningFgRGB: UInt32 = 0xFFAA00
    var gutterInfoFgRGB: UInt32 = 0x00AAFF
    var gutterHintFgRGB: UInt32 = 0x999999
    var gutterFoldFgRGB: UInt32 = 0x999999
    var gitAddedFgRGB: UInt32 = 0x00AA00
    var gitModifiedFgRGB: UInt32 = 0x00AAFF
    var gitDeletedFgRGB: UInt32 = 0xFF0000

    // ── Agent status (shared across tab badges, chat header) ──
    var agentStatusIdle: Color = color(0x999999)
    var agentStatusWorking: Color = color(0x00AA00)
    var agentStatusIterating: Color = color(0x00AA00)
    var agentStatusNeedsYou: Color = color(0xFFAA00)
    var agentStatusDone: Color = color(0xFFFFFF)
    var agentStatusErrored: Color = color(0xFF0000)

    // ── Agent chat theme ──
    var agentPanelBg: Color = color(0x000000)
    var agentHeaderBg: Color = color(0x000000)
    var agentHeaderFg: Color = color(0xFFFFFF)
    var agentUserBorder: Color = color(0xFFFFFF)
    var agentUserLabel: Color = color(0xFFFFFF)
    var agentAssistantBorder: Color = color(0x00AA00)
    var agentAssistantLabel: Color = color(0x00AA00)
    var agentInputBorder: Color = color(0xFFFFFF)
    var agentInputBg: Color = color(0x000000)
    var agentInputPlaceholder: Color = color(0x999999)
    var agentTextFg: Color = color(0xFFFFFF)
    var agentToolBorder: Color = color(0xFFAA00)
    var agentToolHeader: Color = color(0xFFAA00)
    var agentCodeBg: Color = color(0x000000)
    var agentCodeBorder: Color = color(0x666666)

    // ── Accent ──
    var accent: Color = color(0xFFFFFF)

    private(set) var hasAppliedTheme = false

    // ── Shared chrome contrast tokens ──
    var chromeSecondaryFg: Color { editorFg.opacity(0.78) }
    var chromeMutedFg: Color { editorFg.opacity(0.62) }
    var chromeDisabledFg: Color { editorFg.opacity(0.42) }
    var popupSecondaryFg: Color { popupFg.opacity(0.78) }
    var popupMutedFg: Color { popupFg.opacity(0.62) }
    var popupDisabledFg: Color { popupFg.opacity(0.42) }
    var modelineSecondaryFg: Color { modelineBarFg.opacity(0.78) }
    var modelineMutedFg: Color { modelineBarFg.opacity(0.62) }
    var modelineDisabledFg: Color { modelineBarFg.opacity(0.42) }
    var treeSecondaryFg: Color { treeFg.opacity(0.78) }
    var treeMutedFg: Color { treeFg.opacity(0.62) }
    var treeDisabledFg: Color { treeFg.opacity(0.42) }
    // Inactive tab content derives from the active tab foreground so it stays
    // legible and theme-correct. The active/inactive distinction is carried by
    // the active tab's background fill and top accent bar, so the inactive
    // label sits at the "secondary" tier rather than the darkest flat color.
    var tabSecondaryFg: Color { tabActiveFg.opacity(0.78) }
    var agentSecondaryFg: Color { agentTextFg.opacity(0.78) }
    var agentMutedFg: Color { agentTextFg.opacity(0.62) }
    var agentDisabledFg: Color { agentTextFg.opacity(0.42) }

    /// Apply a batch of color slot updates from the gui_theme protocol message.
    func applySlots(_ slots: [(UInt8, UInt8, UInt8, UInt8)]) {
        hasAppliedTheme = true

        for (slotId, r, g, b) in slots {
            let c = Color(
                red: Double(r) / 255.0,
                green: Double(g) / 255.0,
                blue: Double(b) / 255.0
            )
            let rgb = (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
            applySlot(slotId, color: c, rgb: rgb)
        }
    }

    private func rgbToSIMD3(_ rgb: UInt32) -> SIMD3<Float> {
        SIMD3<Float>(
            Float((rgb >> 16) & 0xFF) / 255.0,
            Float((rgb >> 8) & 0xFF) / 255.0,
            Float(rgb & 0xFF) / 255.0
        )
    }

    private func applySlot(_ slot: UInt8, color c: Color, rgb: UInt32) {
        switch slot {
        case GUI_COLOR_EDITOR_BG: editorBg = c
        case GUI_COLOR_EDITOR_FG: editorFg = c; editorFgRGB = rgb
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
        case GUI_COLOR_POPUP_SEL_FG: popupSelFg = c
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
        case GUI_COLOR_GUTTER_FG: gutterFg = c; gutterFgRGB = rgb
        case GUI_COLOR_GUTTER_CURRENT_FG: gutterCurrentFg = c; gutterCurrentFgRGB = rgb
        case GUI_COLOR_GUTTER_ERROR_FG: gutterErrorFg = c; gutterErrorFgRGB = rgb
        case GUI_COLOR_GUTTER_WARNING_FG: gutterWarningFg = c; gutterWarningFgRGB = rgb
        case GUI_COLOR_GUTTER_INFO_FG: gutterInfoFg = c; gutterInfoFgRGB = rgb
        case GUI_COLOR_GUTTER_HINT_FG: gutterHintFg = c; gutterHintFgRGB = rgb
        case GUI_COLOR_GUTTER_FOLD_FG: gutterFoldFg = c; gutterFoldFgRGB = rgb
        case GUI_COLOR_GIT_ADDED_FG: gitAddedFg = c; gitAddedFgRGB = rgb
        case GUI_COLOR_GIT_MODIFIED_FG: gitModifiedFg = c; gitModifiedFgRGB = rgb
        case GUI_COLOR_GIT_DELETED_FG: gitDeletedFg = c; gitDeletedFgRGB = rgb
        case GUI_COLOR_HIGHLIGHT_READ_BG:
            highlightReadBg = c
            highlightReadBgSIMD = rgbToSIMD3(rgb)
        case GUI_COLOR_HIGHLIGHT_WRITE_BG:
            highlightWriteBg = c
            highlightWriteBgSIMD = rgbToSIMD3(rgb)
        case GUI_COLOR_SELECTION_BG:
            selectionBg = c
            selectionBgSIMD = rgbToSIMD3(rgb)
        case GUI_COLOR_AGENT_STATUS_IDLE: agentStatusIdle = c
        case GUI_COLOR_AGENT_STATUS_WORKING: agentStatusWorking = c
        case GUI_COLOR_AGENT_STATUS_ITERATING: agentStatusIterating = c
        case GUI_COLOR_AGENT_STATUS_NEEDS_YOU: agentStatusNeedsYou = c
        case GUI_COLOR_AGENT_STATUS_DONE: agentStatusDone = c
        case GUI_COLOR_AGENT_STATUS_ERRORED: agentStatusErrored = c
        case GUI_COLOR_AGENT_PANEL_BG: agentPanelBg = c
        case GUI_COLOR_AGENT_HEADER_BG: agentHeaderBg = c
        case GUI_COLOR_AGENT_HEADER_FG: agentHeaderFg = c
        case GUI_COLOR_AGENT_USER_BORDER: agentUserBorder = c
        case GUI_COLOR_AGENT_USER_LABEL: agentUserLabel = c
        case GUI_COLOR_AGENT_ASSISTANT_BORDER: agentAssistantBorder = c
        case GUI_COLOR_AGENT_ASSISTANT_LABEL: agentAssistantLabel = c
        case GUI_COLOR_AGENT_INPUT_BORDER: agentInputBorder = c
        case GUI_COLOR_AGENT_INPUT_BG: agentInputBg = c
        case GUI_COLOR_AGENT_INPUT_PLACEHOLDER: agentInputPlaceholder = c
        case GUI_COLOR_AGENT_TEXT_FG: agentTextFg = c
        case GUI_COLOR_AGENT_TOOL_BORDER: agentToolBorder = c
        case GUI_COLOR_AGENT_TOOL_HEADER: agentToolHeader = c
        case GUI_COLOR_AGENT_CODE_BG: agentCodeBg = c
        case GUI_COLOR_AGENT_CODE_BORDER: agentCodeBorder = c
        default: break
        }
    }

}

private struct ThemeColorsEnvironmentKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = ThemeColors()
}

extension EnvironmentValues {
    var themeColors: ThemeColors {
        get { self[ThemeColorsEnvironmentKey.self] }
        set { self[ThemeColorsEnvironmentKey.self] = newValue }
    }
}

/// Shared spacing scale for SwiftUI chrome.
///
/// A 4pt modular grid. Reach for the nearest step instead of ad-hoc magic
/// numbers so spacing rhythm stays consistent across views. A 4pt grid reads
/// more evenly for dense UI layout than a literal golden-ratio scale (φ suits
/// type and section rhythm better than control gaps), so the steps below are
/// the de-facto 4pt system used by Apple, Material, and Tailwind.
enum Spacing {
    /// 2pt: hairline. Badge internals, dot-to-glyph.
    static let hairline: CGFloat = 2
    /// 4pt: tight inline groups (chips, toggles, icon-to-label).
    static let xs: CGFloat = 4
    /// 8pt: default control/element gap.
    static let sm: CGFloat = 8
    /// 12pt: row padding, label-to-content, comfortable rows.
    static let md: CGFloat = 12
    /// 16pt: separation between distinct groups.
    static let lg: CGFloat = 16
    /// 20pt: section/panel padding.
    static let xl: CGFloat = 20
    /// 32pt: major section breaks.
    static let xxl: CGFloat = 32
}

/// File-private helper to create a Color from a 24-bit RGB integer.
/// Used by ThemeColors property defaults and applySlot.
private func color(_ rgb: UInt32) -> Color {
    Color(
        red: Double((rgb >> 16) & 0xFF) / 255.0,
        green: Double((rgb >> 8) & 0xFF) / 255.0,
        blue: Double(rgb & 0xFF) / 255.0
    )
}
