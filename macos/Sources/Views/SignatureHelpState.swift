/// Observable signature help state driven by BEAM gui_signature_help messages.

import SwiftUI

/// A parameter in a function signature.
struct SignatureParameter: Identifiable {
    let id: Int
    let label: String
    let documentation: String
}

/// A function signature with its parameters.
struct SignatureInfo: Identifiable {
    let id: Int
    let label: String
    let documentation: String
    let parameters: [SignatureParameter]
}

@MainActor
@Observable
final class SignatureHelpState {
    var visible: Bool = false
    var anchorRow: Int = 0
    var anchorCol: Int = 0
    var activeSignature: Int = 0
    var activeParameter: Int = 0
    var signatures: [SignatureInfo] = []

    func update(visible: Bool, anchorRow: UInt16, anchorCol: UInt16,
                activeSignature: UInt8, activeParameter: UInt8,
                rawSignatures: [GUISignature]) {
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

    func hide() {
        visible = false
        signatures = []
    }
}
