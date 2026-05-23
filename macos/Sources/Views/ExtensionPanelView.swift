import SwiftUI

/// Renders an extension panel's structured content blocks with native SwiftUI widgets.
struct ExtensionPanelView: View {
    let panel: Wire.ExtensionPanelEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !panel.title.isEmpty {
                Text(panel.title)
                    .font(.headline)
                    .padding(.bottom, 4)
            }

            ForEach(Array(panel.blocks.enumerated()), id: \.offset) { _, block in
                contentBlockView(block)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func contentBlockView(_ block: Wire.PanelContentBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))

        case .styledText(let runs):
            HStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    Text(run.text)
                        .foregroundStyle(Color(
                            red: Double(run.r) / 255.0,
                            green: Double(run.g) / 255.0,
                            blue: Double(run.b) / 255.0
                        ))
                        .bold(run.bold)
                        .italic(run.italic)
                }
            }
            .font(.system(.body, design: .monospaced))

        case .table(let columns, let rows, let selected):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(columns, id: \.self) { col in
                        Text(col)
                            .font(.system(.caption, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                    }
                }
                .background(Color.primary.opacity(0.05))

                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                        }
                    }
                    .background(rowIdx == Int(selected) ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))

        case .keyValue(let pairs):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text(pair.key)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(pair.value)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

        case .separator:
            Divider()

        case .progress(let label, let percent):
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                ProgressView(value: Double(percent))
            }

        case .tree(let nodes):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                    treeNodeView(node, depth: 0)
                }
            }

        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func treeNodeView(_ node: Wire.PanelTreeNode, depth: Int) -> some View {
        HStack(spacing: 4) {
            if !node.children.isEmpty {
                Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text(node.label)
                .font(.system(.body, design: .monospaced))
        }
        .padding(.leading, CGFloat(depth) * 16)

        if node.expanded {
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                treeNodeView(child, depth: depth + 1)
            }
        }
    }
}
