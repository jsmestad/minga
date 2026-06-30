import AppKit
import SwiftUI
import MingaProtocol

/// Appearance settings: theme and font controls.
public struct AppearanceSettingsView: View {
    public init(state: SettingsState, encoder: InputEncoder? = nil) {
        self.state = state
        self.encoder = encoder
    }
    @Bindable var state: SettingsState
    let encoder: InputEncoder?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    public var body: some View {
        Form {
            Section("Theme") {
                if state.isLoading && state.themePreviews.isEmpty {
                    ProgressView("Loading themes…")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(state.themePreviews) { preview in
                            Button {
                                state.update(key: "theme", value: .atom(preview.atom))
                            } label: {
                                ThemeSwatch(preview: preview, selected: preview.atom == state.currentThemeName)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Font") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.fontFamily)
                            .font(.system(size: 13, weight: .medium))
                        Text("\(Int(state.fontSize)) pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose Font…") {
                        state.openFontPanel(using: encoder)
                    }
                }

                Stepper(value: Binding(
                    get: { Int(state.fontSize) },
                    set: { newValue in
                        state.update(key: "font_size", value: .int(newValue))
                    }
                ), in: 8...40) {
                    Text("Font Size: \(Int(state.fontSize))")
                }

                Toggle("Font Ligatures", isOn: Binding(
                    get: { state.fontLigatures },
                    set: { enabled in
                        state.update(key: "font_ligatures", value: .bool(enabled))
                    }
                ))
            }
        }
        .padding(20)
    }
}

private struct ThemeSwatch: View {
    let preview: Wire.ThemePreview
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                swatchColor(preview.editorBg)
                swatchColor(preview.editorFg)
                swatchColor(preview.accent)
            }
            .frame(height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(preview.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(10)
        .background(.quaternary.opacity(selected ? 0.7 : 0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func swatchColor(_ rgb: UInt32) -> some View {
        Rectangle()
            .fill(Color(
                red: Double((rgb >> 16) & 0xFF) / 255.0,
                green: Double((rgb >> 8) & 0xFF) / 255.0,
                blue: Double(rgb & 0xFF) / 255.0
            ))
    }
}

#Preview("Appearance Settings") {
    let state = SettingsState()
    state.isLoading = false
    state.currentThemeName = "doom_one"
    state.fontFamily = "Menlo"
    state.fontSize = 13
    state.fontWeight = "regular"
    state.fontLigatures = true
    state.themePreviews = [
        Wire.ThemePreview(name: "Doom One", atom: "doom_one", editorBg: 0x282C34, editorFg: 0xBBC2CF, accent: 0x51AFEF),
        Wire.ThemePreview(name: "Tokyo Night", atom: "tokyo_night", editorBg: 0x1A1B26, editorFg: 0xC0CAF5, accent: 0x7AA2F7),
        Wire.ThemePreview(name: "Catppuccin Mocha", atom: "catppuccin_mocha", editorBg: 0x1E1E2E, editorFg: 0xCDD6F4, accent: 0x89B4FA),
        Wire.ThemePreview(name: "Solarized Dark", atom: "solarized_dark", editorBg: 0x002B36, editorFg: 0x839496, accent: 0x268BD2),
        Wire.ThemePreview(name: "Gruvbox Dark", atom: "gruvbox_dark", editorBg: 0x282828, editorFg: 0xEBDBB2, accent: 0xFE8019),
        Wire.ThemePreview(name: "Nord", atom: "nord", editorBg: 0x2E3440, editorFg: 0xD8DEE9, accent: 0x88C0D0),
    ]
    return AppearanceSettingsView(state: state, encoder: nil)
        .frame(width: 520, height: 360)
}
