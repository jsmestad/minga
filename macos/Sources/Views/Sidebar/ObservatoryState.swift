import Foundation
import Observation
import MingaProtocol

/// Observable state for the BEAM Observatory sidebar.
@MainActor
@Observable
public final class ObservatoryState {
    public init(visible: Bool = false, nodes: [ObservatoryNode] = []) {
        self.visible = visible
        self.nodes = nodes
    }
    public var visible: Bool = false
    public var nodes: [ObservatoryNode] = []

    public var processCount: Int { nodes.count }
    public var totalMemory: UInt64 { nodes.reduce(UInt64(0)) { $0 + UInt64($1.memory) } }

    /// Updates state from a decoded gui_observatory protocol message.
    public func update(visible: Bool, rawNodes: [Wire.ObservatoryNode]) {
        self.visible = visible
        self.nodes = rawNodes.map(ObservatoryNode.init(raw:))
    }

    /// Hides the Observatory and clears transient selection.
    public func hide() {
        visible = false
        nodes = []
    }
}

/// SwiftUI view model for a single BEAM process node.
public struct ObservatoryNode: Identifiable, Equatable {
    public let id: String
    public let pid: String
    public let parentPid: String
    public let name: String
    public let processClass: ObservatoryProcessClass
    public let depth: Int
    public let memory: UInt32
    public let messageQueueLen: UInt16
    public let reductions: UInt32
    public let sparkline: [Float]

    public init(raw: Wire.ObservatoryNode) {
        id = raw.pid
        pid = raw.pid
        parentPid = raw.parentPid
        name = raw.name
        processClass = ObservatoryProcessClass(rawValue: raw.processClass) ?? .worker
        depth = Int(raw.depth)
        memory = raw.memory
        messageQueueLen = raw.messageQueueLen
        reductions = raw.reductions
        sparkline = raw.sparkline
    }

    public var isSupervisor: Bool { processClass == .supervisor }
}

/// Semantic process class from the BEAM.
public enum ObservatoryProcessClass: UInt8 {
    case supervisor = 0
    case buffer = 1
    case agentSession = 2
    case lsp = 3
    case service = 4
    case worker = 5

    public var icon: String {
        switch self {
        case .supervisor: return "square.stack.3d.up"
        case .buffer: return "doc.text"
        case .agentSession: return "sparkles"
        case .lsp: return "curlybraces"
        case .service: return "gearshape"
        case .worker: return "circle.hexagongrid"
        }
    }

    public var label: String {
        switch self {
        case .supervisor: return "supervisor"
        case .buffer: return "buffer"
        case .agentSession: return "agent"
        case .lsp: return "lsp"
        case .service: return "service"
        case .worker: return "worker"
        }
    }
}
