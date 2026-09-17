import AppKit
import SwiftUI

/// Native single-line search editor that preserves AppKit marked text until IME commit.
struct SearchQueryField: NSViewRepresentable {
    enum Action: Equatable, Sendable {
        case query(sessionID: UInt32, editSequence: UInt32, query: String, flags: UInt8)
        case previous
        case next
        case dismiss
    }

    let searchState: SearchState
    let style: InlineEditFieldStyle
    let sendAction: ViewActionHandler<Action>?

    func makeCoordinator() -> Coordinator {
        Coordinator(searchState: searchState, sendAction: sendAction, style: style)
    }

    func makeNSView(context: Context) -> SearchNSTextField {
        let field = SearchNSTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byClipping
        field.isSelectable = true
        field.isEditable = sendAction != nil
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        context.coordinator.apply(style: style, to: field)
        context.coordinator.reconcile(field: field, query: searchState.query)
        context.coordinator.sessionID = searchState.sessionID
        context.coordinator.focus(field)
        return field
    }

    func updateNSView(_ field: SearchNSTextField, context: Context) {
        context.coordinator.sendAction = sendAction
        context.coordinator.style = style
        field.isEditable = sendAction != nil
        context.coordinator.apply(style: style, to: field)
        context.coordinator.reconcile(field: field, query: searchState.query)

        if context.coordinator.sessionID != searchState.sessionID {
            context.coordinator.sessionID = searchState.sessionID
            context.coordinator.focus(field)
        }
    }

    static func dismantleNSView(_ field: SearchNSTextField, coordinator: Coordinator) {
        field.window?.endEditing(for: field)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let searchState: SearchState
        var sendAction: ViewActionHandler<Action>?
        var style: InlineEditFieldStyle
        var sessionID: UInt32 = 0
        private var applyingAuthoritativeText = false

        init(searchState: SearchState, sendAction: ViewActionHandler<Action>?, style: InlineEditFieldStyle) {
            self.searchState = searchState
            self.sendAction = sendAction
            self.style = style
        }

        func focus(_ field: NSTextField) {
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
            }
        }

        func reconcile(field: NSTextField, query: String) {
            let editor = field.currentEditor() as? NSTextView
            guard editor?.hasMarkedText() != true, field.stringValue != query else { return }

            applyingAuthoritativeText = true
            let selection = editor?.selectedRange()
            field.stringValue = query
            if let editor, let selection {
                editor.string = query
                editor.setSelectedRange(SearchState.clampSelection(selection, to: query))
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
                  let sendAction,
                  !editor.hasMarkedText(),
                  let edit = searchState.recordQueryEdit(field.stringValue)
            else { return }

            sendAction(.query(sessionID: edit.sessionID, editSequence: edit.sequence, query: edit.query, flags: edit.flags))
        }

        func control(_ control: NSControl, textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            let replacement = replacementString ?? ""
            let candidate = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacement)
            return SearchState.queryFitsWire(candidate)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:":
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    sendAction?(.previous)
                } else {
                    sendAction?(.next)
                }
                return true
            case "cancelOperation:":
                sendAction?(.dismiss)
                return true
            default:
                return false
            }
        }
    }
}

final class SearchNSTextField: NSTextField {
    override var mouseDownCanMoveWindow: Bool { false }
}
