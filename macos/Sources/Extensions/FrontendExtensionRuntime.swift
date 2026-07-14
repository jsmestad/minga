import SwiftUI
import MingaProtocol

public struct FrontendExtensionViewContext {
    public let theme: ThemeColors
    public let encoder: InputEncoder?
    public let namespace: Namespace.ID

    public init(theme: ThemeColors, encoder: InputEncoder? = nil, namespace: Namespace.ID) {
        self.theme = theme
        self.encoder = encoder
        self.namespace = namespace
    }
}

@MainActor
@Observable
public final class FrontendExtensionRuntimeRegistry {
    public typealias Decoder = (FrontendExtensionRuntimeMessage) -> Void
    public typealias ViewBuilder = (FrontendExtensionViewContext) -> AnyView

    @ObservationIgnored private var decoders: [String: Decoder] = [:]
    @ObservationIgnored private var viewBuilders: [String: ViewBuilder] = [:]
    public private(set) var activeExtensionIDs: [String] = []

    public init() {}

    public func register(extensionID: String, decoder: @escaping Decoder, view: @escaping ViewBuilder) {
        decoders[extensionID] = decoder
        viewBuilders[extensionID] = view
        if !activeExtensionIDs.contains(extensionID) {
            activeExtensionIDs.append(extensionID)
        }
    }

    public func dispatch(_ message: FrontendExtensionRuntimeMessage) {
        decoders[message.extensionID]?(message)
    }

    public func view(for extensionID: String, context: FrontendExtensionViewContext) -> AnyView? {
        viewBuilders[extensionID]?(context)
    }
}
