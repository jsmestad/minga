import AppKit
import MingaProtocol
import SwiftUI

/// Native macOS Settings window for common editor preferences.
public struct SettingsView: View {
    public enum Action: Equatable, Sendable {
        case executeCommand(name: String)
        case query
        case update(key: String, value: SettingValue)
    }

    public let state: SettingsState
    public let sendAction: ViewActionHandler<Action>?

    public init(state: SettingsState, sendAction: ViewActionHandler<Action>?) {
        self.state = state
        self.sendAction = sendAction
    }

    public var body: some View {
        TabView {
            AppearanceSettingsView(state: state, onOpenFontPanel: state.openFontPanel)
                .tabItem {
                    Label("Appearance", systemImage: "paintpalette")
                }

            EditorSettingsView(state: state)
                .tabItem {
                    Label("Editor", systemImage: "chevron.left.forwardslash.chevron.right")
                }

            KeybindingsSettingsView(state: state, sendAction: keybindingsAction)
                .tabItem {
                    Label("Keybindings", systemImage: "keyboard")
                }
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: 520, minHeight: 360)
        .background(WindowIdentifierSetter(identifier: "MingaSettingsWindow"))
        .onAppear {
            state.query(using: settingsStateAction)
        }
    }

    private var settingsStateAction: ViewActionHandler<SettingsState.Action>? {
        guard let sendAction else { return nil }
        return { action in
            switch action {
            case .query: sendAction(.query)
            case .update(let key, let value): sendAction(.update(key: key, value: value))
            }
        }
    }

    private var keybindingsAction: ViewActionHandler<KeybindingsSettingsView.Action>? {
        guard let sendAction else { return nil }
        return { _ in sendAction(.executeCommand(name: "open_config")) }
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
