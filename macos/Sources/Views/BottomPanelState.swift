/// Observable state for the bottom panel container.
///
/// The BEAM sends panel state (visible, active tab, height, tabs) each
/// frame via the `gui_bottom_panel` opcode (0x7B). SwiftUI renders the
/// panel view from this state.

import SwiftUI

/// A tab definition decoded from the BEAM protocol.
struct BottomPanelTab: Identifiable, Equatable {
    let id: Int
    let tabType: UInt8
    let name: String
}

@MainActor
@Observable
final class BottomPanelState {
    var visible: Bool = false
    var activeTabIndex: Int = 0
    var heightPercent: Int = 30
    var filterPreset: UInt8 = 0
    var tabs: [BottomPanelTab] = []

    /// Messages tab content state.
    let messagesState = MessagesContentState()

    /// Panel height stored in UserDefaults for persistence across show/hide.
    /// This is the user's drag-resized height; the BEAM's heightPercent is
    /// the initial/default value.
    var userHeight: CGFloat {
        get { UserDefaults.standard.double(forKey: "bottomPanelHeight").clamped(to: 100...800, fallback: 200) }
        set { UserDefaults.standard.set(newValue, forKey: "bottomPanelHeight") }
    }

    func update(visible: Bool, activeTabIndex: Int, heightPercent: Int,
                filterPreset: UInt8, tabs: [BottomPanelTab]) {
        self.visible = visible
        self.activeTabIndex = activeTabIndex
        self.heightPercent = heightPercent
        self.filterPreset = filterPreset
        self.tabs = tabs
    }

    func hide() {
        self.visible = false
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> CGFloat {
        let val = self == 0 ? fallback : self
        return CGFloat(min(max(val, range.lowerBound), range.upperBound))
    }
}
