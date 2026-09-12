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
}

/// Routes native Undo and Redo menu actions to the focused field editor or the BEAM-owned editor history.
@MainActor
enum NativeMenuHistoryRouter {
    enum Command {
        case undo
        case redo

        var nativeCommand: NativeTextCommandRouter.Command {
            switch self {
            case .undo: .undo
            case .redo: .redo
            }
        }

        var semanticCommandName: String {
            switch self {
            case .undo: "undo"
            case .redo: "redo"
            }
        }
    }

    static func perform(
        _ command: Command,
        encoder: InputEncoder?,
        application: NSApplication = NSApp
    ) {
        route(
            command,
            encoder: encoder,
            responder: application.keyWindow?.firstResponder
        ) { selector, target in
            application.sendAction(selector, to: target, from: nil)
        }
    }

    static func route(
        _ command: Command,
        encoder: InputEncoder?,
        responder: NSResponder?,
        sendNative: (Selector, NSResponder) -> Bool
    ) {
        if NativeTextCommandRouter.handles(responder) {
            _ = NativeTextCommandRouter.route(command.nativeCommand, to: responder, send: sendNative)
            return
        }
        encoder?.sendExecuteCommand(name: command.semanticCommandName)
    }
}
