import Foundation
import Observation

/// Observable state for the BEAM Observatory sidebar.
@MainActor
@Observable
final class ObservatoryState {
    var visible: Bool = false
    var nodes: [ObservatoryNode] = []

    var processCount: Int { nodes.count }
    var totalMemory: UInt64 { nodes.reduce(UInt64(0)) { $0 + UInt64($1.memory) } }

    /// Updates state from a decoded gui_observatory protocol message.
    func update(visible: Bool, rawNodes: [Wire.ObservatoryNode]) {
        self.visible = visible
        self.nodes = rawNodes.map(ObservatoryNode.init(raw:))
    }

    /// Hides the Observatory and clears transient selection.
    func hide() {
        visible = false
        nodes = []
    }
}

/// SwiftUI view model for a single BEAM process node.
struct ObservatoryNode: Identifiable, Equatable {
    let id: String
    let pid: String
    let parentPid: String
    let name: String
    let processClass: ObservatoryProcessClass
    let depth: Int
    let memory: UInt32
    let messageQueueLen: UInt16
    let reductions: UInt32
    let sparkline: [Float]

    init(raw: Wire.ObservatoryNode) {
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

    var isSupervisor: Bool { processClass == .supervisor }
}

/// Semantic process class from the BEAM.
enum ObservatoryProcessClass: UInt8 {
    case supervisor = 0
    case buffer = 1
    case agentSession = 2
    case lsp = 3
    case service = 4
    case worker = 5

    var icon: String {
        switch self {
        case .supervisor: return "square.stack.3d.up"
        case .buffer: return "doc.text"
        case .agentSession: return "sparkles"
        case .lsp: return "curlybraces"
        case .service: return "gearshape"
        case .worker: return "circle.hexagongrid"
        }
    }

    var label: String {
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
