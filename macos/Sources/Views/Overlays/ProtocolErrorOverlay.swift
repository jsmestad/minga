/// Blocking full-window overlay shown on a protocol_error (0x18).
///
/// The BEAM rejected this frontend's handshake protocol_version, so it will
/// never reach ready and the editor surface stays empty. This overlay covers
/// the whole window with the editor background and a centered error card so the
/// user sees an explicit reason instead of a blank screen (ticket #2237).

import SwiftUI

public struct ProtocolErrorOverlay: View {
    public init(state: ProtocolErrorState) {
        self.state = state
    }
    public var state: ProtocolErrorState
    @Environment(\.themeColors) private var theme


    public var body: some View {
        if let message = state.message {
            ZStack {
                theme.editorBg
                    .ignoresSafeArea()

                VStack(spacing: Spacing.lg) {
                    Text("Protocol error")
                        .font(Typography.font(.toolbar, weight: .semibold))
                        .foregroundStyle(theme.gutterErrorFg)

                    Text(message)
                        .font(Typography.font(.emphasis))
                        .foregroundStyle(theme.tabActiveFg)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Spacing.panel)
                .background(theme.popupBg)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .stroke(theme.popupBorder, lineWidth: 1)
                )
            }
            .accessibilityIdentifier("protocol-error-overlay")
            // Block interaction with everything underneath; this is a fatal,
            // unrecoverable session state.
            .contentShape(Rectangle())
            .transition(.opacity)
        }
    }
}
