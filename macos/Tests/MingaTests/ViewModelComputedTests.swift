/// Tests for computed properties on view model types.
///
/// These types have business logic beyond simple storage: icon extraction,
/// match position adjustment, display name formatting, status labels, etc.
/// Bugs in these computations produce visible UX issues (wrong highlights,
/// missing icons, incorrect counts).

import Testing
import Foundation

// MARK: - PickerItem

@Suite("PickerItem Computed Properties")
struct PickerItemComputedTests {

    @Test("icon extracts first character of label")
    func iconExtraction() {
        let item = PickerItem(id: 0, iconColor: 0, label: "editor.ex",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.icon == "e")
    }

    @Test("icon returns empty string for empty label")
    func iconEmpty() {
        let item = PickerItem(id: 0, iconColor: 0, label: "",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.icon == "")
    }

    @Test("icon handles Nerd Font character (multi-byte)")
    func iconNerdFont() {
        // Nerd Font icon: "\u{F024B}" (folder icon) + "lib"
        let item = PickerItem(id: 0, iconColor: 0, label: "\u{F024B}lib",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.icon == "\u{F024B}")
    }

    @Test("displayLabel drops first character (icon)")
    func displayLabel() {
        let item = PickerItem(id: 0, iconColor: 0, label: "editor.ex",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayLabel == "ditor.ex")
    }

    @Test("displayLabel returns full label when single character")
    func displayLabelSingleChar() {
        let item = PickerItem(id: 0, iconColor: 0, label: "x",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayLabel == "x")
    }

    @Test("displayMatchPositions adjusts by -1 and filters negatives")
    func matchPositionAdjustment() {
        // Label: "editor.ex" -> icon='e', displayLabel="ditor.ex"
        // Match at position 0 (the icon) should be filtered out (adjusted to -1)
        // Match at position 1 ('d') should become 0
        // Match at position 4 ('o') should become 3
        let item = PickerItem(id: 0, iconColor: 0, label: "editor.ex",
                             description: "", annotation: "",
                             matchPositions: [0, 1, 4], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions == Set([0, 3]))
    }

    @Test("displayMatchPositions with no matches returns empty set")
    func matchPositionEmpty() {
        let item = PickerItem(id: 0, iconColor: 0, label: "test",
                             description: "", annotation: "",
                             matchPositions: [], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions.isEmpty)
    }

    @Test("displayMatchPositions filters positions beyond label range")
    func matchPositionOutOfRange() {
        // Label: "ab" -> displayLabel="b" (length 1)
        // Match at position 5 -> adjusted to 4, which is >= displayLabel.count
        let item = PickerItem(id: 0, iconColor: 0, label: "ab",
                             description: "", annotation: "",
                             matchPositions: [5], isTwoLine: false, isMarked: false)
        #expect(item.displayMatchPositions.isEmpty)
    }
}

// MARK: - GUIHighlightSpan attribute flags

@Suite("GUIHighlightSpan Attribute Flags")
struct HighlightSpanFlagTests {

    @Test("Bold flag is bit 0")
    func boldFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x01, fontWeight: 0, fontId: 0)
        #expect(span.isBold == true)
        #expect(span.isItalic == false)
        #expect(span.isUnderline == false)
    }

    @Test("Italic flag is bit 1")
    func italicFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x02, fontWeight: 0, fontId: 0)
        #expect(span.isBold == false)
        #expect(span.isItalic == true)
    }

    @Test("Underline flag is bit 2")
    func underlineFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x04, fontWeight: 0, fontId: 0)
        #expect(span.isUnderline == true)
    }

    @Test("Strikethrough flag is bit 3")
    func strikethroughFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x08, fontWeight: 0, fontId: 0)
        #expect(span.isStrikethrough == true)
    }

    @Test("Curl flag is bit 4")
    func curlFlag() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x10, fontWeight: 0, fontId: 0)
        #expect(span.isCurl == true)
    }

    @Test("Combined bold+italic+underline")
    func combinedFlags() {
        let span = GUIHighlightSpan(startCol: 0, endCol: 5, fg: 0, bg: 0,
                                     attrs: 0x07, fontWeight: 0, fontId: 0)
        #expect(span.isBold == true)
        #expect(span.isItalic == true)
        #expect(span.isUnderline == true)
        #expect(span.isStrikethrough == false)
        #expect(span.isCurl == false)
    }
}

