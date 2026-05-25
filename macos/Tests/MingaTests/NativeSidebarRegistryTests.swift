/// Tests for static native sidebar registry selection and fallback behavior.

import Testing
import SwiftUI

@Suite("Native sidebar registry")
@MainActor
struct NativeSidebarRegistryTests {
    @Test("known sidebar kinds resolve to native adapters")
    func knownAdaptersResolve() {
        #expect(NativeSidebarRegistry.adapter(for: "file_tree") != nil)
        #expect(NativeSidebarRegistry.adapter(for: "git_status") != nil)
        #expect(NativeSidebarRegistry.adapter(for: "observatory") != nil)
    }

    @Test("unknown sidebar kinds use generic fallback")
    func unknownAdapterFallsBack() {
        let adapter = NativeSidebarRegistry.adapterOrFallback(for: "custom_sidebar")
        #expect(adapter.kind == "generic_fallback")
    }

    @Test("sidebar host selects highest-priority visible sidebar")
    func activeSidebarSelection() {
        let state = SidebarHostState()
        state.update(activeId: "", sidebars: [
            Wire.SidebarMetadata(id: "file_tree", displayName: "File Tree", semanticKind: "file_tree", icon: "folder", order: 10, visible: true, focused: false, preferredWidth: 30, badgeCount: nil),
            Wire.SidebarMetadata(id: "observatory", displayName: "BEAM Observatory", semanticKind: "observatory", icon: "network", order: 30, visible: true, focused: true, preferredWidth: 30, badgeCount: nil)
        ])

        #expect(state.activeSidebar?.id == "observatory")
    }

    @Test("adapter action encodes sidebar id and kind")
    func adapterActionEncodesSemanticIntent() {
        let spy = SpyEncoder()
        let item = SidebarItem(Wire.SidebarMetadata(id: "git_status", displayName: "Git Status", semanticKind: "git_status", icon: "", order: 20, visible: true, focused: true, preferredWidth: 30, badgeCount: 2))

        NativeSidebarRegistry.adapterOrFallback(for: item.semanticKind).sendPrimaryAction(spy, item, false)

        #expect(spy.guiActions == [.sidebarAction(sidebarId: "git_status", kind: "git_status", action: "activate")])
    }

    @Test("active adapter action toggles the selected sidebar")
    func activeAdapterActionTogglesSemanticIntent() {
        let spy = SpyEncoder()
        let item = SidebarItem(Wire.SidebarMetadata(id: "git_status", displayName: "Git Status", semanticKind: "git_status", icon: "", order: 20, visible: true, focused: true, preferredWidth: 30, badgeCount: 2))

        NativeSidebarRegistry.adapterOrFallback(for: item.semanticKind).sendPrimaryAction(spy, item, true)

        #expect(spy.guiActions == [.sidebarAction(sidebarId: "git_status", kind: "git_status", action: "toggle")])
    }
}
