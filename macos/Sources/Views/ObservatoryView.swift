import SwiftUI

/// Native sidebar for observing the live BEAM supervision tree.
struct ObservatoryView: View {
    let state: ObservatoryState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var expandedNodeIds: Set<String> = []
    @State private var selectedNodeId: String?
    @State private var hasInitializedExpansion = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.treeSeparatorFg.opacity(0.4))

            treeList
        }
        .background(theme.treeBg)
        .onAppear(perform: reconcileLocalState)
        .onChange(of: state.nodes) { _, _ in reconcileLocalState() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("BEAM Observatory")
                    .font(.headline)
                    .foregroundStyle(theme.treeFg)
                Spacer()
                Text("\(state.processCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.treeFg.opacity(0.55))
            }

            Label(formatBytes(state.totalMemory), systemImage: "memorychip")
                .font(.caption)
                .foregroundStyle(theme.treeFg.opacity(0.55))
        }
        .padding(Spacing.md)
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.hairline) {
                ForEach(visibleTreeNodes()) { node in
                    row(node)
                }
            }
            .padding(.vertical, Spacing.sm)
        }
        .focusable(false)
        .focusEffectDisabled()
    }

    private func row(_ node: ObservatoryNode) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                activateRow(node)
            } label: {
                rowMainContent(node)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                selectedNodeId = node.id
                encoder?.sendObservatoryInspect(pid: node.pid)
            } label: {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(theme.treeFg.opacity(0.55))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
        }
        // 12pt per depth level (down from 14) keeps deep nodes from starving
        // the name column; the right-side memory/sparkline cluster is tightened
        // in rowMainContent for the same reason.
        .padding(.leading, CGFloat(node.depth) * Spacing.md + Spacing.sm)
        .padding(.trailing, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(selectedNodeId == node.id ? theme.treeSelectionBg.opacity(0.55) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func rowMainContent(_ node: ObservatoryNode) -> some View {
        HStack(spacing: Spacing.xs) {
            if node.isSupervisor {
                Image(systemName: disclosureIcon(node))
                    .font(.caption)
                    .frame(width: 12)
                    .foregroundStyle(theme.treeFg.opacity(0.55))
            } else {
                Color.clear.frame(width: 12).allowsHitTesting(false)
            }

            Image(systemName: node.processClass.icon)
                .font(.caption)
                .foregroundStyle(classColor(node))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: Spacing.hairline) {
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(statusColor(node))
                        .frame(width: 6, height: 6)
                    Text(shortName(node.name))
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(theme.treeFg)
                }
                Text("\(node.processClass.label) · \(node.pid)")
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(theme.treeFg.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatBytes(UInt64(node.memory)))
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(theme.treeFg.opacity(0.55))
                .frame(minWidth: 46, alignment: .trailing)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.hairline)
                .background(theme.treeSelectionBg.opacity(0.35), in: Capsule())

            SparklineView(data: node.sparkline, color: statusColor(node))
                .frame(width: 40, height: 16)
        }
        .contentShape(Rectangle())
    }

    private func disclosureIcon(_ node: ObservatoryNode) -> String {
        expandedNodeIds.contains(node.id) ? "chevron.down" : "chevron.right"
    }

    private func statusColor(_ node: ObservatoryNode) -> Color {
        if node.messageQueueLen == 0 { return .green }
        if node.messageQueueLen <= 10 { return .orange }
        return .red
    }

    private func classColor(_ node: ObservatoryNode) -> Color {
        switch node.processClass {
        case .supervisor: return .blue
        case .buffer: return .cyan
        case .agentSession: return .purple
        case .lsp: return .indigo
        case .service: return .secondary
        case .worker: return theme.treeFg.opacity(0.55)
        }
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "Elixir.", with: "")
    }

    private func reconcileLocalState() {
        let nodeIds = Set(state.nodes.map(\.id))
        expandedNodeIds = expandedNodeIds.intersection(nodeIds)
        if !hasInitializedExpansion {
            expandedNodeIds = Set(state.nodes.filter(\.isSupervisor).map(\.id))
            hasInitializedExpansion = true
        }
        if let selectedNodeId, !nodeIds.contains(selectedNodeId) {
            self.selectedNodeId = nil
        }
        if state.nodes.isEmpty {
            hasInitializedExpansion = false
        }
    }

    private func activateRow(_ node: ObservatoryNode) {
        selectedNodeId = node.id
        dismissInspection()
        if node.isSupervisor {
            toggleExpanded(node.id)
        }
    }

    private func dismissInspection() {
        encoder?.sendObservatoryInspect(pid: "")
    }

    private func toggleExpanded(_ id: String) {
        if expandedNodeIds.contains(id) {
            expandedNodeIds.remove(id)
        } else {
            expandedNodeIds.insert(id)
        }
    }

    private func visibleTreeNodes() -> [ObservatoryNode] {
        state.nodes.filter { node in ancestorsExpanded(node) }
    }

    private func ancestorsExpanded(_ node: ObservatoryNode) -> Bool {
        var parent = node.parentPid
        while !parent.isEmpty {
            guard expandedNodeIds.contains(parent) else { return false }
            parent = state.nodes.first(where: { $0.id == parent })?.parentPid ?? ""
        }
        return true
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }
}

#Preview {
    let state = ObservatoryState()
    state.update(visible: true, rawNodes: [
        Wire.ObservatoryNode(pid: "<0.1.0>", parentPid: "", name: "Minga.Supervisor", processClass: 0, depth: 0, memory: 125_000, messageQueueLen: 0, reductions: 42, sparkline: [0, 0.2, 0.1]),
        Wire.ObservatoryNode(pid: "<0.2.0>", parentPid: "<0.1.0>", name: "Minga.Buffer.Process", processClass: 1, depth: 1, memory: 42_000, messageQueueLen: 2, reductions: 1024, sparkline: [0, 0.4, 0.2])
    ])
    return ObservatoryView(state: state, theme: ThemeColors(), encoder: nil)
}
