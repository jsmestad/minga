import Foundation
import MingaProtocol
import Observation

/// The tasks drawer's committed model. `CommandDispatcher` is the only writer; the view reads.
@Observable
public final class TasksDrawerState {
    public init(drawer: Wire.TasksDrawer = .hidden) {
        self.drawer = drawer
    }

    public private(set) var drawer: Wire.TasksDrawer

    public var visible: Bool { drawer.visible }

    /// Installs the drawer the BEAM committed.
    public func update(_ drawer: Wire.TasksDrawer) {
        guard drawer != self.drawer else { return }
        self.drawer = drawer
    }

    /// Hides the drawer, for a reconnect before the BEAM's first frame.
    public func hide() {
        update(.hidden)
    }
}
