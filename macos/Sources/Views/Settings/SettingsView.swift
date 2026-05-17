import AppKit
import SwiftUI

/// Native macOS Settings window for common editor preferences.
struct SettingsView: View {
    let appState: AppState

    var body: some View {
        TabView {
            AppearanceSettingsView(state: appState.gui.settingsState, encoder: appState.encoder)
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            EditorSettingsView(state: appState.gui.settingsState)
                .tabItem {
                    Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }

            KeybindingsSettingsView(state: appState.gui.settingsState, encoder: appState.encoder)
                .tabItem {
                    Label("Keybindings", systemImage: "keyboard")
                }
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: 520, minHeight: 360)
        .background(WindowIdentifierSetter(identifier: "MingaSettingsWindow"))
        .onAppear {
            appState.gui.settingsState.query(using: appState.encoder)
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
