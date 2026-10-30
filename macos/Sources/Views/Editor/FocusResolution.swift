import MingaProtocol

/// Frontend-local reasons to defer a committed owner, never alternative owners.
struct FocusLifecycleState: Sendable, Equatable {
    var nativeModalDepth = 0
    var windowIsKey = true
    var nativeTextEditingActive = false
}

/// Projects the BEAM fact to a responder without consulting surface visibility.
enum FocusResolution {
    static func resolve(
        committed: Wire.FocusOwner?, lifecycle: FocusLifecycleState
    ) -> Wire.FocusOwner.Responder? {
        guard lifecycle.nativeModalDepth == 0, lifecycle.windowIsKey,
              !lifecycle.nativeTextEditingActive else { return nil }
        return committed?.responderKind
    }
}
