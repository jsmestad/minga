import CoreGraphics
import MingaProtocol
import Observation

/// The last committed BEAM offer. Filtering and activation never mutate this state locally.
@Observable
public final class ActMenuState {
    public private(set) var menu: Wire.ActMenu?
    private(set) var presentedCaret: CGRect?

    public init() {}

    public func update(_ menu: Wire.ActMenu?) {
        guard self.menu != menu else { return }
        self.menu = menu
    }

    /// Anchors keyboard offers to the last caret that Metal actually displayed.
    public func updatePresentedCaret(_ caret: CGRect?) {
        guard presentedCaret != caret else { return }
        presentedCaret = caret
    }
}
