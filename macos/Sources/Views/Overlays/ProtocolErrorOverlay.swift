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

                VStack(spacing: 12) {
                    Text("Protocol error")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.gutterErrorFg)

                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.tabActiveFg)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .background(theme.popupBg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
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
