/// Subtle non-blocking hint shown while a frame-transaction resync is pending
/// (#2219 child D).
///
/// When `CommandDispatcher` invalidates an in-flight frame it holds the last
/// good frame on screen and requests a keyframe from the BEAM. This badge sits
/// unobtrusively in the bottom-trailing corner so the user knows a brief
/// recovery is underway. Unlike `ProtocolErrorOverlay`, it does not block input:
/// resync is self-healing and clears on the next clean commit.

import SwiftUI

struct ResyncOverlay: View {
    var state: ResyncState
    var theme: ThemeColors

    var body: some View {
        if state.pending {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Resyncing…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.tabActiveFg)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.popupBg.opacity(0.92))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.popupBorder, lineWidth: 1))
                    .padding(12)
                }
            }
            .accessibilityIdentifier("resync-pending-indicator")
            // Hint only; never intercept input. The editor stays usable while the
            // keyframe is in flight.
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
