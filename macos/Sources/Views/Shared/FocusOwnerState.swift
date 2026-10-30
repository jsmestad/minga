import AppKit
import MingaProtocol
import Observation
import SwiftUI


/// Frontend-local text leases. These fields are intentionally not BEAM surfaces.
public enum LocalTextEditing: Equatable, Sendable {
    case workspaceRename(UInt16)
    case workspaceIconSearch
}

/// Read-only SwiftUI mirror. Only EditorFocusPolicy publishes changes through its SPI.
@MainActor
@Observable
public final class FocusOwnerState {
    public private(set) var decodedOwner: Wire.FocusOwner?
    public private(set) var localTextEditing: LocalTextEditing?

    public init() {}

    @_spi(FocusPolicy) public func publish(owner: Wire.FocusOwner?) {
        decodedOwner = owner
    }

    @_spi(FocusPolicy) public func publish(localTextEditing: LocalTextEditing?) {
        self.localTextEditing = localTextEditing
    }
}

/// Narrow focus-policy access shared by native fields and SwiftUI chrome leaves.
@MainActor
public protocol EditorFocusControlling: AnyObject, Sendable {
    var focusOwnerState: FocusOwnerState { get }
    func register(_ responder: NSResponder, as kind: Wire.FocusOwner.Responder)
    func unregister(_ responder: NSResponder, as kind: Wire.FocusOwner.Responder)
    func nativeTextEditingDidEnd()
    func beginLocalTextEditing(_ editing: LocalTextEditing)
    func endLocalTextEditing(_ editing: LocalTextEditing)
}

/// Native fields may initialize their field editor after policy focus succeeds.
@MainActor
public protocol EditorFocusReceiving: AnyObject {
    func editorFocusDidApply()
}

private struct EditorFocusPolicyKey: EnvironmentKey {
    static let defaultValue: (any EditorFocusControlling)? = nil
}

extension EnvironmentValues {
    /// Injected at the application boundary; previews may omit a native focus policy.
    public var editorFocusPolicy: (any EditorFocusControlling)? {
        get { self[EditorFocusPolicyKey.self] }
        set { self[EditorFocusPolicyKey.self] = newValue }
    }
}
