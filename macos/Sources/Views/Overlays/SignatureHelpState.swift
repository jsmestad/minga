/// Observable signature help state driven by BEAM gui_signature_help messages.

import SwiftUI
import MingaProtocol

/// A parameter in a function signature.
public struct SignatureParameter: Identifiable {
    public init(id: Int, label: String, documentation: String) {
        self.id = id
        self.label = label
        self.documentation = documentation
    }
    public let id: Int
    public let label: String
    public let documentation: String
}

/// A function signature with its parameters.
public struct SignatureInfo: Identifiable {
    public init(id: Int, label: String, documentation: String, parameters: [SignatureParameter]) {
        self.id = id
        self.label = label
        self.documentation = documentation
        self.parameters = parameters
    }
    public let id: Int
    public let label: String
    public let documentation: String
    public let parameters: [SignatureParameter]
}

/// Complete presentation value for one visible signature-help popup.
public struct SignatureHelpContent {
    fileprivate init(anchorRow: Int, anchorCol: Int, activeSignature: Int, activeParameter: Int, signatures: [SignatureInfo]) {
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
        self.signatures = signatures
    }

    public let anchorRow: Int
    public let anchorCol: Int
    public let activeSignature: Int
    public let activeParameter: Int
    public let signatures: [SignatureInfo]
}

@MainActor
@Observable
public final class SignatureHelpState {
    public init() {}

    /// The complete visible presentation, or `nil` when hidden.
    public private(set) var content: SignatureHelpContent?

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                activeSignature: UInt8, activeParameter: UInt8,
                rawSignatures: [Wire.Signature]) {
        guard visible else {
            hide()
            return
        }

        var paramId = 0
        let signatures = rawSignatures.enumerated().map { i, sig in
            let params = sig.parameters.map { p in
                let param = SignatureParameter(id: paramId, label: p.label, documentation: p.documentation)
                paramId += 1
                return param
            }
            return SignatureInfo(id: i, label: sig.label, documentation: sig.documentation, parameters: params)
        }
        content = SignatureHelpContent(
            anchorRow: Int(anchorRow), anchorCol: Int(anchorCol),
            activeSignature: Int(activeSignature), activeParameter: Int(activeParameter),
            signatures: signatures
        )
    }

    public func hide() {
        content = nil
    }
}
