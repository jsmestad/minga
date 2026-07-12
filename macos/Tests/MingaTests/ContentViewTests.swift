import MingaProtocol
@testable import MingaUI
import SwiftUI
import Testing

@Suite("Content view")
@MainActor
struct ContentViewTests {
    @Test("resolves the current encoder instead of retaining the startup value")
    func currentEncoder() {
        let first = NullInputEncoder()
        let second = NullInputEncoder()
        var current: InputEncoder? = first

        let view = ContentView(
            gui: GUIState(),
            encoder: { current },
            editorGeometry: { .preview },
            chrome: .preview,
            onAgentChatVisibleChange: { _ in }
        ) {
            Color.clear
        }

        #expect(view.encoder === first)
        current = second
        #expect(view.encoder === second)
    }
}