// MARK: - CursorShape

@Suite("CursorShape Raw Values")
struct CursorShapeTests {

    @Test("Block is 0x00")
    func block() {
        #expect(CursorShape.block.rawValue == 0x00)
    }

    @Test("Beam is 0x01")
    func beam() {
        #expect(CursorShape.beam.rawValue == 0x01)
    }

    @Test("Underline is 0x02")
    func underline() {
        #expect(CursorShape.underline.rawValue == 0x02)
    }
}

// MARK: - ToolCategory/Status/Method labels

@Suite("Tool Enum Display Labels")
struct ToolEnumLabelTests {

    @Test("ToolCategory labels match expected strings")
    func categoryLabels() {
        #expect(ToolCategory.lspServer.label == "Language Servers")
        #expect(ToolCategory.formatter.label == "Formatters")
        #expect(ToolCategory.linter.label == "Linters")
        #expect(ToolCategory.debugger.label == "Debuggers")
    }

    @Test("ToolStatus labels match expected strings")
    func statusLabels() {
        #expect(ToolStatus.notInstalled.label == "Not installed")
        #expect(ToolStatus.installed.label == "Installed")
        #expect(ToolStatus.installing.label == "Installing...")
        #expect(ToolStatus.updateAvailable.label == "Update available")
        #expect(ToolStatus.failed.label == "Failed")
    }

    @Test("ToolMethod labels match expected strings")
    func methodLabels() {
        #expect(ToolMethod.npm.label == "npm")
        #expect(ToolMethod.pip.label == "pip")
        #expect(ToolMethod.cargo.label == "cargo")
        #expect(ToolMethod.goInstall.label == "go install")
        #expect(ToolMethod.githubRelease.label == "GitHub Release")
    }

    @Test("ToolFilter labels match expected strings")
    func filterLabels() {
        #expect(ToolFilter.all.label == "All")
        #expect(ToolFilter.installed.label == "Installed")
        #expect(ToolFilter.notInstalled.label == "Available")
        #expect(ToolFilter.lspServers.label == "Servers")
        #expect(ToolFilter.formatters.label == "Formatters")
    }
}

// MARK: - WhichKeyBinding

@Suite("WhichKeyBinding Computed Properties")
struct WhichKeyBindingTests {

    @Test("isGroup is true when kind == 1")
    func isGroupTrue() {
        let binding = WhichKeyBinding(id: 0, isGroup: true, key: "b",
                                      description: "Buffers", icon: "")
        #expect(binding.isGroup == true)
    }

    @Test("isGroup is false when kind == 0")
    func isGroupFalse() {
        let binding = WhichKeyBinding(id: 0, isGroup: false, key: "f",
                                      description: "Find file", icon: "🔍")
        #expect(binding.isGroup == false)
    }
}

// MARK: - FileTreeState fullPath

@Suite("FileTreeState Path Computation")
struct FileTreePathTests {

    @Test("fullPath with empty projectRoot returns relPath")
    @MainActor func emptyRoot() {
        let state = FileTreeState()
        state.projectRoot = ""
        let entry = FileTreeEntry(id: 1, index: 0, isDir: false,
                                  isExpanded: false, isSelected: false,
                                  depth: 0, gitStatus: 0, icon: "",
                                  name: "test", relPath: "lib/test.ex")
        #expect(state.fullPath(for: entry) == "lib/test.ex")
    }

    @Test("fullPath with empty relPath returns relPath")
    @MainActor func emptyRelPath() {
        let state = FileTreeState()
        state.projectRoot = "/project"
        let entry = FileTreeEntry(id: 1, index: 0, isDir: false,
                                  isExpanded: false, isSelected: false,
                                  depth: 0, gitStatus: 0, icon: "",
                                  name: "test", relPath: "")
        #expect(state.fullPath(for: entry) == "")
    }
}
