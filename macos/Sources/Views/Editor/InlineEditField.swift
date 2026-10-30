/// NSViewRepresentable wrapper for NSTextField used as an inline editor
/// in the file tree. Provides programmatic focus, Escape handling,
/// and Finder-style stem-only selection for rename operations.
///
/// Uses NSTextField instead of SwiftUI TextField because:
/// - `becomeFirstResponder()` works reliably for programmatic focus
/// - `cancelOperation(_:)` intercepts Escape without system beep
/// - `textDidEndEditing` detects focus loss for click-outside-to-commit

import SwiftUI

public struct InlineEditFieldStyle {
    public init(textColor: Color, selectionBackgroundColor: Color, selectionForegroundColor: Color, insertionPointColor: Color) {
        self.textColor = textColor
        self.selectionBackgroundColor = selectionBackgroundColor
        self.selectionForegroundColor = selectionForegroundColor
        self.insertionPointColor = insertionPointColor
    }
    public let textColor: Color
    public let selectionBackgroundColor: Color
    public let selectionForegroundColor: Color
    public let insertionPointColor: Color

    @MainActor public var nsTextColor: NSColor {
        Self.nsColor(textColor)
    }

    @MainActor public func apply(to textView: NSTextView) {
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

public struct InlineEditField: NSViewRepresentable {
    @Environment(\.editorFocusPolicy) private var focusPolicy
    public init(initialText: String, selectStem: Bool, style: InlineEditFieldStyle, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialText = initialText
        self.selectStem = selectStem
        self.style = style
        self.onCommit = onCommit
        self.onCancel = onCancel
    }
    public let initialText: String
    /// When true, selects only the stem (before the last dot) on first focus.
    public let selectStem: Bool
    public let style: InlineEditFieldStyle
    public let onCommit: (String) -> Void
    public let onCancel: () -> Void

    public func makeNSView(context: Context) -> NSTextField {
        let field = InlineEditTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .none
        field.stringValue = initialText
        field.delegate = context.coordinator
        field.focusCoordinator = context.coordinator
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        Self.applyStyle(style, to: field)

        context.coordinator.selectStem = selectStem
        context.coordinator.reconcileFocusPolicy(focusPolicy, field: field)

        return field
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.style = style
        Self.applyStyle(style, to: nsView)
        context.coordinator.reconcileFocusPolicy(focusPolicy, field: nsView)
        // Don't update stringValue on subsequent SwiftUI updates;
        // the user is actively typing and we'd reset their input.
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(style: style, onCommit: onCommit, onCancel: onCancel)
    }

    public static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.retire()
        coordinator.focusPolicy?.unregister(field, as: .inlineEdit)
        field.window?.endEditing(for: field)
        coordinator.focusPolicy?.nativeTextEditingDidEnd()
    }

    @MainActor private static func applyStyle(_ style: InlineEditFieldStyle, to field: NSTextField) {
        field.textColor = style.nsTextColor

        guard let editor = field.currentEditor() as? NSTextView else { return }
        style.apply(to: editor)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextFieldDelegate {
        public var style: InlineEditFieldStyle
        public let onCommit: (String) -> Void
        public let onCancel: () -> Void
        private var committed = false
        weak var focusPolicy: (any EditorFocusControlling)?
        var selectStem = false
        private var selectedInitialText = false

        public init(style: InlineEditFieldStyle, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.style = style
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func reconcileFocusPolicy(_ policy: (any EditorFocusControlling)?, field: NSTextField) {
            guard focusPolicy !== policy else { return }
            focusPolicy?.unregister(field, as: .inlineEdit)
            focusPolicy = policy
            policy?.register(field, as: .inlineEdit)
        }

        /// Dismantle is not a user submit or cancellation.
        func retire() {
            committed = true
        }

        func focusDidApply(to field: NSTextField) {
            guard !selectedInitialText,
                  let editor = field.currentEditor() as? NSTextView else { return }
            selectedInitialText = true
            style.apply(to: editor)
            if selectStem {
                let name = field.stringValue as NSString
                let ext = name.pathExtension as NSString
                let stemLength = ext.length == 0 ? name.length : name.length - ext.length - 1
                editor.setSelectedRange(NSRange(location: 0, length: stemLength))
            } else {
                editor.selectAll(nil)
            }
        }

        public func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView
            else { return }

            field.textColor = style.nsTextColor
            style.apply(to: editor)
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            focusPolicy?.nativeTextEditingDidEnd()
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

        public func control(
            _ control: NSControl, textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard !committed else { return false }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                committed = true
                onCancel()
                return true  // Prevent system beep
            }
            return false
        }
    }
}

/// Selection setup follows successful policy focus, before the first text mutation.
private final class InlineEditTextField: NSTextField, EditorFocusReceiving {
    weak var focusCoordinator: InlineEditField.Coordinator?

    func editorFocusDidApply() {
        focusCoordinator?.focusDidApply(to: self)
    }
}
