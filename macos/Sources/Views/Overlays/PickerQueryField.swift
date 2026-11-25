import AppKit
import SwiftUI

enum PickerQueryKeyRouting {
    /// Readline edits the native field performs itself, so the local caret stays authoritative while you type.
    enum LineEdit: Equatable {
        case deleteWordBackward
        case deleteToLineStart
    }

    /// What the query field does with a key that Cocoa turned into a command.
    enum Route: Equatable {
        /// The picker binds the key, or the BEAM handles it for a text picker: it is sent as a key press and the field does nothing.
        case forward(KeyPressIdentity)
        /// One of the readline edits Cocoa's field editor does not bind.
        case lineEdit(LineEdit)
        /// The key would end or abort editing in the field, and the picker does not bind it: it does nothing, so the query keeps its text and its focus.
        case ignore
        /// The field's own text editing.
        case native
    }

    /// Decides what a key does in the query field.
    ///
    /// `binds` answers whether the BEAM lists that exact key press for the open picker (`PickerState.binds`). The field keeps no list of picker keys: a listed key is forwarded, whatever it is, and an unlisted key stays with the field. A user's binding therefore wins over the field's own editing of the same chord.
    static func route(identity: KeyPressIdentity?, selectorName: String, fieldIsEmpty: Bool, binds: (UInt32, UInt8) -> Bool) -> Route {
        if let identity, binds(identity.codepoint, identity.modifiers) { return .forward(identity) }

        if let identity, let edit = lineEdit(identity) { return .lineEdit(edit) }

        // Backspace on an empty query is not a picker key: the BEAM handles it for a text picker (it leaves a prefix or a folder).
        if selectorName == "deleteBackward:", fieldIsEmpty { return .forward(KeyPressIdentity(codepoint: 127, modifiers: 0)) }

        return endsEditing(selectorName) ? .ignore : .native
    }

    /// Returns the readline edit for ⌃W or ⌃U, which Cocoa's field editor does not bind by default.
    static func lineEdit(_ identity: KeyPressIdentity) -> LineEdit? {
        guard identity.modifiers == 0x02 else { return nil }

        switch identity.codepoint {
        case 119: return .deleteWordBackward
        case 117: return .deleteToLineStart
        default: return nil
        }
    }

    /// Commands that make a one-line field end or abort its editing session. This is about the field's own life, not about what a key does in the picker.
    static func endsEditing(_ selectorName: String) -> Bool {
        switch selectorName {
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertTab:", "insertTabIgnoringFieldEditor:", "insertBacktab:", "cancelOperation:":
            return true
        default:
            return false
        }
    }
}

/// Native single-line picker editor with optimistic local caret and selection state.
struct PickerQueryField: NSViewRepresentable {
    @Environment(\.editorFocusPolicy) private var focusPolicy
    enum Action: Equatable, Sendable {
        case queryChanged(generation: UInt32, editSequence: UInt32, text: String)
        case keyPress(codepoint: UInt32, modifiers: UInt8, sequence: UInt32)
    }

    let authoritativeText: String
    let generation: UInt32
    let acknowledgedEditSequence: UInt32
    let placeholder: String
    let isEditable: Bool
    let style: InlineEditFieldStyle
    /// Whether the BEAM lists a key press for the open picker. A listed key is sent to the BEAM, every other key edits the query.
    var binds: (UInt32, UInt8) -> Bool = { _, _ in false }
    let sendAction: ViewActionHandler<Action>?

    func makeCoordinator() -> Coordinator {
        Coordinator(sendAction: sendAction, style: style, binds: binds)
    }

