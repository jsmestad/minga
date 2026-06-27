import Foundation

@MainActor
@Observable
final class EditTimelineState {
    var visible: Bool = false
    var viewingIndex: Int = -1
    var entries: [TimelineEntry] = []
    var files: [TimelineFile] = []

    struct TimelineEntry: Identifiable {
        let index: Int
        let toolName: String
        let timestampDelta: UInt32

        var id: Int { index }
    }

    struct TimelineFile: Identifiable {
        let path: String
        let entryCount: Int
        let linesAdded: UInt32
        let linesRemoved: UInt32
        let reviewStatus: UInt8

        var id: String { path }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    func update(visible: Bool, viewingIndex: UInt16, wireEntries: [Wire.TimelineEntry], wireFiles: [Wire.TimelineFile]) {
        self.visible = visible
        self.viewingIndex = viewingIndex == 0xFFFF ? -1 : Int(viewingIndex)
        self.entries = wireEntries.map { entry in
            TimelineEntry(
                index: Int(entry.index),
                toolName: entry.toolName,
                timestampDelta: entry.timestampDelta
            )
        }
        self.files = wireFiles.map { file in
            TimelineFile(
                path: file.path,
                entryCount: Int(file.entryCount),
                linesAdded: file.linesAdded,
                linesRemoved: file.linesRemoved,
                reviewStatus: file.reviewStatus
            )
        }
    }
}
