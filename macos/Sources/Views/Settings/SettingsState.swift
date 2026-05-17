import AppKit
import Observation
import SwiftUI

/// Line number styles exposed by the native settings panel.
enum SettingsLineNumberStyle: String, CaseIterable, Identifiable, Sendable {
    case none
    case absolute
    case relative
    case hybrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Off"
        case .absolute: return "Absolute"
        case .relative: return "Relative"
        case .hybrid: return "Hybrid"
        }
    }
}

/// Observable state for the native Settings scene.
@MainActor
@Observable
final class SettingsState {
    var isLoading: Bool = true
    var currentThemeName: String = "doom_one"
    var fontFamily: String = "Menlo"
    var fontSize: CGFloat = 13
    var fontWeight: String = "regular"
    var fontLigatures: Bool = true
    var tabWidth: Int = 2
    var lineNumbers: SettingsLineNumberStyle = .absolute
    var wordWrap: Bool = false
    var cursorBlink: Bool = true
    var cursorline: Bool = true
    var themePreviews: [Wire.ThemePreview] = []
    var keybindings: [Wire.KeybindingEntry] = []

    var encoder: InputEncoder?
    var onCursorBlinkChanged: ((Bool) -> Void)?

    private var fontPanelCoordinator: FontPanelCoordinator?

    /// Applies a full or incremental settings state push from the BEAM.
    func apply(configState: Wire.ConfigState) {
        isLoading = false

        for (key, value) in configState.options {
            applyOption(key: key, value: value)
        }

        if !configState.themePreviews.isEmpty {
            themePreviews = configState.themePreviews
        }

        if !configState.keybindings.isEmpty {
            keybindings = configState.keybindings
        }
    }

    /// Sends a settings query to the BEAM.
    func query(using encoder: InputEncoder?) {
        self.encoder = encoder
        isLoading = true
        encoder?.sendConfigQuery()
    }

    /// Sends a typed setting update to the BEAM.
    func update(key: String, value: SettingValue) {
        encoder?.sendConfigUpdate(key: key, value: value)
    }

    /// Opens the macOS system font panel and routes selections back through config updates.
    func openFontPanel(using encoder: InputEncoder?) {
        self.encoder = encoder
        let coordinator = fontPanelCoordinator ?? FontPanelCoordinator(settingsState: self)
        fontPanelCoordinator = coordinator
        NSFontManager.shared.target = coordinator
        NSFontManager.shared.action = #selector(FontPanelCoordinator.changeFont(_:))
        NSFontManager.shared.setSelectedFont(NSFont(name: fontFamily, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular), isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    private func applyOption(key: String, value: SettingValue) {
        switch (key, value) {
        case ("theme", .atom(let atom)):
            currentThemeName = atom
        case ("font_family", .string(let family)):
            fontFamily = family
        case ("font_size", .int(let size)):
            fontSize = CGFloat(size)
        case ("font_weight", .atom(let weight)):
            fontWeight = weight
        case ("font_ligatures", .bool(let enabled)):
            fontLigatures = enabled
        case ("tab_width", .int(let width)):
            tabWidth = width
        case ("line_numbers", .atom(let style)):
            lineNumbers = SettingsLineNumberStyle(rawValue: style) ?? .absolute
        case ("wrap", .bool(let enabled)):
            wordWrap = enabled
        case ("cursor_blink", .bool(let enabled)):
            let changed = cursorBlink != enabled
            cursorBlink = enabled
            if changed { onCursorBlinkChanged?(enabled) }
        case ("cursorline", .bool(let enabled)):
            cursorline = enabled
        default:
            break
        }
    }
}

/// AppKit bridge for NSFontPanel changes.
@MainActor
final class FontPanelCoordinator: NSObject {
    private weak var settingsState: SettingsState?

    init(settingsState: SettingsState) {
        self.settingsState = settingsState
    }

    @objc func changeFont(_ sender: NSFontManager) {
        guard let settingsState else { return }
        let current = NSFont(name: settingsState.fontFamily, size: settingsState.fontSize) ?? .monospacedSystemFont(ofSize: settingsState.fontSize, weight: .regular)
        let converted = sender.convert(current)
        let family = converted.familyName ?? converted.fontName
        settingsState.update(key: "font_family", value: .string(family))
        settingsState.update(key: "font_size", value: .int(Int(round(converted.pointSize))))
    }

    @objc var validModesForFontPanel: NSFontPanel.ModeMask {
        [.face, .size]
    }
}
