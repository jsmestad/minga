/// On-screen keystroke-to-present latency HUD (ticket #2215).
///
/// An unobtrusive top-right badge showing live p50/p99/max keystroke-to-present
/// latency and the resolved sample count, mirroring the Go TUI's HUD. It reads
/// only from `LatencyHUDState`, which pulls a recorder snapshot on a coarse timer
/// outside the measured critical sections, so the overlay never perturbs the
/// numbers it reports. This is a frontend-local, ephemeral debug surface.

import SwiftUI

struct LatencyHUDOverlay: View {
    @Bindable var state: LatencyHUDState
    @Environment(\.themeColors) private var theme

    var body: some View {
        if state.visible {
            let model = state.model
            VStack {
                HStack {
                    Spacer()
                    badge(model)
                        .padding(.top, 6)
                        .padding(.trailing, 10)
                }
                Spacer()
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier("latency-hud")
        }
    }

    private func badge(_ model: LatencyHUDModel) -> some View {
        Text(model.line)
            // Monospaced digits keep the badge from jittering as values change.
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(theme.treeActiveFg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.treeBg.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.treeSeparatorFg.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}
