/// Tests for ThemeColors.applySlots mapping.
///
/// Verifies that each GUI color slot ID maps to the correct ThemeColors
/// property. Catches slot ID mismatches, duplicates, and missing entries
/// in the manual switch statement.

import Testing
import SwiftUI

@Suite("ThemeColors Slot Mapping")
struct ThemeColorsSlotMappingTests {

    /// Helper to apply a single slot and get the resulting RGB value.
    @MainActor
    private func applySlot(_ slotId: UInt8, r: UInt8 = 0xAA, g: UInt8 = 0xBB, b: UInt8 = 0xCC) -> ThemeColors {
        let theme = ThemeColors()
        theme.applySlots([(slotId, r, g, b)])
        return theme
    }

    /// Helper to create a Color from RGB bytes for comparison.
    private func expectedColor(_ r: UInt8 = 0xAA, _ g: UInt8 = 0xBB, _ b: UInt8 = 0xCC) -> Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }

    // MARK: - Editor slots

    @Test("Slot 0x01 maps to editorBg")
    @MainActor func editorBg() {
        let theme = applySlot(GUI_COLOR_EDITOR_BG)
        #expect(theme.editorBg == expectedColor())
    }

    @Test("Slot 0x02 maps to editorFg and editorFgRGB")
    @MainActor func editorFg() {
        let theme = applySlot(GUI_COLOR_EDITOR_FG)
        #expect(theme.editorFg == expectedColor())
        #expect(theme.editorFgRGB == 0xAABBCC)
    }

    // MARK: - Tree slots

    @Test("Slot 0x03 maps to treeBg")
    @MainActor func treeBg() { #expect(applySlot(GUI_COLOR_TREE_BG).treeBg == expectedColor()) }

    @Test("Slot 0x04 maps to treeFg")
    @MainActor func treeFg() { #expect(applySlot(GUI_COLOR_TREE_FG).treeFg == expectedColor()) }

    @Test("Slot 0x05 maps to treeSelectionBg")
    @MainActor func treeSelectionBg() { #expect(applySlot(GUI_COLOR_TREE_SELECTION_BG).treeSelectionBg == expectedColor()) }

    @Test("Slot 0x06 maps to treeDirFg")
    @MainActor func treeDirFg() { #expect(applySlot(GUI_COLOR_TREE_DIR_FG).treeDirFg == expectedColor()) }

    @Test("Slot 0x07 maps to treeActiveFg")
    @MainActor func treeActiveFg() { #expect(applySlot(GUI_COLOR_TREE_ACTIVE_FG).treeActiveFg == expectedColor()) }

    @Test("Slot 0x08 maps to treeHeaderBg")
    @MainActor func treeHeaderBg() { #expect(applySlot(GUI_COLOR_TREE_HEADER_BG).treeHeaderBg == expectedColor()) }

    @Test("Slot 0x09 maps to treeHeaderFg")
    @MainActor func treeHeaderFg() { #expect(applySlot(GUI_COLOR_TREE_HEADER_FG).treeHeaderFg == expectedColor()) }

    @Test("Slot 0x0A maps to treeSeparatorFg")
    @MainActor func treeSepFg() { #expect(applySlot(GUI_COLOR_TREE_SEPARATOR_FG).treeSeparatorFg == expectedColor()) }

    @Test("Slot 0x0B maps to treeGitModified")
    @MainActor func treeGitMod() { #expect(applySlot(GUI_COLOR_TREE_GIT_MODIFIED).treeGitModified == expectedColor()) }

    @Test("Slot 0x0C maps to treeGitStaged")
    @MainActor func treeGitStaged() { #expect(applySlot(GUI_COLOR_TREE_GIT_STAGED).treeGitStaged == expectedColor()) }

    @Test("Slot 0x0D maps to treeGitUntracked")
    @MainActor func treeGitUntracked() { #expect(applySlot(GUI_COLOR_TREE_GIT_UNTRACKED).treeGitUntracked == expectedColor()) }

    @Test("Slot 0x0E maps to treeSelectionFg")
    @MainActor func treeSelectionFg() { #expect(applySlot(GUI_COLOR_TREE_SELECTION_FG).treeSelectionFg == expectedColor()) }

    @Test("Slot 0x0F maps to treeGuideFg")
    @MainActor func treeGuideFg() { #expect(applySlot(GUI_COLOR_TREE_GUIDE_FG).treeGuideFg == expectedColor()) }

    // MARK: - Tab slots

    @Test("Slot 0x10 maps to tabBg")
    @MainActor func tabBg() { #expect(applySlot(GUI_COLOR_TAB_BG).tabBg == expectedColor()) }

    @Test("Slot 0x11 maps to tabActiveBg")
    @MainActor func tabActiveBg() { #expect(applySlot(GUI_COLOR_TAB_ACTIVE_BG).tabActiveBg == expectedColor()) }

    @Test("Slot 0x12 maps to tabActiveFg")
    @MainActor func tabActiveFg() { #expect(applySlot(GUI_COLOR_TAB_ACTIVE_FG).tabActiveFg == expectedColor()) }

    @Test("Slot 0x13 maps to tabInactiveFg")
    @MainActor func tabInactiveFg() { #expect(applySlot(GUI_COLOR_TAB_INACTIVE_FG).tabInactiveFg == expectedColor()) }

    @Test("Slot 0x14 maps to tabModifiedFg")
    @MainActor func tabModifiedFg() { #expect(applySlot(GUI_COLOR_TAB_MODIFIED_FG).tabModifiedFg == expectedColor()) }

    @Test("Slot 0x15 maps to tabSeparatorFg")
    @MainActor func tabSepFg() { #expect(applySlot(GUI_COLOR_TAB_SEPARATOR_FG).tabSeparatorFg == expectedColor()) }

    @Test("Slot 0x16 maps to tabCloseHoverFg")
    @MainActor func tabCloseHoverFg() { #expect(applySlot(GUI_COLOR_TAB_CLOSE_HOVER_FG).tabCloseHoverFg == expectedColor()) }

    @Test("Slot 0x17 maps to tabAttentionFg")
    @MainActor func tabAttentionFg() { #expect(applySlot(GUI_COLOR_TAB_ATTENTION_FG).tabAttentionFg == expectedColor()) }

    // MARK: - Popup slots

    @Test("Slot 0x20 maps to popupBg")
    @MainActor func popupBg() { #expect(applySlot(GUI_COLOR_POPUP_BG).popupBg == expectedColor()) }

    @Test("Slot 0x21 maps to popupFg")
    @MainActor func popupFg() { #expect(applySlot(GUI_COLOR_POPUP_FG).popupFg == expectedColor()) }

    @Test("Slot 0x22 maps to popupBorder")
    @MainActor func popupBorder() { #expect(applySlot(GUI_COLOR_POPUP_BORDER).popupBorder == expectedColor()) }

    @Test("Slot 0x23 maps to popupSelBg")
    @MainActor func popupSelBg() { #expect(applySlot(GUI_COLOR_POPUP_SEL_BG).popupSelBg == expectedColor()) }

    @Test("Slot 0x24 maps to popupKeyFg")
    @MainActor func popupKeyFg() { #expect(applySlot(GUI_COLOR_POPUP_KEY_FG).popupKeyFg == expectedColor()) }

    @Test("Slot 0x25 maps to popupGroupFg")
    @MainActor func popupGroupFg() { #expect(applySlot(GUI_COLOR_POPUP_GROUP_FG).popupGroupFg == expectedColor()) }

    @Test("Slot 0x26 maps to popupDescFg")
    @MainActor func popupDescFg() { #expect(applySlot(GUI_COLOR_POPUP_DESC_FG).popupDescFg == expectedColor()) }

    // MARK: - Breadcrumb slots

    @Test("Slot 0x27 maps to breadcrumbBg")
    @MainActor func breadcrumbBg() { #expect(applySlot(GUI_COLOR_BREADCRUMB_BG).breadcrumbBg == expectedColor()) }

    @Test("Slot 0x28 maps to breadcrumbFg")
    @MainActor func breadcrumbFg() { #expect(applySlot(GUI_COLOR_BREADCRUMB_FG).breadcrumbFg == expectedColor()) }

    @Test("Slot 0x29 maps to breadcrumbSeparatorFg")
    @MainActor func breadcrumbSepFg() { #expect(applySlot(GUI_COLOR_BREADCRUMB_SEPARATOR_FG).breadcrumbSeparatorFg == expectedColor()) }

    // MARK: - Modeline / status bar slots

    @Test("Slot 0x30 maps to modelineBarBg")
    @MainActor func modelineBarBg() { #expect(applySlot(GUI_COLOR_MODELINE_BAR_BG).modelineBarBg == expectedColor()) }

    @Test("Slot 0x31 maps to modelineBarFg")
    @MainActor func modelineBarFg() { #expect(applySlot(GUI_COLOR_MODELINE_BAR_FG).modelineBarFg == expectedColor()) }

    @Test("Slot 0x32 maps to modelineInfoBg")
    @MainActor func modelineInfoBg() { #expect(applySlot(GUI_COLOR_MODELINE_INFO_BG).modelineInfoBg == expectedColor()) }

    @Test("Slot 0x33 maps to modelineInfoFg")
    @MainActor func modelineInfoFg() { #expect(applySlot(GUI_COLOR_MODELINE_INFO_FG).modelineInfoFg == expectedColor()) }

    @Test("Slot 0x34 maps to modeNormalBg")
    @MainActor func modeNormalBg() { #expect(applySlot(GUI_COLOR_MODE_NORMAL_BG).modeNormalBg == expectedColor()) }

    @Test("Slot 0x35 maps to modeNormalFg")
    @MainActor func modeNormalFg() { #expect(applySlot(GUI_COLOR_MODE_NORMAL_FG).modeNormalFg == expectedColor()) }

    @Test("Slot 0x36 maps to modeInsertBg")
    @MainActor func modeInsertBg() { #expect(applySlot(GUI_COLOR_MODE_INSERT_BG).modeInsertBg == expectedColor()) }

    @Test("Slot 0x37 maps to modeInsertFg")
    @MainActor func modeInsertFg() { #expect(applySlot(GUI_COLOR_MODE_INSERT_FG).modeInsertFg == expectedColor()) }

    @Test("Slot 0x38 maps to modeVisualBg")
    @MainActor func modeVisualBg() { #expect(applySlot(GUI_COLOR_MODE_VISUAL_BG).modeVisualBg == expectedColor()) }

    @Test("Slot 0x39 maps to modeVisualFg")
    @MainActor func modeVisualFg() { #expect(applySlot(GUI_COLOR_MODE_VISUAL_FG).modeVisualFg == expectedColor()) }

    @Test("Slot 0x3A maps to statusbarAccentFg")
    @MainActor func statusbarAccentFg() { #expect(applySlot(GUI_COLOR_STATUSBAR_ACCENT_FG).statusbarAccentFg == expectedColor()) }

    // MARK: - Gutter + Git slots (with RGB sync)

    @Test("Slot 0x50 maps to gutterFg and gutterFgRGB")
    @MainActor func gutterFg() {
        let theme = applySlot(GUI_COLOR_GUTTER_FG)
        #expect(theme.gutterFg == expectedColor())
        #expect(theme.gutterFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x51 maps to gutterCurrentFg and gutterCurrentFgRGB")
    @MainActor func gutterCurrentFg() {
        let theme = applySlot(GUI_COLOR_GUTTER_CURRENT_FG)
        #expect(theme.gutterCurrentFg == expectedColor())
        #expect(theme.gutterCurrentFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x52 maps to gutterErrorFg and gutterErrorFgRGB")
    @MainActor func gutterErrorFg() {
        let theme = applySlot(GUI_COLOR_GUTTER_ERROR_FG)
        #expect(theme.gutterErrorFg == expectedColor())
        #expect(theme.gutterErrorFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x53 maps to gutterWarningFg and gutterWarningFgRGB")
    @MainActor func gutterWarningFg() {
        let theme = applySlot(GUI_COLOR_GUTTER_WARNING_FG)
        #expect(theme.gutterWarningFg == expectedColor())
        #expect(theme.gutterWarningFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x54 maps to gutterInfoFg and gutterInfoFgRGB")
    @MainActor func gutterInfoFg() {
        let theme = applySlot(GUI_COLOR_GUTTER_INFO_FG)
        #expect(theme.gutterInfoFg == expectedColor())
        #expect(theme.gutterInfoFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x55 maps to gutterHintFg and gutterHintFgRGB")
    @MainActor func gutterHintFg() {
        let theme = applySlot(GUI_COLOR_GUTTER_HINT_FG)
        #expect(theme.gutterHintFg == expectedColor())
        #expect(theme.gutterHintFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x56 maps to gitAddedFg and gitAddedFgRGB")
    @MainActor func gitAddedFg() {
        let theme = applySlot(GUI_COLOR_GIT_ADDED_FG)
        #expect(theme.gitAddedFg == expectedColor())
        #expect(theme.gitAddedFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x57 maps to gitModifiedFg and gitModifiedFgRGB")
    @MainActor func gitModifiedFg() {
        let theme = applySlot(GUI_COLOR_GIT_MODIFIED_FG)
        #expect(theme.gitModifiedFg == expectedColor())
        #expect(theme.gitModifiedFgRGB == 0xAABBCC)
    }

    @Test("Slot 0x58 maps to gitDeletedFg and gitDeletedFgRGB")
    @MainActor func gitDeletedFg() {
        let theme = applySlot(GUI_COLOR_GIT_DELETED_FG)
        #expect(theme.gitDeletedFg == expectedColor())
        #expect(theme.gitDeletedFgRGB == 0xAABBCC)
    }

    // MARK: - Accent

    @Test("Slot 0x40 maps to accent")
    @MainActor func accent() { #expect(applySlot(GUI_COLOR_ACCENT).accent == expectedColor()) }

    // MARK: - Agent status slots

    @Test("Slot 0x5C maps to agentStatusIdle")
    @MainActor func agentStatusIdle() { #expect(applySlot(GUI_COLOR_AGENT_STATUS_IDLE).agentStatusIdle == expectedColor()) }

    @Test("Slot 0x5D maps to agentStatusWorking")
    @MainActor func agentStatusWorking() { #expect(applySlot(GUI_COLOR_AGENT_STATUS_WORKING).agentStatusWorking == expectedColor()) }

    @Test("Slot 0x5E maps to agentStatusIterating")
    @MainActor func agentStatusIterating() { #expect(applySlot(GUI_COLOR_AGENT_STATUS_ITERATING).agentStatusIterating == expectedColor()) }

    @Test("Slot 0x5F maps to agentStatusNeedsYou")
    @MainActor func agentStatusNeedsYou() { #expect(applySlot(GUI_COLOR_AGENT_STATUS_NEEDS_YOU).agentStatusNeedsYou == expectedColor()) }

    @Test("Slot 0x60 maps to agentStatusDone")
    @MainActor func agentStatusDone() { #expect(applySlot(GUI_COLOR_AGENT_STATUS_DONE).agentStatusDone == expectedColor()) }

    @Test("Slot 0x61 maps to agentStatusErrored")
    @MainActor func agentStatusErrored() { #expect(applySlot(GUI_COLOR_AGENT_STATUS_ERRORED).agentStatusErrored == expectedColor()) }

    // MARK: - Batch application

    @Test("Multiple slots applied in one call all take effect")
    @MainActor func batchApply() {
        let theme = ThemeColors()
        theme.applySlots([
            (GUI_COLOR_EDITOR_BG, 0x11, 0x22, 0x33),
            (GUI_COLOR_EDITOR_FG, 0x44, 0x55, 0x66),
            (GUI_COLOR_ACCENT, 0x77, 0x88, 0x99),
        ])

        let bg = Color(red: 0x11/255.0, green: 0x22/255.0, blue: 0x33/255.0)
        let fg = Color(red: 0x44/255.0, green: 0x55/255.0, blue: 0x66/255.0)
        let acc = Color(red: 0x77/255.0, green: 0x88/255.0, blue: 0x99/255.0)

        #expect(theme.editorBg == bg)
        #expect(theme.editorFg == fg)
        #expect(theme.accent == acc)
        #expect(theme.editorFgRGB == 0x445566)
    }

    @Test("Unknown slot ID is silently ignored")
    @MainActor func unknownSlot() {
        let theme = ThemeColors()
        let originalBg = theme.editorBg
        theme.applySlots([(0xFF, 0xAA, 0xBB, 0xCC)]) // unknown slot
        #expect(theme.editorBg == originalBg) // unchanged
    }
}
