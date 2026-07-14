/// Observable state for the bottom panel container.
///
/// The BEAM sends panel state (visible, active tab, height, tabs) each
/// frame via the `gui_bottom_panel` opcode (0x7B). SwiftUI renders the
/// panel view from this state.

import SwiftUI

/// A tab definition decoded from the BEAM protocol.
public struct BottomPanelTab: Identifiable, Equatable {
    public init(id: Int, tabType: UInt8, name: String) {
        self.id = id
        self.tabType = tabType
        self.name = name
    }
    public let id: Int
    public let tabType: UInt8
    public let name: String
}

@MainActor
@Observable
public final class BottomPanelState {
    public init(visible: Bool = false, activeTabIndex: Int = 0, heightPercent: Int = 30, filterPreset: UInt8 = 0, tabs: [BottomPanelTab] = []) {
        self.visible = visible
        self.activeTabIndex = activeTabIndex
        self.heightPercent = heightPercent
        self.filterPreset = filterPreset
        self.tabs = tabs
        self.userHeight = UserDefaults.standard.double(forKey: "bottomPanelHeight").clamped(to: 100...800, fallback: 200)
    }
    public var visible: Bool = false
    public var activeTabIndex: Int = 0
    public var heightPercent: Int = 30
    public var filterPreset: UInt8 = 0
    public var tabs: [BottomPanelTab] = []

    /// Messages tab content state.
    public let messagesState = MessagesContentState()

    /// Panel height stored in UserDefaults for persistence across show/hide.
    /// This is the user's drag-resized height; the BEAM's heightPercent is
    /// the initial/default value.
    public var userHeight: CGFloat {
        didSet { UserDefaults.standard.set(userHeight, forKey: "bottomPanelHeight") }
    }

    public func update(visible: Bool, activeTabIndex: Int, heightPercent: Int,
                filterPreset: UInt8, tabs: [BottomPanelTab]) {
        let wasHidden = !self.visible
        self.activeTabIndex = activeTabIndex
        self.heightPercent = heightPercent
        self.filterPreset = filterPreset
        self.tabs = tabs
        self.visible = visible

        // Apply filter preset on visibility transition (hidden -> visible)
        // only if the user hasn't already changed filters manually.
        if wasHidden && visible && filterPreset == 1 {
            messagesState.activeLevels = [2, 3]  // warning + error
        }
    }

    public func hide() {
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
