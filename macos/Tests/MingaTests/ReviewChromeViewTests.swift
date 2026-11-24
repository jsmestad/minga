import AppKit
import MingaUI
import MingaProtocol
import SwiftUI
import Testing
import ViewInspector

@Suite("Review chrome native controls")
struct ReviewChromeViewTests {
    private func offer(_ freshness: StatusBarUpdate.Review.Freshness = .stale, generation: UInt32 = 41, itemID: String = "opaque:é/👩‍💻?original=1") -> StatusBarUpdate.Review {
        .init(path: "lib/é/duplicate.ex", freshness: freshness, generation: generation, itemID: itemID)
    }

    private func status(_ review: StatusBarUpdate.Review?) -> StatusBarUpdate {
        .init(
            contentKind: 0, mode: 0, cursorLine: 1, cursorCol: 1, lineCount: 20,
            flags: 0, lspStatus: 0, gitBranch: "main", message: "ordinary metadata",
            filetype: "elixir", errorCount: 0, warningCount: 0, modelName: "",
            messageCount: 0, sessionStatus: 0, infoCount: 0, hintCount: 0,
            macroRecording: 0, parserStatus: 0, agentStatus: 0,
            gitAdded: 0, gitModified: 0, gitDeleted: 0, icon: "",
            iconColorR: 0, iconColorG: 0, iconColorB: 0, filename: "ordinary.ex",
            diagnosticHint: "", backgroundSubagentCount: 0, backgroundSubagentLabel: "",
            review: review
        )
    }

    @Test("Retained Back and Refresh Buttons use the original committed offer")
    @MainActor func immutableActionCapture() throws {
        let state = StatusBarState()
        state.update(from: status(offer()))
        let spy = SpyEncoder()
        let sut = StatusBarView(state: state, sendAction: { action in
            _ = spy.send(FrontendActionComposition.outbound(action))
        }).environment(\.themeColors, ThemeColors())
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        let back = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Back to chat" })
        let refresh = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Review latest changes in lib/é/duplicate.ex" })
        state.update(from: status(offer(.current, generation: 42, itemID: "replacement")))
        try back.tap()
        try refresh.tap()
        #expect(spy.actions == [
            .semanticItemActivate(surface: .review, intent: 1, generation: 41, itemID: Data(offer().itemID.utf8)),
            .semanticItemActivate(surface: .review, intent: 2, generation: 41, itemID: Data(offer().itemID.utf8))
        ])
    }

    @Test("Compact Review keeps individually labelled icon Buttons without an overflow menu", arguments: [StatusBarUpdate.Review.Freshness.current, .stale])
    @MainActor func narrowButtons(freshness: StatusBarUpdate.Review.Freshness) throws {
        let spy = SpyEncoder()
        let sut = StatusBarView.ReviewButtons(review: offer(freshness), compact: true, sendAction: { action in
            _ = spy.send(FrontendActionComposition.outbound(action))
        }).frame(width: 160, height: 24)
        let body = try sut.inspect()
        let buttons = body.findAll(ViewType.Button.self)
        #expect(buttons.count == 3)
        #expect(try buttons.map { try $0.accessibilityLabel().string() } == [
            "Back to chat", "Review latest changes in lib/é/duplicate.ex", "Agent help"
        ])
        #expect(body.findAll(ViewType.Image.self).count == 3)
        #expect(body.findAll(ViewType.Menu.self).isEmpty)
        #expect(try buttons[1].isDisabled() == (freshness == .current))
        if freshness == .current {
            #expect(throws: (any Error).self) { try buttons[1].tap() }
            #expect(spy.actions.isEmpty)
        }
        try buttons[0].tap()
        try buttons[2].tap()
        #expect(spy.actions.last == .executeCommand(name: "agent_toggle_help"))
        #expect(spy.keyPressCalls.isEmpty)
    }

    @Test("Review replaces ordinary status metadata with textual read-only freshness", arguments: [StatusBarUpdate.Review.Freshness.current, .stale])
    @MainActor func reviewStatusBranch(freshness: StatusBarUpdate.Review.Freshness) throws {
        let state = StatusBarState()
        state.update(from: status(offer(freshness)))
        let sut = StatusBarView(state: state, sendAction: { _ in })
            .environment(\.themeColors, ThemeColors())
        let body = try sut.inspect()
        let texts = body.findAll(ViewType.Text.self)
        let strings = texts.compactMap { try? $0.string() }
        #expect(strings.contains(freshness == .stale ? "RO · Stale" : "RO · Current"))
        #expect(!strings.contains("ordinary metadata"))
        #expect(!strings.contains("NORMAL"))
        #expect(!strings.contains("ordinary.ex"))
        #expect(body.findAll(ViewType.Button.self).count == 3)
        let status = try body.find(StatusBarView.ReviewFreshnessLabel.self)
        #expect(try status.zStack().accessibilityLabel().string() ==
                (freshness == .stale ? "Read-only Review, stale" : "Read-only Review, current"))
    }

    @Test("Normal Review controls show full labels and keep Refresh's disabled slot")
    @MainActor func fullLabels() throws {
        let sut = StatusBarView.ReviewButtons(review: offer(.current), compact: false, sendAction: { _ in })
        let body = try sut.inspect()
        let buttons = body.findAll(ViewType.Button.self)
        #expect(try buttons.map { try $0.labelView().find(ViewType.Text.self).string() } == ["Back to chat", "Review latest", "Help"])
        #expect(buttons.count == 3)
        #expect(try buttons[1].isDisabled())
    }

    @Test("Conflict decisions name the keys the BEAM binds for the active editing model", arguments: [("x", "y"), ("Cmd+Backspace", "Cmd+Enter")])
    @MainActor func conflictKeyLabels(keys: (String, String)) throws {
        let conflict = StatusBarUpdate.Review(path: "note.txt", freshness: .current, generation: 9, itemID: "hunk", conflictIndex: 1, keepMineKey: keys.0, useAgentKey: keys.1)
        let sut = StatusBarView.ReviewButtons(review: conflict, compact: false, sendAction: { _ in })
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        #expect(try buttons.prefix(2).map { try $0.labelView().find(ViewType.Text.self).string() } == [
            "Keep mine (\(keys.0))", "Use Agent version (\(keys.1))"
        ])
        #expect(try buttons.prefix(2).map { try $0.accessibilityLabel().string() } == [
            "Keep my version (\(keys.0))", "Use Agent version (\(keys.1))"
        ])
    }

    @Test("Freshness changes preserve the intrinsic space before Review controls", arguments: [false, true])
    @MainActor func stableFreshnessAllocation(compact: Bool) {
        let current = NSHostingView(rootView: StatusBarView.ReviewFreshnessLabel(freshness: .current, compact: compact))
        let stale = NSHostingView(rootView: StatusBarView.ReviewFreshnessLabel(freshness: .stale, compact: compact))
        #expect(current.fittingSize.width > 0)
        #expect(current.fittingSize == stale.fittingSize)
    }

    @Test("Disconnected Review keeps all three controls visible but disabled")
    @MainActor func disconnectedControls() throws {
        let sut = StatusBarView.ReviewButtons(review: offer(), compact: true, sendAction: nil)
        let buttons = try sut.inspect().findAll(ViewType.Button.self)
        #expect(buttons.count == 3)
        #expect(try buttons.allSatisfy { try $0.isDisabled() })
    }
}

