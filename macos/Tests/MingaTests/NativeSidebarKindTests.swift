/// Tests for semantic native sidebar selection and fallback behavior.

import Testing
@testable import MingaUI
import MingaProtocol

@Suite("Native sidebar kinds")
@MainActor
struct NativeSidebarKindTests {
    @Test("known semantic kinds resolve to compiler-checked cases")
    func knownKindsResolve() {
        #expect(NativeSidebarKind("file_tree") == .fileTree)
        #expect(NativeSidebarKind("git_status") == .gitStatus)
        #expect(NativeSidebarKind("observatory") == .observatory)
    }

    @Test("unknown and empty semantic kinds preserve fallback identity")
    func unknownKindsPreserveIdentity() {
        #expect(NativeSidebarKind("custom_sidebar") == .unsupported("custom_sidebar"))
        #expect(NativeSidebarKind("") == .unsupported(""))
        #expect(NativeSidebarKind("custom_sidebar").wireValue == "custom_sidebar")
        #expect(!NativeSidebarKind("").isSupported)
    }

    @Test("compiled-in kinds provide icon and badge choices")
    func compiledInPresentationChoices() {
        #expect(NativeSidebarKind.fileTree.fallbackIcon == "folder")
        #expect(NativeSidebarKind.gitStatus.fallbackIcon == "point.3.filled.connected.trianglepath.dotted")
        #expect(NativeSidebarKind.observatory.fallbackIcon == "network")
        #expect(NativeSidebarKind.unsupported("custom").fallbackIcon == "questionmark.square.dashed")
        #expect(NativeSidebarKind.gitStatus.badgeText(metadataCount: 7, gitStatusCount: 12) == "7")
        #expect(NativeSidebarKind.gitStatus.badgeText(metadataCount: nil, gitStatusCount: 100) == "99+")
        #expect(NativeSidebarKind.fileTree.badgeText(metadataCount: 7, gitStatusCount: 12) == nil)
    }

    @Test("sidebar host selects highest-priority visible sidebar")
    func activeSidebarSelection() {
        let state = SidebarHostState()
        state.update(activeId: "", sidebars: [
            metadata(id: "file_tree", kind: "file_tree", order: 10, focused: false),
            metadata(id: "observatory", kind: "observatory", order: 30, focused: true),
        ])

        #expect(state.activeSidebar?.id == "observatory")
    }

    @Test("unknown semantic kinds warn once per kind for the host lifetime")
    func unknownKindsWarnOnce() {
        var warnings: [String] = []
        let state = SidebarHostState { warnings.append($0) }

        state.update(activeId: "custom-a", sidebars: [metadata(id: "custom-a", kind: "custom_sidebar")])
        state.update(activeId: "custom-b", sidebars: [metadata(id: "custom-b", kind: "custom_sidebar")])
        state.update(activeId: "other", sidebars: [metadata(id: "other", kind: "other_sidebar")])

        #expect(warnings == [
            "Unknown sidebar kind 'custom_sidebar' for sidebar 'custom-a'; using generic fallback",
            "Unknown sidebar kind 'other_sidebar' for sidebar 'other'; using generic fallback",
        ])
    }

    private func metadata(
        id: String,
        kind: String,
        order: UInt16 = 10,
        focused: Bool = true
    ) -> Wire.SidebarMetadata {
        Wire.SidebarMetadata(
            id: id,
            displayName: id,
            semanticKind: kind,
            icon: "",
            order: order,
            visible: true,
            focused: focused,
            preferredWidth: 30,
            badgeCount: nil
        )
    }
}
