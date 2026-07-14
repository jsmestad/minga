/// Subtle non-blocking hint shown while a frame-transaction resync is pending
/// (#2219 child D).
///
/// When `CommandDispatcher` invalidates an in-flight frame it holds the last
/// good frame on screen and requests a keyframe from the BEAM. This badge sits
/// unobtrusively in the bottom-trailing corner so the user knows a brief
/// recovery is underway. Unlike `ProtocolErrorOverlay`, it does not block input:
/// resync is self-healing and clears on the next clean commit.

import SwiftUI

public struct ResyncOverlay: View {
    public init(state: ResyncState, onRetry: ((UInt32, UInt32) -> Void)? = nil) {
        self.state = state
        self.onRetry = onRetry
    }
    public var state: ResyncState
    public var onRetry: ((UInt32, UInt32) -> Void)?
    @Environment(\.themeColors) private var theme

    @State private var retryVisible = false

    public var body: some View {
        if state.pending {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    badge
                }
            }
            .accessibilityIdentifier("resync-pending-indicator")
            .allowsHitTesting(retryVisible && onRetry != nil)
            .transition(.opacity)
            .task(id: state.pending) {
                retryVisible = false
                guard state.pending else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled && state.pending {
                    retryVisible = true
                }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if retryVisible, let onRetry {
            Button {
                onRetry(state.lastGoodFrameSeq, state.generation)
            } label: {
                badgeContent(showRetryIcon: true)
            }
            .buttonStyle(.plain)
            .help("Retry resync")
            .accessibilityIdentifier("resync-retry-button")
        } else {
            badgeContent(showRetryIcon: false)
        }
    }

    private func badgeContent(showRetryIcon: Bool) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(state.rejection.map { "Resyncing generation \(state.generation): \($0)" } ?? "Resyncing generation \(state.generation)…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.tabActiveFg)
            if showRetryIcon {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.tabActiveFg)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.popupBg.opacity(0.92))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.popupBorder, lineWidth: 1))
        .padding(12)
    }
}
