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

        return CompletionOverlay(state: state, sendAction: { _ in })
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
            PickerOverlay(state: state, sendAction: { _ in })
        }
        .frame(width: 600, height: 400)
        .clipped()
        .environment(theme)
    }

    /// Model rows grouped by route under section headers, with readiness and plan usage in a status chip, one row per tone, the current model marked and its description on a second line. The setup row has a chip too; the ungrouped long path row keeps its file name inline and has no header.
    static func pickerModelRowsPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = PickerState()
        let active: UInt8 = 0x08
        let tail = "1000k ctx · thinking medium · tools, images, streaming"
        let claude = "Claude (subscription)"
        let rows: [Wire.PickerItem] = [
            Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}picker_item_row_test.exs", description: "test/minga_editor/render_model/ui/picker/agent_model_source/description_overflow/picker_item_row_test.exs", annotation: "", matchPositions: [], activationID: 9),
            Wire.PickerItem(iconColor: 0, flags: active, label: "Claude Opus 4", description: "Claude Max · 5h limit resets 3:59 PM · \(tail)", annotation: "★ favorite", matchPositions: [], activationID: 1, status: "Ready · 45%", statusTone: .ready, group: claude),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Claude Sonnet 4", description: "Claude Max · 5h limit resets 3:40 PM · \(tail)", annotation: "", matchPositions: [], activationID: 2, status: "Ready · 82%", statusTone: .warn, group: claude),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Claude Opus 4.1", description: "Claude Max · 5h limit resets Sun 12:32 AM · \(tail)", annotation: "", matchPositions: [], activationID: 3, status: "Limit reached", statusTone: .error, group: claude),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Claude Haiku 4", description: "Claude Max · checking plan usage · 200k ctx · thinking fixed", annotation: "", matchPositions: [], activationID: 4, status: "Checking…", statusTone: .checking, group: claude),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Claude Haiku 3.5", description: "Run claude login in a terminal, then reopen /model. · 200k ctx", annotation: "", matchPositions: [], activationID: 5, status: "Unavailable", statusTone: .error, group: claude),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Claude Sonnet 4 (API)", description: "$3/15 per MTok · 200k ctx · thinking medium", annotation: "", matchPositions: [], activationID: 6, status: "Ready", statusTone: .ready, group: "anthropic API"),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Fixture Model", description: "200k ctx · thinking off · tools, images, streaming", annotation: "", matchPositions: [], activationID: 7, status: "Not checked", statusTone: .neutral, group: "Fixture Route"),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Use Claude subscription", description: "Uses the Claude app login. Minga never sees your login. · Claude Max", annotation: "", matchPositions: [], activationID: 8, status: "Ready", statusTone: .ready, group: "Routes"),
            Wire.PickerItem(iconColor: 0, flags: 0, label: "Connect another provider…", description: "Sign in, manage API keys, or retry the connection.", annotation: "", matchPositions: [], activationID: 10, group: "Connections"),
        ]
        state.update(
            visible: true,
            selectedIndex: 2,
            filteredCount: UInt16(rows.count),
            totalCount: UInt16(rows.count),
            markedCount: 0,
            title: "Models and connections",
            query: "",
            hasPreview: false,
            rawItems: rows,
            actionMenu: nil,
            modePrefix: "",
            activationGeneration: 1
        )

        return ZStack {
            theme.editorBg
            PickerOverlay(state: state, sendAction: { _ in })
        }
        .frame(width: 680, height: 900)
        .clipped()
        .environment(theme)
    }

    /// Mixed 24pt and 40pt rows that overflow the list, with the selection moved to a stacked row near the bottom after the list appears.
    static func pickerMixedScrollPreview() -> some View {
        PickerMixedScrollFixture(theme: PreviewFixtures.theme())
    }

    // MARK: - MinibufferView

    static func minibufferPreview() -> some View {
        let theme = PreviewFixtures.theme()
        let state = MinibufferState()
        state.update(
            visible: true,
            mode: .command,
            cursorPos: 7,
            prompt: "M-x ",
            input: "org-mod",
            context: "",
            selectedIndex: 0,
            totalCandidates: 23,
            generation: 1,
            rawCandidates: [
                Wire.MinibufferCandidate(id: "org-mode", matchScore: 95, label: "org-mode", description: "Toggle Org major mode", annotation: "SPC m o", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
                Wire.MinibufferCandidate(id: "org-mode-restart", matchScore: 80, label: "org-mode-restart", description: "Restart Org mode parser", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6]),
                Wire.MinibufferCandidate(id: "org-modernize", matchScore: 72, label: "org-modernize", description: "Modernize Org buffer syntax", annotation: "", matchPositions: [0, 1, 2, 3, 4, 5, 6, 8]),
            ]
        )

        return MinibufferView(state: state, sendAction: { _ in })
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
                Wire.WhichKeyBinding(kind: 1, key: "f", description: "Files ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "Buffers ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "w", description: "Windows ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "g", description: "Git ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "s", description: "Search ›", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: ":", description: "M-x command", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: ".", description: "repeat", icon: ""),
                Wire.WhichKeyBinding(kind: 0, key: "/", description: "search project", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "p", description: "Project ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "t", description: "Toggles ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "c", description: "Code ›", icon: ""),
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
                Wire.WhichKeyBinding(kind: 1, key: "b", description: "Branch ›", icon: ""),
                Wire.WhichKeyBinding(kind: 1, key: "r", description: "Rebase ›", icon: ""),
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
        state.update(
            active: true,
            matchCount: 12,
            currentIndex: 3,
            flags: 0,
            query: "needle",
            sessionID: 1,
            acknowledgedEditSeq: 0
        )

        return SearchToolbar(searchState: state, sendAction: { _ in })
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

        return HoverPopupOverlay(state: state, sendAction: { _ in })
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

/// Owns its picker state across body re-evaluation so the post-appearance selection change drives the overlay's real scroll-to-selection path.
private struct PickerMixedScrollFixture: View {
    let theme: ThemeColors
    @State private var state = Self.initialState()

    private static let rows: [Wire.PickerItem] = (0..<16).map { index in
        if index.isMultiple(of: 2) {
            return Wire.PickerItem(iconColor: 0, flags: 0, label: "Model \(index)", description: "Claude (subscription) · Claude Max · 5h limit resets 2:50 PM", annotation: "", matchPositions: [], activationID: UInt32(index + 1), status: "Ready · \(index * 5)%", statusTone: .ready)
        }
        return Wire.PickerItem(iconColor: 0x98BE65, flags: 0, label: "\u{f0e7}file_\(index).ex", description: "lib/minga_editor/render_model/ui/picker/file_\(index).ex", annotation: "", matchPositions: [], activationID: UInt32(index + 1))
    }

    var body: some View {
        ZStack {
            theme.editorBg
            PickerOverlay(state: state, sendAction: { _ in })
        }
        .frame(width: 680, height: 600)
        .clipped()
        .environment(theme)
        .task {
            // Change the selection after the list exists, as a keypress would.
            try? await Task.sleep(for: .milliseconds(50))
            Self.show(14, in: state)
        }
    }

    private static func initialState() -> PickerState {
        let state = PickerState()
        show(0, in: state)
        return state
    }

    private static func show(_ selected: UInt16, in state: PickerState) {
        state.update(visible: true, selectedIndex: selected, filteredCount: 16, totalCount: 16, markedCount: 0, title: "Mixed Rows", query: "", hasPreview: false, rawItems: rows, actionMenu: nil, activationGeneration: 1)
    }
}
