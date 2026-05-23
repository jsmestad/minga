import Foundation

@MainActor
@Observable
final class EditTimelineState {
    var visible: Bool = false
    var viewingIndex: Int = -1
    var entries: [TimelineEntry] = []

    struct TimelineEntry: Identifiable {
        let index: Int
        let toolName: String
        let timestampDelta: UInt32

        var id: Int { index }
    }

    func update(visible: Bool, viewingIndex: UInt16, wireEntries: [Wire.TimelineEntry]) {
        self.visible = visible
        self.viewingIndex = viewingIndex == 0xFFFF ? -1 : Int(viewingIndex)
        self.entries = wireEntries.map { entry in
            TimelineEntry(
                index: Int(entry.index),
                toolName: entry.toolName,
                timestampDelta: entry.timestampDelta
            )
        }
    }
}
