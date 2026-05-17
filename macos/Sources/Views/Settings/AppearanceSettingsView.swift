import AppKit
import SwiftUI

/// Appearance settings: theme and font controls.
struct AppearanceSettingsView: View {
    @Bindable var state: SettingsState
    let encoder: InputEncoder?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        Form {
            Section("Theme") {
                if state.isLoading && state.themePreviews.isEmpty {
                    ProgressView("Loading themes…")
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(state.themePreviews) { preview in
                            ThemeSwatch(preview: preview, selected: preview.atom == state.currentThemeName)
                                .onTapGesture {
                                    state.update(key: "theme", value: .atom(preview.atom))
                                }
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
