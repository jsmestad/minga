import MingaUI
import SwiftUI
import MingaProtocol

@MainActor
extension PreviewRegistry {

    // MARK: - CompletionOverlay

    static func completionPreview() -> some View {
        let theme = PreviewFixtures.theme()

        return completionPopupPreview()
            .frame(width: 400, height: 300)
            .background(theme.editorBg)
            .environment(theme)
    }

    static func completionPopupPreview() -> some View {
        let state = CompletionState()
        state.update(
            visible: true, anchorRow: 5, anchorCol: 10, selectedIndex: 1,
            rawItems: [
                Wire.CompletionItem(kind: 7, label: "defmodule", detail: "keyword"),
                Wire.CompletionItem(kind: 7, label: "defstruct", detail: "keyword"),
                Wire.CompletionItem(kind: 7, label: "defdelegate", detail: "keyword"),
                Wire.CompletionItem(kind: 2, label: "def", detail: "keyword"),
                Wire.CompletionItem(kind: 1, label: "Document", detail: "Minga.Buffer.Document"),
            ],
            documentation: "Defines a struct for the module.\n\nFields are given as a keyword list."
        )

        return CompletionOverlay(state: state, encoder: nil)
    }

    // MARK: - PickerOverlay

    static func pickerPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = PickerState()
        state.update(
            visible: true,
            selectedIndex: 1,
            filteredCount: 5,
            totalCount: 42,
            markedCount: 0,
            title: "Find File",
            query: "edit",
            hasPreview: false,
            rawItems: [
                Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}editor.ex", description: "lib/minga/editor.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0x98BE65, flags: 0x01, label: "\u{f0e7}editor_test.exs", description: "test/minga/editor_test.exs", annotation: "test", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0x51AFEF, flags: 0, label: "\u{f0e7}EditorNSView.swift", description: "macos/Sources/EditorNSView.swift", annotation: "swift", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0xECBE7B, flags: 0, label: "\u{f085}edit_mode.ex", description: "lib/minga/mode/edit_mode.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
                Wire.PickerItem(iconColor: 0xC678DD, flags: 0, label: "\u{f0e7}editor_config.ex", description: "lib/minga/editor/config.ex", annotation: "", matchPositions: [1, 2, 3, 4]),
            ],
            actionMenu: nil,
            modePrefix: ""
        )

        return ZStack {
            theme.editorBg
            PickerOverlay(state: state, encoder: nil)
        }
        .frame(width: 600, height: 400)
        .clipped()
        .environment(theme)
    }

    // MARK: - MinibufferView

    static func minibufferPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = MinibufferState()
        state.update(
            visible: true,
            mode: MinibufferMode.command.rawValue,
            cursorPos: 7,
            prompt: "M-x ",
            input: "org-mod",
            context: "",
            selectedIndex: 0,
            totalCandidates: 23,
            rawCandidates: [
                Wire.MinibufferCandidate(matchScore: 95, label: "org-mode", description: "Toggle Org major mode", annotation: "SPC m o", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
                Wire.MinibufferCandidate(matchScore: 80, label: "org-mode-restart", description: "Restart Org mode parser", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
                Wire.MinibufferCandidate(matchScore: 72, label: "org-modernize", description: "Modernize Org buffer syntax", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6, 8]),
            ]
        )

        return MinibufferView(state: state, encoder: nil)
            .frame(width: 600, height: 140)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - WhichKeyOverlay

    static func whichKeyPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = WhichKeyState()
        state.update(
            visible: true,
            prefix: "SPC",
            page: 0,
            pageCount: 1,
            rawBindings: [
                Wire.WhichKeyBinding(kind: 1, key: "f", description: "+file", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "+buffer", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "w", description: "+window", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "g", description: "+git", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "s", description: "+search", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: ":", description: "M-x command", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: ".", description: "repeat", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "/", description: "search project", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "p", description: "+project", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "t", description: "+toggle", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "c", description: "+code", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "e", description: "file tree", icon: ""),
            ]
        )

        return WhichKeyOverlay(state: state)
            .frame(width: 520, height: 300)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - WhichKeyPaged

    static func whichKeyPagedPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = WhichKeyState()
        state.update(
            visible: true,
            prefix: "SPC g",
            page: 1,
            pageCount: 3,
            rawBindings: [
                Wire.WhichKeyBinding(kind: 0, key: "s", description: "stage file", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "u", description: "unstage file", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "c", description: "commit", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "p", description: "push", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "f", description: "fetch", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "d", description: "diff", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "+branch", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "r", description: "+rebase", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "l", description: "log", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "z", description: "stash", icon: ""),
            ]
        )

        return WhichKeyOverlay(state: state)
            .frame(width: 520, height: 300)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - SearchToolbar

    static func searchToolbarPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = SearchState()
        state.update(active: true, matchCount: 12, currentIndex: 3, flags: 0)

        return SearchToolbar(searchState: state, encoder: nil)
            .frame(width: 800, height: 40)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - HoverPopupOverlay

    static func hoverPopupPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = HoverPopupState()
        state.update(
            visible: true, anchorRow: 8, anchorCol: 4,
            focused: false, scrollOffset: 0,
            rawLines: [
                Wire.HoverLine(lineType: .header, segments: [
                    Wire.HoverSegment(style: .header2, fgColor: nil, flags: 0, text: "Buffer.open/1"),
                ]),
                Wire.HoverLine(lineType: .empty, segments: []),
                Wire.HoverLine(lineType: .text, segments: [
                    Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "Opens a file from disk and returns a managed buffer process."),
                ]),
                Wire.HoverLine(lineType: .text, segments: [
                    Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "The buffer is registered under the given path and will be reused"),
                ]),
                Wire.HoverLine(lineType: .text, segments: [
                    Wire.HoverSegment(style: .plain, fgColor: nil, flags: 0, text: "on subsequent calls with the same path."),
                ]),
                Wire.HoverLine(lineType: .empty, segments: []),
                Wire.HoverLine(lineType: .codeHeader, segments: [
                    Wire.HoverSegment(style: .codeBlock, fgColor: nil, flags: 0, text: "elixir"),
                ]),
                Wire.HoverLine(lineType: .code, segments: [
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xC678DD, flags: 1, text: "@spec "),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0x61AFEF, flags: 0, text: "open"),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: "("),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xE5C07B, flags: 0, text: "String.t()"),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xBBC2CF, flags: 0, text: ") :: "),
                    Wire.HoverSegment(style: .syntaxHighlighted, fgColor: 0xE5C07B, flags: 0, text: "{:ok, pid()}"),
                ]),
                Wire.HoverLine(lineType: .empty, segments: []),
                Wire.HoverLine(lineType: .blockquote, segments: [
                    Wire.HoverSegment(style: .blockquote, fgColor: nil, flags: 0, text: "Since: v0.4.0"),
                ]),
            ]
        )

        return HoverPopupOverlay(state: state, encoder: nil)
            .frame(width: 500, height: 300)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - SignatureHelpOverlay

    static func signatureHelpPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = SignatureHelpState()
        state.update(
            visible: true, anchorRow: 8, anchorCol: 6,
            activeSignature: 0, activeParameter: 1,
            rawSignatures: [
                Wire.Signature(
                    label: "GenServer.start_link(module, init_arg, options)",
                    documentation: "Starts a GenServer process linked to the current process.",
                    parameters: [
                        Wire.SignatureParameter(label: "module", documentation: "The module implementing the GenServer callbacks."),
                        Wire.SignatureParameter(label: "init_arg", documentation: "The argument passed to init/1."),
                        Wire.SignatureParameter(label: "options", documentation: "Options such as :name, :timeout, and :hibernate_after."),
                    ]
                ),
            ]
        )

        return SignatureHelpOverlay(state: state)
            .frame(width: 500, height: 200)
            .background(theme.editorBg)
            .environment(theme)
    }

    // MARK: - LatencyHUDOverlay

    static func latencyHUDPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = LatencyHUDState(environment: ["MINGA_LATENCY_HUD": "1"])
        state.stats = LatencyRecorder.Stats(
            apply: .init(count: 128, p50Micros: 812, p95Micros: 1_200),
            present: .init(count: 120, p50Micros: 2_450, p95Micros: 5_100),
            submittedCount: 120,
            discardCounts: [.superseded: 8]
        )

        return LatencyHUDOverlay(state: state)
            .frame(width: 520, height: 120)
            .background(theme.editorBg)
            .environment(theme)
    }

    static func latencyHUDEmptyPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = LatencyHUDState(environment: ["MINGA_LATENCY_HUD": "1"])

        return LatencyHUDOverlay(state: state)
            .frame(width: 520, height: 120)
            .background(theme.editorBg)
            .environment(theme)
    }
}
