/// Kind-scoped flags carried by a legacy tab-bar entry.
public struct TabFlags: OptionSet, Sendable {
    public let rawValue: UInt8

    /// Creates flags while retaining all unknown bits.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let active = TabFlags(rawValue: 0x01)
    public static let dirty = TabFlags(rawValue: 0x02)
    public static let agent = TabFlags(rawValue: 0x04)
    public static let attention = TabFlags(rawValue: 0x08)
    public static let ephemeralFile = TabFlags(rawValue: 0x10)
    public static let pinned = TabFlags(rawValue: 0x80)

    /// The agent-status payload stored in bits 4 through 6.
    public var agentStatus: AgentStatus {
        AgentStatus(rawValue: (rawValue >> 4) & 0x07)
    }

    /// Whether this file tab represents content not backed by a file on disk.
    public var isEphemeralFile: Bool {
        !contains(.agent) && contains(.ephemeralFile)
    }

    /// Bits that are not meaningful for this entry's kind.
    public var unknownBits: UInt8 {
        if contains(.agent) {
            return 0
        }
        return rawValue & 0x60
    }
}
