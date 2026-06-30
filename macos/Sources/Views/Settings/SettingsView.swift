import AppKit
import SwiftUI

/// Native macOS Settings window for common editor preferences.
public struct SettingsView: View {
    public let state: SettingsState
    public let encoder: InputEncoder?

    public init(state: SettingsState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }

    public var body: some View {
        TabView {
            AppearanceSettingsView(state: state, encoder: encoder)
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            EditorSettingsView(state: state)
                .tabItem {
                    Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }

            KeybindingsSettingsView(state: state, encoder: encoder)
                .tabItem {
                    Label("Keybindings", systemImage: "keyboard")
                }
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: 520, minHeight: 360)
        .background(WindowIdentifierSetter(identifier: "MingaSettingsWindow"))
        .onAppear {
            state.query(using: encoder)
        }
    }
}

/// Marks the Settings window so editor theme appearance updates do not affect it.
private struct WindowIdentifierSetter: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
    }
}
