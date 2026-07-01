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

@MainActor
@Observable
public final class SignatureHelpState {
    public init(visible: Bool = false, anchorRow: Int = 0, anchorCol: Int = 0, activeSignature: Int = 0, activeParameter: Int = 0, signatures: [SignatureInfo] = []) {
        self.visible = visible
        self.anchorRow = anchorRow
        self.anchorCol = anchorCol
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
        self.signatures = signatures
    }
    public var visible: Bool = false
    public var anchorRow: Int = 0
    public var anchorCol: Int = 0
    public var activeSignature: Int = 0
    public var activeParameter: Int = 0
    public var signatures: [SignatureInfo] = []

    public func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                activeSignature: UInt8, activeParameter: UInt8,
                rawSignatures: [Wire.Signature]) {
        self.visible = visible
        self.anchorRow = Int(anchorRow)
        self.anchorCol = Int(anchorCol)
        self.activeSignature = Int(activeSignature)
        self.activeParameter = Int(activeParameter)
        var paramId = 0
        self.signatures = rawSignatures.enumerated().map { i, sig in
            let params = sig.parameters.map { p in
                let param = SignatureParameter(id: paramId, label: p.label, documentation: p.documentation)
                paramId += 1
                return param
            }
            return SignatureInfo(id: i, label: sig.label, documentation: sig.documentation, parameters: params)
        }
    }

    public func hide() {
        visible = false
        signatures = []
    }
}
