/// A decoded message destined for a frontend-owned extension runtime.
///
/// Pure protocol value type: produced by the app-target decoder (as the
/// `guiExtensionRuntime` render command) and consumed by `MingaUI`'s
/// `FrontendExtensionRuntimeRegistry`, so it lives in `MingaProtocol` where
/// both layers can see it.

import Foundation

public struct FrontendExtensionRuntimeMessage: Sendable, Equatable {
    public let extensionID: String
    public let channel: String
    public let payload: Data

    public init(extensionID: String, channel: String, payload: Data) {
        self.extensionID = extensionID
        self.channel = channel
        self.payload = payload
    }
}
