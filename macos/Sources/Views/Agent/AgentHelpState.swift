import AppKit
import SwiftUI
import MingaProtocol

/// Committed Help chrome, independent of Chat and its composer/transcript lifetime.
@MainActor
@Observable
public final class AgentHelpState {
    public init() {}

    public private(set) var visible = false
    public private(set) var groups: [Wire.HelpGroup] = []

    @ObservationIgnored let scrollAttachment = AgentHelpScrollAttachment()

    /// Previews Help scrolling while the editor still forwards the original input to the BEAM.
    public func previewNavigation(_ event: NSEvent, in window: NSWindow?) {
        guard visible else { return }
        scrollAttachment.previewNavigation(event, in: window)
    }

    public func update(visible: Bool, groups: [Wire.HelpGroup]) {
        self.visible = visible
        self.groups = visible ? groups : []
    }

    public func hide() {
        update(visible: false, groups: [])
    }
}
