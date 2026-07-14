/// Native SwiftUI signature help overlay for LSP signature help.
///
/// Shows the active function signature with the current parameter
/// highlighted. Supports cycling through overloaded signatures. `EditorOverlayHost`
/// owns anchor placement, viewport clipping, and z-order.

import SwiftUI
import MingaProtocol

public struct SignatureHelpOverlay: View {
    public init(state: SignatureHelpState) {
        self.state = state
    }
    public let state: SignatureHelpState
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    @Environment(\.anchoredOverlayContext) private var overlayContext

    private let maxWidth: CGFloat = 600

    public var body: some View {
        let _ = frameVersion
        if state.visible && !state.signatures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                signatureLabel

                if let paramDoc = activeParameterDoc, !paramDoc.isEmpty {
                    Divider()
                        .background(theme.popupBorder.opacity(0.3))

                    Text(paramDoc)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.popupFg.opacity(0.75))
                        .lineLimit(4)
                }

                if state.signatures.count > 1 {
                    Text("\(state.activeSignature + 1)/\(state.signatures.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.popupFg.opacity(0.4))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: maxWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.popupBg)
                    .shadow(color: .black.opacity(0.4), radius: 12, y: overlayContext.shadowYOffset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .allowsHitTesting(false)
        }
    }

    /// The active signature, or nil if the index is out of bounds.
    private var activeSignatureInfo: SignatureInfo? {
        guard state.activeSignature < state.signatures.count else { return nil }
        return state.signatures[state.activeSignature]
    }

    /// Documentation for the active parameter, if available.
    private var activeParameterDoc: String? {
        guard let sig = activeSignatureInfo,
              state.activeParameter < sig.parameters.count else { return nil }
        let doc = sig.parameters[state.activeParameter].documentation
        return doc.isEmpty ? nil : doc
    }

    @ViewBuilder
    private var signatureLabel: some View {
        if let sig = activeSignatureInfo {
            highlightedSignature(sig)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    /// Renders the signature label with the active parameter highlighted.
    @ViewBuilder
    private func highlightedSignature(_ sig: SignatureInfo) -> some View {
        let label = sig.label
        let activeParam = state.activeParameter < sig.parameters.count
            ? sig.parameters[state.activeParameter]
            : nil

        if let param = activeParam, let range = label.range(of: param.label) {
            let before = String(label[label.startIndex..<range.lowerBound])
            let active = String(label[range])
            let after = String(label[range.upperBound..<label.endIndex])

            (Text(before).foregroundStyle(theme.popupFg.opacity(0.8))
             + Text(active).foregroundStyle(theme.accent).bold()
             + Text(after).foregroundStyle(theme.popupFg.opacity(0.8)))
        } else {
            Text(label)
                .foregroundStyle(theme.popupFg.opacity(0.8))
        }
    }
}

// MARK: - Previews

@MainActor
private func signatureHelpPreviewState() -> SignatureHelpState {
    let state = SignatureHelpState()
    state.update(
        visible: true, anchorRow: 8, anchorCol: 6,
        activeSignature: 0, activeParameter: 1,
        rawSignatures: [
            Wire.Signature(
                label: "GenServer.start_link(module, init_arg, options)",
                documentation: "Starts a GenServer process linked to the current process.",
                parameters: [
                    Wire.SignatureParameter(label: "module", documentation: "The module implementing the GenServer callbacks."),
                    Wire.SignatureParameter(label: "init_arg", documentation: "The argument passed to init/1."),
                    Wire.SignatureParameter(label: "options", documentation: "Options such as :name, :timeout, and :hibernate_after."),
                ]
            ),
        ]
    )
    return state
}

#Preview("Signature Help") {
    let theme = PreviewFixtures.theme()
    SignatureHelpOverlay(state: signatureHelpPreviewState())
        .frame(width: 500, height: 200)
        .background(theme.editorBg)
        .environment(\.themeColors, theme)
}
