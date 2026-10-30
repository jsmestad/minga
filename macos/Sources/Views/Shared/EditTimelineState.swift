import Foundation
import MingaProtocol
import Observation

@MainActor
@Observable
public final class EditTimelineState {
    public init(visible: Bool = false, viewingIndex: Int = -1, entries: [TimelineEntry] = [], files: [TimelineFile] = [], generation: UInt32 = 0) {
        self.visible = visible
        self.viewingIndex = viewingIndex
        self.entries = entries
        self.files = files
        self.generation = generation
    }
    public var visible: Bool = false
    public var generation: UInt32 = 0
    public var viewingIndex: Int = -1
    public var entries: [TimelineEntry] = []
    public var files: [TimelineFile] = []

    public struct TimelineEntry: Identifiable {
        public init(entryID: String, index: Int, toolName: String, timestampDelta: UInt32) {
            self.entryID = entryID
            self.index = index
            self.toolName = toolName
            self.timestampDelta = timestampDelta
        }
        public let index: Int
        public let entryID: String
        public let toolName: String
        public let timestampDelta: UInt32

        public var id: String { entryID }
    }

    public struct TimelineFile: Identifiable {
        public init(path: String, entryCount: Int, linesAdded: UInt32, linesRemoved: UInt32, reviewStatus: UInt8) {
            self.path = path
            self.entryCount = entryCount
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
            self.reviewStatus = reviewStatus
        }
        public let path: String
        public let entryCount: Int
        public let linesAdded: UInt32
        public let linesRemoved: UInt32
        public let reviewStatus: UInt8

        public var id: String { path }
        public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    }

    public func update(visible: Bool, viewingIndex: UInt16, wireEntries: [Wire.TimelineEntry], wireFiles: [Wire.TimelineFile], generation: UInt32) {
        self.visible = visible
        self.generation = generation
        self.viewingIndex = viewingIndex == 0xFFFF ? -1 : Int(viewingIndex)
        self.entries = wireEntries.map { entry in
            TimelineEntry(
                entryID: entry.entryID,
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
