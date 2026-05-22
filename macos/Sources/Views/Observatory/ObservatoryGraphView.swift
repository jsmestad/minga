import SwiftUI

/// Force-directed graph view for the BEAM Observatory.
struct ObservatoryGraphView: View {
    let state: ObservatoryState
    let theme: ThemeColors
    let encoder: InputEncoder?
    @Binding var selectedNodeId: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let positions = ForceDirectedLayout().positions(for: state.nodes, in: geometry.size)

            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for node in state.nodes where !node.parentPid.isEmpty {
                        guard let start = positions[node.parentPid], let end = positions[node.id] else { continue }
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(theme.treeSeparatorFg.opacity(0.45)), lineWidth: 1)
                    }
                }

                ForEach(state.nodes) { node in
                    if let position = positions[node.id] {
                        pill(node)
                            .position(position)
                            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: position)
                    }
                }
            }
        }
        .padding(8)
        .focusable()
        .onMoveCommand(perform: moveSelection)
        .onKeyPress(.return) {
            inspectSelected()
            return .handled
        }
    }

    private func pill(_ node: ObservatoryNode) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(node))
                .frame(width: 7, height: 7)
                .scaleEffect(node.processClass == .agentSession && node.messageQueueLen > 0 ? 1.2 : 1.0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: node.messageQueueLen)
            Text(shortName(node.name))
                .font(.caption2)
                .lineLimit(1)
            Text(formatBytes(UInt64(node.memory)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.treeInactiveFg)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 170)
        .background(selectedNodeId == node.id ? theme.treeSelectionBg.opacity(0.8) : theme.treeBg.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(statusColor(node).opacity(0.65), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture {
            selectedNodeId = node.id
            encoder?.sendObservatoryInspect(pid: node.pid)
        }
    }

    private func statusColor(_ node: ObservatoryNode) -> Color {
        if node.messageQueueLen == 0 { return .green }
        if node.messageQueueLen <= 10 { return .orange }
        return .red
    }

    private func shortName(_ name: String) -> String {
        let trimmed = name.replacingOccurrences(of: "Elixir.", with: "")
        return String(trimmed.suffix(32))
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !state.nodes.isEmpty else { return }
        let currentIndex = state.nodes.firstIndex { $0.id == selectedNodeId } ?? 0
        let nextIndex: Int
        switch direction {
        case .left, .up:
            nextIndex = max(currentIndex - 1, 0)
        case .right, .down:
            nextIndex = min(currentIndex + 1, state.nodes.count - 1)
        @unknown default:
            nextIndex = currentIndex
        }
        selectedNodeId = state.nodes[nextIndex].id
    }

    private func inspectSelected() {
        guard let selected = state.nodes.first(where: { $0.id == selectedNodeId }) else { return }
        encoder?.sendObservatoryInspect(pid: selected.pid)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }
}
