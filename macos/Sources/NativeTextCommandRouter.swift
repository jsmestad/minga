import AppKit
import MingaUI

/// Keeps standard macOS editing commands local when an AppKit field editor owns focus.
@MainActor
enum NativeTextCommandRouter {
    enum Command: String, CaseIterable {
        case undo = "undo:"
        case redo = "redo:"
        case cut = "cut:"
        case copy = "copy:"
        case paste = "paste:"
        case selectAll = "selectAll:"

        var selector: Selector { Selector((rawValue)) }
    }

    static func perform(_ command: Command, application: NSApplication = NSApp) -> Bool {
        route(command, to: application.keyWindow?.firstResponder) { selector, target in
            application.sendAction(selector, to: target, from: nil)
        }
    }

    static func route(
        _ command: Command,
        to responder: NSResponder?,
        send: (Selector, NSResponder) -> Bool
    ) -> Bool {
        guard let responder, handles(responder) else { return false }
        return send(command.selector, responder)
    }

    static func handles(_ responder: NSResponder?) -> Bool {
        responder is NSTextView
    }

    static func isAvailable(
        _ command: Command,
        to responder: NSResponder?,
        target: (Selector, NSResponder) -> Any?
    ) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        switch command {
        case .undo:
            return textView.undoManager?.canUndo ?? false
        case .redo:
            return textView.undoManager?.canRedo ?? false
        case .cut, .copy, .paste, .selectAll:
            break
        }
        guard let target = target(command.selector, textView) else { return false }
        let menuItem = NSMenuItem(title: "", action: command.selector, keyEquivalent: "")
        if let validator = target as? NSMenuItemValidation {
            return validator.validateMenuItem(menuItem)
        }
        if let validator = target as? NSUserInterfaceValidations {
            return validator.validateUserInterfaceItem(menuItem)
        }
        return true
    }
}

/// Routes standard Edit menu actions to the focused native field editor or one BEAM-owned editor fallback.
@MainActor
enum NativeMenuTextRouter {
    static func perform(
        _ command: NativeTextCommandRouter.Command,
        encoder: OutboundActionEncoding?,
        application: NSApplication = NSApp,
        fallback: (OutboundActionEncoding) -> Void
    ) {
        route(
            command,
            encoder: encoder,
            responder: application.keyWindow?.firstResponder
        ) { selector, target in
            application.sendAction(selector, to: target, from: nil)
        } fallback: {
            fallback($0)
        }
    }

    static func isAvailable(
        _ command: NativeTextCommandRouter.Command,
        encoder: OutboundActionEncoding?,
        application: NSApplication = NSApp
    ) -> Bool {
        isAvailable(
            command,
            encoder: encoder,
            responder: application.keyWindow?.firstResponder
        ) { selector, responder in
            application.target(forAction: selector, to: responder, from: nil)
        }
    }

    static func route(
        _ command: NativeTextCommandRouter.Command,
        encoder: OutboundActionEncoding?,
        responder: NSResponder?,
        sendNative: (Selector, NSResponder) -> Bool,
        fallback: (OutboundActionEncoding) -> Void
    ) {
        if NativeTextCommandRouter.handles(responder) {
            _ = NativeTextCommandRouter.route(command, to: responder, send: sendNative)
            return
        }
        guard let encoder else { return }
        fallback(encoder)
    }

    static func isAvailable(
        _ command: NativeTextCommandRouter.Command,
        encoder: OutboundActionEncoding?,
        responder: NSResponder?,
        target: (Selector, NSResponder) -> Any?
    ) -> Bool {
        if NativeTextCommandRouter.handles(responder) {
            return NativeTextCommandRouter.isAvailable(command, to: responder, target: target)
        }
        return encoder != nil
    }
}
