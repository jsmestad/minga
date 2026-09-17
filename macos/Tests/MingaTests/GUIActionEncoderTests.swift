/// Tests that the canonical outbound values preserve action identity and order.

import MingaUI
import Testing
import Foundation
import os

@Suite("Canonical Outbound Action Recording")
struct GUIActionEncoderTests {

    @Test("an explicitly inert preview sink accepts and discards its action")
    func deliberatePreviewDiscard() {
        let encoder = ClosureOutboundActionEncoder { _ in .accepted }

        #expect(encoder.send(.newTab) == .accepted)
    }

    @Test("sendSelectTab records tab ID")
    func selectTab() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.selectTab(id: 42))

        #expect(spy.actions == [.selectTab(id: 42)])
    }

    @Test("sendCloseTab records tab ID")
    func closeTab() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.closeTab(id: 99))

        #expect(spy.actions == [.closeTab(id: 99)])
    }

    @Test("tab context menu actions record tab IDs")
    func tabContextMenuActions() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.tabPin(id: 7))
        encoder.send(.tabUnpin(id: 8))
        encoder.send(.tabMoveLeft(id: 9))
        encoder.send(.tabMoveRight(id: 10))

        #expect(spy.actions == [
            .tabPin(id: 7),
            .tabUnpin(id: 8),
            .tabMoveLeft(id: 9),
            .tabMoveRight(id: 10)
        ])
    }

    @Test("sendNewTab records action")
    func newTab() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.newTab)

        #expect(spy.actions == [.newTab])
    }

    @Test("sendSystemWillSleep records action")
    func systemWillSleep() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.systemWillSleep)

        #expect(spy.actions == [.systemWillSleep])
    }

    @Test("sendSystemDidWake records action")
    func systemDidWake() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.systemDidWake)

        #expect(spy.actions == [.systemDidWake])
    }

    @Test("sendFoldToggleAtLine records buffer line")
    func foldToggleAtLine() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.foldToggleAtLine(windowID: 7, bufferLine: 42))

        #expect(spy.actions == [.foldToggleAtLine(windowID: 7, bufferLine: 42)])
    }

    @Test("sendFileTreeClick records index")
    func fileTreeClick() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.fileTreeClick(index: 5))

        #expect(spy.actions == [.fileTreeClick(index: 5)])
    }

    @Test("sendFileTreeToggle records index")
    func fileTreeToggle() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.fileTreeToggle(index: 3))

        #expect(spy.actions == [.fileTreeToggle(index: 3)])
    }

    @Test("sendCompletionSelect records stable item ID")
    func completionSelect() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.completionSelect(itemID: "item-0"))

        #expect(spy.actions == [.completionSelect(itemID: "item-0")])
    }


    @Test("sendTogglePanel records panel ID")
    func togglePanel() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.togglePanel(panel: 0))
        encoder.send(.togglePanel(panel: 1))

        #expect(spy.actions == [.togglePanel(panel: 0), .togglePanel(panel: 1)])
    }

    @Test("sendSidebarAction records semantic action")
    func sidebarAction() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.sidebarAction(sidebarID: "git_status", kind: "git_status", action: "toggle"))

        #expect(spy.actions == [.sidebarAction(sidebarID: "git_status", kind: "git_status", action: "toggle")])
    }

    @Test("panel actions record correctly")
    func panelActions() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.panelSwitchTab(index: 2))
        encoder.send(.panelDismiss)
        encoder.send(.panelResize(heightPercent: 40))

        #expect(spy.actions == [
            .panelSwitchTab(index: 2),
            .panelDismiss,
            .panelResize(heightPercent: 40)
        ])
    }

    @Test("file tree management actions record correctly")
    func fileTreeManagement() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.fileTreeNewFile(parentIndex: 5))
        encoder.send(.fileTreeNewFolder(parentIndex: 3))
        encoder.send(.fileTreeCollapseAll)
        encoder.send(.fileTreeRefresh)

        #expect(spy.actions == [
            .fileTreeNewFile(parentIndex: 5), .fileTreeNewFolder(parentIndex: 3),
            .fileTreeCollapseAll, .fileTreeRefresh
        ])
    }

    @Test("file tree drop action records stable target identity and source paths")
    func fileTreeDropAction() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.fileTreeDrop(sourcePaths: ["/tmp/from.txt"], targetIndex: 9, targetID: "/project/lib", targetPathHash: 0xABCD, targetPath: "/project/lib", targetIsDirectory: true, modifiers: 0))

        #expect(spy.actions == [
            .fileTreeDrop(sourcePaths: ["/tmp/from.txt"], targetIndex: 9, targetID: "/project/lib", targetPathHash: 0xABCD, targetPath: "/project/lib", targetIsDirectory: true, modifiers: 0)
        ])
    }

    @Test("file tree edit confirm and cancel actions record correctly")
    func fileTreeEditActions() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.fileTreeEditConfirm(token: 0x01020304, text: "newfile.txt"))
        encoder.send(.fileTreeEditCancel)

        #expect(spy.actions == [
            .fileTreeEditConfirm(token: 0x01020304, text: "newfile.txt"),
            .fileTreeEditCancel
        ])
    }


    @Test("sendAgentToolToggle records stable message ID")
    func agentToolToggle() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.agentToolToggle(messageID: 0x01020304))

        #expect(spy.actions == [.agentToolToggle(messageID: 0x01020304)])
    }

    @Test("sendOpenFile records path")
    func openFile() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.openFile(path: "/home/user/project/lib/editor.ex"))

        #expect(spy.actions == [.openFile(path: "/home/user/project/lib/editor.ex")])
    }

    @Test("key press recording captures codepoint and modifiers")
    func keyPress() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.keyPress(codepoint: 27, modifiers: 0x02, sequence: 0)) // Escape + Ctrl

        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == 27)
        #expect(spy.keyPressCalls[0].modifiers == 0x02)
    }

    @Test("mouse event recording captures all fields")
    func mouseEvent() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.mouse(row: 10, column: 20, button: MOUSE_BUTTON_LEFT,
                            modifiers: 0x01, eventType: MOUSE_PRESS, clickCount: 2))

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].row == 10)
        #expect(spy.mouseEventCalls[0].col == 20)
        #expect(spy.mouseEventCalls[0].button == MOUSE_BUTTON_LEFT)
        #expect(spy.mouseEventCalls[0].clickCount == 2)
    }

    @Test("sendExecuteCommand records command name")
    func executeCommand() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.executeCommand(name: "buffer_prev"))

        #expect(spy.actions == [.executeCommand(name: "buffer_prev")])
    }

    @Test("sendExecuteCommand handles various command names")
    func executeCommandVariety() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.executeCommand(name: "split_vertical"))
        encoder.send(.executeCommand(name: "find_file"))
        encoder.send(.executeCommand(name: "open_config"))

        #expect(spy.actions == [
            .executeCommand(name: "split_vertical"),
            .executeCommand(name: "find_file"),
            .executeCommand(name: "open_config")
        ])
    }

    @Test("multiple action types accumulate independently")
    func mixedActions() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.selectTab(id: 1))
        encoder.send(.paste("hello"))
        encoder.send(.fileTreeClick(index: 0))

        #expect(spy.actions.count == 3)
        #expect(spy.pasteCalls.count == 1)
    }

    @Test("chat pin intents record scrolled-away and returned-to-bottom")
    func chatPinIntents() {
        let spy = SpyEncoder()
        let encoder: OutboundActionEncoding = spy
        encoder.send(.chatScrolledAwayFromBottom)
        encoder.send(.chatReturnedToBottom)

        #expect(spy.actions == [.chatScrolledAwayFromBottom, .chatReturnedToBottom])
    }
}
