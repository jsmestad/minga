/// NSViewRepresentable wrapper for NSTextField used as an inline editor
/// in the file tree. Provides programmatic focus, Escape handling,
/// and Finder-style stem-only selection for rename operations.
///
/// Uses NSTextField instead of SwiftUI TextField because:
/// - `becomeFirstResponder()` works reliably for programmatic focus
/// - `cancelOperation(_:)` intercepts Escape without system beep
/// - `textDidEndEditing` detects focus loss for click-outside-to-commit

import SwiftUI

struct InlineEditFieldStyle {
    let textColor: Color
    let selectionBackgroundColor: Color
    let selectionForegroundColor: Color
    let insertionPointColor: Color

    @MainActor var nsTextColor: NSColor {
        Self.nsColor(textColor)
    }

    @MainActor func apply(to textView: NSTextView) {
        textView.textColor = nsTextColor
        textView.insertionPointColor = Self.nsColor(insertionPointColor)
        textView.selectedTextAttributes = [
            .backgroundColor: Self.nsColor(selectionBackgroundColor),
            .foregroundColor: Self.nsColor(selectionForegroundColor)
        ]
    }

    @MainActor private static func nsColor(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }
}

struct InlineEditField: NSViewRepresentable {
    let initialText: String
    /// When true, selects only the stem (before the last dot) on first focus.
    let selectStem: Bool
    let style: InlineEditFieldStyle
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.stringValue = initialText
        field.delegate = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        Self.applyStyle(style, to: field)

        // Schedule focus for next run loop to ensure the view is in the hierarchy
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            Self.applyStyle(self.style, to: field)

            if self.selectStem {
                let nsName = field.stringValue as NSString
                let ext = nsName.pathExtension
                let stemLength = ext.isEmpty ? nsName.length : nsName.length - (ext as NSString).length - 1
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: stemLength)
            } else {
                // Select all for new file/folder
                field.currentEditor()?.selectAll(nil)
            }
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.style = style
        Self.applyStyle(style, to: nsView)
        // Don't update stringValue on subsequent SwiftUI updates;
        // the user is actively typing and we'd reset their input.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(style: style, onCommit: onCommit, onCancel: onCancel)
    }

    @MainActor private static func applyStyle(_ style: InlineEditFieldStyle, to field: NSTextField) {
        field.textColor = style.nsTextColor

        guard let editor = field.currentEditor() as? NSTextView else { return }
        style.apply(to: editor)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var style: InlineEditFieldStyle
        let onCommit: (String) -> Void
        let onCancel: () -> Void
        private var committed = false

        init(style: InlineEditFieldStyle, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.style = style
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView
            else { return }

            field.textColor = style.nsTextColor
            style.apply(to: editor)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !committed else { return }
            committed = true

            guard let field = obj.object as? NSTextField else { return }

            // Check if the user pressed Escape (movement == NSTextMovement.cancel)
            if let movement = obj.userInfo?["NSTextMovement"] as? Int,
               movement == NSTextMovement.cancel.rawValue
            {
                onCancel()
            } else {
                // Enter or click-outside: commit
                onCommit(field.stringValue)
            }
        }

        func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                committed = true
                onCancel()
                return true  // Prevent system beep
            }
            return false
        }
    }
}