    func makeNSView(context: Context) -> PickerNSTextField {
        let field = PickerNSTextField()
        field.setAccessibilityIdentifier("minga.picker.query")
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: Typography.Step.emphasis.rawValue, weight: .regular)
        field.lineBreakMode = .byClipping
        field.isSelectable = true
        field.isEditable = isEditable && sendAction != nil
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        context.coordinator.apply(style: style, to: field)
        context.coordinator.reconcile(field: field, generation: generation, acknowledgedSequence: acknowledgedEditSequence, authoritativeText: authoritativeText)
        context.coordinator.reconcileFocusPolicy(focusPolicy, field: field)
        return field
    }

    func updateNSView(_ field: PickerNSTextField, context: Context) {
        context.coordinator.sendAction = sendAction
        context.coordinator.style = style
        context.coordinator.binds = binds
        field.isEditable = isEditable && sendAction != nil
        field.placeholderString = placeholder
        context.coordinator.apply(style: style, to: field)

        context.coordinator.reconcile(field: field, generation: generation, acknowledgedSequence: acknowledgedEditSequence, authoritativeText: authoritativeText)
        context.coordinator.reconcileFocusPolicy(focusPolicy, field: field)
    }

    static func dismantleNSView(_ field: PickerNSTextField, coordinator: Coordinator) {
        coordinator.focusPolicy?.unregister(field, as: .pickerQuery)
        field.window?.endEditing(for: field)
        coordinator.focusPolicy?.nativeTextEditingDidEnd()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var sendAction: ViewActionHandler<Action>?
        var style: InlineEditFieldStyle
        var binds: (UInt32, UInt8) -> Bool
        var reconciler = PickerQueryReconciler()
        weak var focusPolicy: (any EditorFocusControlling)?
        private var applyingAuthoritativeText = false

        init(sendAction: ViewActionHandler<Action>?, style: InlineEditFieldStyle, binds: @escaping (UInt32, UInt8) -> Bool = { _, _ in false }) {
            self.sendAction = sendAction
            self.style = style
            self.binds = binds
        }

        func reconcileFocusPolicy(_ policy: (any EditorFocusControlling)?, field: NSTextField) {
            guard focusPolicy !== policy else { return }
            focusPolicy?.unregister(field, as: .pickerQuery)
            focusPolicy = policy
            policy?.register(field, as: .pickerQuery)
        }


        func reconcile(field: NSTextField, generation: UInt32, acknowledgedSequence: UInt32, authoritativeText: String) {
            reconcile(field: field, editor: field.currentEditor() as? NSTextView, generation: generation, acknowledgedSequence: acknowledgedSequence, authoritativeText: authoritativeText)
        }

        func reconcile(field: NSTextField, editor: NSTextView?, generation: UInt32, acknowledgedSequence: UInt32, authoritativeText: String) {
            guard let text = reconciler.reconcile(generation: generation, acknowledgedSequence: acknowledgedSequence, authoritativeText: authoritativeText) else { return }
            guard field.stringValue != text else { return }

            applyingAuthoritativeText = true
            let selection = editor?.selectedRange()
            let previousText = editor?.string ?? field.stringValue
            field.stringValue = text

            if let editor, let selection {
                editor.string = text
                editor.setSelectedRange(PickerQueryReconciler.adoptedSelection(selection, previousText: previousText, adoptedText: text))
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

        func controlTextDidEndEditing(_ notification: Notification) {
            focusPolicy?.nativeTextEditingDidEnd()
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
                  let sendAction,
                  !editor.hasMarkedText(),
                  let edit = reconciler.recordLocalEdit(field.stringValue)
            else { return }

            sendAction(.queryChanged(generation: edit.generation, editSequence: edit.sequence, text: edit.text))
        }

        func control(_ control: NSControl, textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let replacement = replacementString ?? ""
            let candidate = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacement)
            return PickerQueryReconciler.queryFitsWire(candidate)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let identity = NSApp.currentEvent.flatMap(KeyPressIdentity.command(from:))
            let route = PickerQueryKeyRouting.route(
                identity: identity,
                selectorName: NSStringFromSelector(commandSelector),
                fieldIsEmpty: textView.string.isEmpty,
                binds: binds
            )

            switch route {
            case .forward(let key):
                sendAction?(.keyPress(codepoint: key.codepoint, modifiers: key.modifiers, sequence: 0))
                return true
            case .lineEdit(.deleteWordBackward):
                textView.deleteWordBackward(nil)
                return true
            case .lineEdit(.deleteToLineStart):
                textView.deleteToBeginningOfLine(nil)
                return true
            case .ignore:
                return true
            case .native:
                return false
            }
        }

    }
}

final class PickerNSTextField: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
}
