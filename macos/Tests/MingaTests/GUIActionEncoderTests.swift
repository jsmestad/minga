/// Tests that GUI action calls through InputEncoder are correctly recorded.
///
/// These tests verify the contract that views use: call encoder?.sendFoo()
/// and the correct action is dispatched. Since views accept InputEncoder?
/// (not ProtocolEncoder), these tests use SpyEncoder to verify the protocol
/// abstraction works end-to-end.
///
/// Previously, some views cast to ProtocolEncoder, which meant SpyEncoder
/// never received the calls. The InputEncoder cast fix (commit e9212e03)
/// made these testable.

import Testing
import Foundation
import os

@Suite("GUI Action Recording via InputEncoder")
struct GUIActionEncoderTests {

    @Test("sendSelectTab records tab ID")
    func selectTab() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendSelectTab(id: 42)

        #expect(spy.guiActions == [.selectTab(id: 42)])
    }

    @Test("sendCloseTab records tab ID")
    func closeTab() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendCloseTab(id: 99)

        #expect(spy.guiActions == [.closeTab(id: 99)])
    }

    @Test("sendNewTab records action")
    func newTab() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendNewTab()

        #expect(spy.guiActions == [.newTab])
    }

    @Test("sendFileTreeClick records index")
    func fileTreeClick() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendFileTreeClick(index: 5)

        #expect(spy.guiActions == [.fileTreeClick(index: 5)])
    }

    @Test("sendFileTreeToggle records index")
    func fileTreeToggle() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendFileTreeToggle(index: 3)

        #expect(spy.guiActions == [.fileTreeToggle(index: 3)])
    }

    @Test("sendCompletionSelect records index")
    func completionSelect() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendCompletionSelect(index: 0)

        #expect(spy.guiActions == [.completionSelect(index: 0)])
    }

    @Test("sendBreadcrumbClick records index")
    func breadcrumbClick() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendBreadcrumbClick(index: 2)

        #expect(spy.guiActions == [.breadcrumbClick(index: 2)])
    }

    @Test("sendTogglePanel records panel ID")
    func togglePanel() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendTogglePanel(panel: 0)
        encoder.sendTogglePanel(panel: 1)

        #expect(spy.guiActions == [.togglePanel(panel: 0), .togglePanel(panel: 1)])
    }

    @Test("panel actions record correctly")
    func panelActions() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendPanelSwitchTab(index: 2)
        encoder.sendPanelDismiss()
        encoder.sendPanelResize(heightPercent: 40)

        #expect(spy.guiActions == [
            .panelSwitchTab(index: 2),
            .panelDismiss,
            .panelResize(heightPercent: 40)
        ])
    }

    @Test("file tree management actions record correctly")
    func fileTreeManagement() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendFileTreeNewFile()
        encoder.sendFileTreeNewFolder()
        encoder.sendFileTreeCollapseAll()
        encoder.sendFileTreeRefresh()

        #expect(spy.guiActions == [
            .fileTreeNewFile, .fileTreeNewFolder,
            .fileTreeCollapseAll, .fileTreeRefresh
        ])
    }

    @Test("tool manager actions record name correctly")
    func toolActions() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendToolInstall(name: "elixir_ls")
        encoder.sendToolUninstall(name: "prettier")
        encoder.sendToolUpdate(name: "rust_analyzer")
        encoder.sendToolDismiss()

        #expect(spy.guiActions == [
            .toolInstall(name: "elixir_ls"),
            .toolUninstall(name: "prettier"),
            .toolUpdate(name: "rust_analyzer"),
            .toolDismiss
        ])
    }

    @Test("sendOpenFile records path")
    func openFile() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendOpenFile(path: "/home/user/project/lib/editor.ex")

        #expect(spy.guiActions == [.openFile(path: "/home/user/project/lib/editor.ex")])
    }

    @Test("key press recording captures codepoint and modifiers")
    func keyPress() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendKeyPress(codepoint: 27, modifiers: 0x02) // Escape + Ctrl

        #expect(spy.keyPressCalls.count == 1)
        #expect(spy.keyPressCalls[0].codepoint == 27)
        #expect(spy.keyPressCalls[0].modifiers == 0x02)
    }

    @Test("mouse event recording captures all fields")
    func mouseEvent() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendMouseEvent(row: 10, col: 20, button: MOUSE_BUTTON_LEFT,
                               modifiers: 0x01, eventType: MOUSE_PRESS, clickCount: 2)

        #expect(spy.mouseEventCalls.count == 1)
        #expect(spy.mouseEventCalls[0].row == 10)
        #expect(spy.mouseEventCalls[0].col == 20)
        #expect(spy.mouseEventCalls[0].button == MOUSE_BUTTON_LEFT)
        #expect(spy.mouseEventCalls[0].clickCount == 2)
    }

    @Test("multiple action types accumulate independently")
    func mixedActions() {
        let spy = SpyEncoder()
        let encoder: InputEncoder = spy
        encoder.sendSelectTab(id: 1)
        encoder.sendPasteEvent(text: "hello")
        encoder.sendFileTreeClick(index: 0)

        #expect(spy.guiActions.count == 2)
        #expect(spy.pasteCalls.count == 1)
    }
}
