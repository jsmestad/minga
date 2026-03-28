/// Native SwiftUI signature help overlay for LSP signature help.
///
/// Shows the active function signature with the current parameter
/// highlighted. Supports cycling through overloaded signatures.
/// Positioned above the cursor, non-interactive (keyboard-driven).

import SwiftUI

/// PreferenceKey to measure the signature help popup height.
/// Single reporter: only one GeometryReader writes to this key.
private struct SigHelpHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// PreferenceKey to measure the signature help popup width.
/// Single reporter: only one GeometryReader writes to this key.
private struct SigHelpWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SignatureHelpOverlay: View {
    let state: SignatureHelpState
    let theme: ThemeColors
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let viewportHeight: CGFloat
    let viewportWidth: CGFloat

    @State private var popupHeight: CGFloat = 0
    @State private var popupWidth: CGFloat = 0

    private let maxWidth: CGFloat = 600
    private let gap: CGFloat = 4

    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
    }

    /// Whether to show above (preferred) or below the anchor.
    private var showAbove: Bool {
        let anchorY = CGFloat(state.anchorRow) * cellHeight
        return anchorY > popupHeight + gap + cellHeight
    }

    /// Clamped to stay within the viewport height.
    private var offsetY: CGFloat {
        let anchorY = CGFloat(state.anchorRow) * cellHeight
        if showAbove {
            return max(anchorY - popupHeight - gap, 0)
        } else {
            let y = anchorY + cellHeight + gap
            let maxY = max(viewportHeight - popupHeight - 8, 0)
            return min(y, maxY)
        }
    }

    private var offsetX: CGFloat {
        let rawX = CGFloat(state.anchorCol) * cellWidth
        let maxX = max(viewportWidth - popupWidth - 8, 0)
        return min(rawX, maxX)
    }

    var body: some View {
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
                GeometryReader { geo in
                    Color.clear
                        .preference(key: SigHelpHeightKey.self, value: geo.size.height)
                        .preference(key: SigHelpWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(SigHelpHeightKey.self) { popupHeight = $0 }
            .onPreferenceChange(SigHelpWidthKey.self) { popupWidth = $0 }
            .background(
                VibrancyBackground(material: .popover)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            )
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.popupBg.opacity(0.5))
                    .shadow(color: .black.opacity(0.4), radius: 12,
                            y: showAbove ? -4 : 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.popupBorder.opacity(0.5), lineWidth: 1)
            )
            .offset(x: offsetX, y: offsetY)
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeIn(duration: animDuration)))
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