@Suite("Independent Agent Help native controls")
struct AgentHelpViewTests {
    @Test("Help renders independent groups and Close sends a directional command", arguments: [CGFloat(160), CGFloat(600)])
    @MainActor func closeHelp(width: CGFloat) throws {
        let state = AgentHelpState()
        state.update(visible: true, groups: [
            .init(title: "Review", bindings: [(key: "Tab", description: "Back to chat")]),
            .init(title: "Review", bindings: [(key: "?", description: "Toggle help")])
        ])
        let spy = SpyEncoder()
        let sut = AgentHelpView(state: state, sendAction: { action in
            _ = spy.send(FrontendActionComposition.outbound(action))
        }).environment(\.themeColors, ThemeColors()).frame(width: width, height: 240)
        let body = try sut.inspect()
        let buttons = body.findAll(ViewType.Button.self)
        let close = try #require(buttons.first { (try? $0.accessibilityLabel().string()) == "Close Help" })
        #expect(buttons.count == 1)
        #expect(body.findAll(ViewType.ScrollView.self).count == 1)
        let strings = body.findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(strings.contains("Back to chat"))
        #expect(strings.contains("Toggle help"))
        try close.tap()
        #expect(spy.actions == [.executeCommand(name: "agent_dismiss_help")])
        #expect(spy.keyPressCalls.isEmpty)
        // Only the next committed backend update may hide Help.
        #expect(state.visible)
        #expect(state.groups.count == 2)
        state.update(visible: false, groups: [])
        #expect(!state.visible)
        #expect(state.groups.isEmpty)
    }
}
