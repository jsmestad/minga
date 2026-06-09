import SwiftUI

struct FrontendExtensionViewContext {
    let theme: ThemeColors
    let encoder: InputEncoder?
    let namespace: Namespace.ID
}

@MainActor
final class FrontendExtensionRuntimeRegistry {
    typealias Decoder = (FrontendExtensionRuntimeMessage) -> Void
    typealias ViewBuilder = (FrontendExtensionViewContext) -> AnyView

    private var decoders: [String: Decoder] = [:]
    private var viewBuilders: [String: ViewBuilder] = [:]
    private(set) var activeExtensionIDs: [String] = []

    func register(extensionID: String, decoder: @escaping Decoder, view: @escaping ViewBuilder) {
        decoders[extensionID] = decoder
        viewBuilders[extensionID] = view
        if !activeExtensionIDs.contains(extensionID) {
            activeExtensionIDs.append(extensionID)
        }
    }

    func dispatch(_ message: FrontendExtensionRuntimeMessage) {
        decoders[message.extensionID]?(message)
    }

    func view(for extensionID: String, context: FrontendExtensionViewContext) -> AnyView? {
        viewBuilders[extensionID]?(context)
    }
}
