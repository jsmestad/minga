/// Observable state for the bottom panel container.
///
/// The BEAM sends panel state (visible, active tab, height, tabs) each
/// frame via the `gui_bottom_panel` opcode (0x7B). SwiftUI renders the
/// panel view from this state.

import Foundation
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
    /// Persistence for the frontend's locally resized panel height.
    public enum HeightStorage {
        case transient
        case applicationPreferences
        case file(URL)
    }

    private let heightStorage: HeightStorage
    private static let heightPreferenceKey = "bottomPanelHeight"

    public init(
        visible: Bool = false, activeTabIndex: Int = 0, heightPercent: Int = 30,
        filterPreset: UInt8 = 0, tabs: [BottomPanelTab] = [], heightStorage: HeightStorage = .transient
    ) {
        self.heightStorage = heightStorage
        self.visible = visible
        self.activeTabIndex = activeTabIndex
        self.heightPercent = heightPercent
        self.filterPreset = filterPreset
        self.tabs = tabs
        self.userHeight = Self.loadHeight(from: heightStorage).clamped(to: 100...800, fallback: 200)
    }
    public var visible: Bool = false
    public var activeTabIndex: Int = 0
    public var heightPercent: Int = 30
    public var filterPreset: UInt8 = 0
    public var tabs: [BottomPanelTab] = []

    /// Messages tab content state.
    public let messagesState = MessagesContentState()

    /// User's drag-resized height. The BEAM's heightPercent is the initial/default value.
    public var userHeight: CGFloat

    /// Persists the completed resize without writing during the drag.
    public func persistUserHeight() {
        switch heightStorage {
        case .transient:
            break
        case .applicationPreferences:
            UserDefaults.standard.set(Double(userHeight), forKey: Self.heightPreferenceKey)
        case .file(let url):
            do {
                try String(Double(userHeight)).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                PortLogger.warn("Could not save bottom panel height", privateDetail: error.localizedDescription)
            }
        }
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
            messagesState.activeLevels = [.warning, .error]
        }
    }

    public func hide() {
        self.visible = false
    }

    private static func loadHeight(from storage: HeightStorage) -> Double {
        switch storage {
        case .transient:
            return 0
        case .applicationPreferences:
            return UserDefaults.standard.double(forKey: heightPreferenceKey)
        case .file(let url):
            guard let value = try? String(contentsOf: url, encoding: .utf8),
                  let height = Double(value), height.isFinite else { return 0 }
            return height
        }
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> CGFloat {
        let val = self == 0 ? fallback : self
        return CGFloat(min(max(val, range.lowerBound), range.upperBound))
    }
}
