import AppKit
import SwiftUI

struct PickerQueryKeyCommand: Equatable {
    let codepoint: UInt32
    let modifiers: UInt8
}

enum PickerQueryKeyRouting {
    static func controlBinding(characters: String?, modifiers: NSEvent.ModifierFlags) -> PickerQueryKeyCommand? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control), !flags.contains(.command), let character = characters?.lowercased() {
            switch character {
            case "g", "j", "k", "n", "o", "p", "v", "d":
                return PickerQueryKeyCommand(codepoint: character.unicodeScalars.first?.value ?? 0, modifiers: 0x02)
            default:
                return nil
            }
        }

        if flags.contains(.option), !flags.contains(.command), characters?.lowercased() == "v" {
            return PickerQueryKeyCommand(codepoint: 118, modifiers: 0x04)
        }

        return nil
    }

    static func selectorBinding(_ selectorName: String, fieldIsEmpty: Bool) -> PickerQueryKeyCommand? {
        switch selectorName {
        case "moveUp:":
            return PickerQueryKeyCommand(codepoint: 57_352, modifiers: 0)
        case "moveDown:":
            return PickerQueryKeyCommand(codepoint: 57_353, modifiers: 0)
        case "pageUp:", "scrollPageUp:":
            return PickerQueryKeyCommand(codepoint: 118, modifiers: 0x04)
        case "pageDown:", "scrollPageDown:":
            return PickerQueryKeyCommand(codepoint: 118, modifiers: 0x02)
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
            return PickerQueryKeyCommand(codepoint: 13, modifiers: 0)
        case "insertTab:", "insertTabIgnoringFieldEditor:":
            return PickerQueryKeyCommand(codepoint: 9, modifiers: 0)
        case "cancelOperation:":
            return PickerQueryKeyCommand(codepoint: 27, modifiers: 0)
        case "deleteBackward:" where fieldIsEmpty:
            return PickerQueryKeyCommand(codepoint: 127, modifiers: 0)
        default:
            return nil
        }
    }
}

/// Native single-line picker editor with optimistic local caret and selection state.
struct PickerQueryField: NSViewRepresentable {
    let authoritativeText: String
    let generation: UInt32
    let acknowledgedEditSequence: UInt32
    let placeholder: String
    let isEditable: Bool
    let style: InlineEditFieldStyle
    let encoder: (any InputEncoder)?

    func makeCoordinator() -> Coordinator {
        Coordinator(encoder: encoder, style: style)
    }

    func makeNSView(context: Context) -> PickerNSTextField {
        let field = PickerNSTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.lineBreakMode = .byClipping
        field.isSelectable = true
        field.isEditable = isEditable && encoder != nil
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        context.coordinator.apply(style: style, to: field)
        context.coordinator.reconcile(field: field, generation: generation, acknowledgedSequence: acknowledgedEditSequence, authoritativeText: authoritativeText)
        context.coordinator.focus(field)
        return field
    }

    func updateNSView(_ field: PickerNSTextField, context: Context) {
        context.coordinator.encoder = encoder
        context.coordinator.style = style
        field.isEditable = isEditable && encoder != nil
        field.placeholderString = placeholder
        context.coordinator.apply(style: style, to: field)

        let generationChanged = context.coordinator.reconciler.generation != generation
        context.coordinator.reconcile(field: field, generation: generation, acknowledgedSequence: acknowledgedEditSequence, authoritativeText: authoritativeText)
        if generationChanged {
            context.coordinator.focus(field)
        }
    }

    static func dismantleNSView(_ field: PickerNSTextField, coordinator: Coordinator) {
        field.window?.endEditing(for: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var encoder: (any InputEncoder)?
        var style: InlineEditFieldStyle
        var reconciler = PickerQueryReconciler()
        private var applyingAuthoritativeText = false

        init(encoder: (any InputEncoder)?, style: InlineEditFieldStyle) {
            self.encoder = encoder
            self.style = style
        }

        func focus(_ field: NSTextField) {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

        func reconcile(field: NSTextField, generation: UInt32, acknowledgedSequence: UInt32, authoritativeText: String) {
            reconcile(field: field, editor: field.currentEditor() as? NSTextView, generation: generation, acknowledgedSequence: acknowledgedSequence, authoritativeText: authoritativeText)
        }

        func reconcile(field: NSTextField, editor: NSTextView?, generation: UInt32, acknowledgedSequence: UInt32, authoritativeText: String) {
            guard let text = reconciler.reconcile(generation: generation, acknowledgedSequence: acknowledgedSequence, authoritativeText: authoritativeText) else { return }
            guard field.stringValue != text else { return }

            applyingAuthoritativeText = true
            let selection = editor?.selectedRange()
            field.stringValue = text

            if let editor, let selection {
                editor.string = text
                editor.setSelectedRange(PickerQueryReconciler.clampSelection(selection, to: text))
            }

            applyingAuthoritativeText = false
        }

        func apply(style: InlineEditFieldStyle, to field: NSTextField) {
            field.textColor = style.nsTextColor
            guard let editor = field.currentEditor() as? NSTextView else { return }
            style.apply(to: editor)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            apply(style: style, to: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView
            else { return }

            handleTextChange(field: field, editor: editor)
        }

        func handleTextChange(field: NSTextField, editor: NSTextView) {
            guard !applyingAuthoritativeText,
                  field.isEditable,
                  let encoder,
                  !editor.hasMarkedText(),
                  let edit = reconciler.recordLocalEdit(field.stringValue)
            else { return }

            encoder.sendPickerQueryChanged(generation: edit.generation, editSeq: edit.sequence, text: edit.text)
        }

        func control(_ control: NSControl, textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let replacement = replacementString ?? ""
            let candidate = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacement)
            return PickerQueryReconciler.queryFitsWire(candidate)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if let event = NSApp.currentEvent,
               let command = PickerQueryKeyRouting.controlBinding(characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags)
            {
                encoder?.sendKeyPress(codepoint: command.codepoint, modifiers: command.modifiers)
                return true
            }

            let selectorName = NSStringFromSelector(commandSelector)
            guard let command = PickerQueryKeyRouting.selectorBinding(selectorName, fieldIsEmpty: textView.string.isEmpty) else { return false }
            encoder?.sendKeyPress(codepoint: command.codepoint, modifiers: command.modifiers)
            return true
        }

    }
}

final class PickerNSTextField: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
}
