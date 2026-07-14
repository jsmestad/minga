/// Consumer regions affected by one atomic GUI commit.
public struct GUIFrameImpact: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shell = GUIFrameImpact(rawValue: 1 << 0)
    public static let editor = GUIFrameImpact(rawValue: 1 << 1)
    public static let editorOverlay = GUIFrameImpact(rawValue: 1 << 2)
    public static let windowOverlay = GUIFrameImpact(rawValue: 1 << 3)
    public static let all: GUIFrameImpact = [.shell, .editor, .editorOverlay, .windowOverlay]
}

/// Identity of a transaction committed by the BEAM.
public struct GUICommittedFrame: Equatable, Sendable {
    public let generation: UInt32
    public let frameSeq: UInt32

    public init(generation: UInt32, frameSeq: UInt32) {
        self.generation = generation
        self.frameSeq = frameSeq
    }
}
