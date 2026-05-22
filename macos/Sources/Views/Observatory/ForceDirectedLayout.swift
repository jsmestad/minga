import CoreGraphics
import Foundation

/// Small deterministic force-directed layout for the BEAM Observatory graph.
struct ForceDirectedLayout {
    private let iterations: Int = 48

    /// Computes node positions in the provided viewport.
    func positions(for nodes: [ObservatoryNode], in size: CGSize) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        var positions = seededPositions(nodes: nodes, size: size)
        let area = max(size.width * size.height, 1)
        let k = sqrt(area / CGFloat(max(nodes.count, 1)))

        let iterationCount = nodes.count > 120 ? 8 : (nodes.count > 60 ? 16 : iterations)
        let nodesById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        for _ in 0..<iterationCount {
            var displacement = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, CGVector(dx: 0, dy: 0)) })

            for left in nodes {
                for right in nodes where left.id != right.id {
                    let delta = vector(from: positions[right.id] ?? .zero, to: positions[left.id] ?? .zero)
                    let distance = max(length(delta), 0.01)
                    let force = (k * k) / distance
                    displacement[left.id, default: .zero].dx += delta.dx / distance * force
                    displacement[left.id, default: .zero].dy += delta.dy / distance * force
                }
            }

            for node in nodes where !node.parentPid.isEmpty {
                guard let parent = nodesById[node.parentPid] else { continue }
                let delta = vector(from: positions[parent.id] ?? .zero, to: positions[node.id] ?? .zero)
                let distance = max(length(delta), 0.01)
                let force = (distance * distance) / k
                displacement[node.id, default: .zero].dx -= delta.dx / distance * force
                displacement[node.id, default: .zero].dy -= delta.dy / distance * force
                displacement[parent.id, default: .zero].dx += delta.dx / distance * force
                displacement[parent.id, default: .zero].dy += delta.dy / distance * force
            }

            let temperature = max(min(size.width, size.height) / 12, 12)
            for node in nodes {
                let delta = displacement[node.id] ?? .zero
                let distance = max(length(delta), 0.01)
                let limited = min(distance, temperature)
                let current = positions[node.id] ?? .zero
                positions[node.id] = CGPoint(
                    x: min(max(current.x + delta.dx / distance * limited, 40), max(size.width - 40, 40)),
                    y: min(max(current.y + delta.dy / distance * limited, 30), max(size.height - 30, 30))
                )
            }
        }

        return positions
    }

    private func seededPositions(nodes: [ObservatoryNode], size: CGSize) -> [String: CGPoint] {
        Dictionary(uniqueKeysWithValues: nodes.enumerated().map { index, node in
            let angle = (CGFloat(index) / CGFloat(max(nodes.count, 1))) * CGFloat.pi * 2
            let radius = min(size.width, size.height) * 0.35
            return (node.id, CGPoint(x: size.width / 2 + cos(angle) * radius, y: size.height / 2 + sin(angle) * radius))
        })
    }

    private func vector(from: CGPoint, to: CGPoint) -> CGVector {
        CGVector(dx: to.x - from.x, dy: to.y - from.y)
    }

    private func length(_ vector: CGVector) -> CGFloat {
        sqrt(vector.dx * vector.dx + vector.dy * vector.dy)
    }
}
