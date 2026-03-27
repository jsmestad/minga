import SwiftUI

/// Change summary sidebar showing files touched by an agent with diff stats.
///
/// Displays a list of changed files grouped by status (modified, added, deleted).
/// Each entry shows a file icon (based on extension), relative path, diff stats
/// (+N in green, -M in red), and a status indicator (M/A/D/R).
///
/// The selected file is highlighted. Clicking a file sends a `change_summary_click`
/// gui_action to the BEAM, which opens the file and activates diff view.
struct ChangeSummaryView: View {
    let state: ChangeSummaryState
    let theme: ThemeColors
    let encoder: InputEncoder?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Changes")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.treeFg)
                Spacer()
                Text("\(state.entries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.treeBg)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.treeSeparatorFg.opacity(0.3))
                    .frame(height: 1)
            }

            // File list
            ScrollView {
                VStack(spacing: 0) {
                    if state.entries.isEmpty {
                        emptyState
                    } else {
                        // Group by status: modified first, then added, then deleted
                        let grouped = Dictionary(grouping: state.entries) { $0.action }
                        let statusOrder: [ChangeSummaryEntry.FileAction] = [.modified, .added, .deleted, .renamed]

                        ForEach(statusOrder, id: \.self) { action in
                            if let entries = grouped[action], !entries.isEmpty {
                                statusSection(action: action, entries: entries)
                            }
                        }
                    }
                }
            }
            .background(theme.treeBg)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No changes yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Status Section

    @ViewBuilder
    private func statusSection(action: ChangeSummaryEntry.FileAction, entries: [ChangeSummaryEntry]) -> some View {
        // Section header
        HStack(spacing: 4) {
            Text(sectionTitle(for: action))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)

        // File entries
        ForEach(entries) { entry in
            fileEntryView(entry: entry)
        }
    }

    private func sectionTitle(for action: ChangeSummaryEntry.FileAction) -> String {
        switch action {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }

    // MARK: - File Entry

    @State private var hoveredEntryId: Int? = nil

    @ViewBuilder
    private func fileEntryView(entry: ChangeSummaryEntry) -> some View {
        let isSelected = entry.id == state.selectedIndex
        let isHovered = hoveredEntryId == entry.id

        HStack(spacing: 8) {
            // Status indicator
            Text(entry.action.indicator)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor(entry.action))
                .frame(width: 14)

            // File icon (SF Symbol based on extension)
            Image(systemName: fileIcon(for: entry.path))
                .font(.system(size: 12))
                .foregroundStyle(fileIconColor(for: entry.path))
                .frame(width: 16)

            // File path
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName(from: entry.path))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.treeFg)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let dir = directoryPath(from: entry.path) {
                    Text(dir)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            // Diff stats
            HStack(spacing: 4) {
                if entry.linesAdded > 0 {
                    Text("+\(entry.linesAdded)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.4))
                }
                if entry.linesRemoved > 0 {
                    Text("-\(entry.linesRemoved)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.3, blue: 0.3))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? theme.treeSelectionBg
                : isHovered
                    ? Color.blend(theme.treeBg, with: .white, amount: 0.08)
                    : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredEntryId = hovering ? entry.id : nil
        }
        .onTapGesture {
            encoder?.sendChangeSummaryClick(index: UInt32(entry.id))
        }
    }

    private func statusColor(_ action: ChangeSummaryEntry.FileAction) -> Color {
        let c = action.color
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: - File Path Helpers

    /// Extracts the file name from a path.
    private func fileName(from path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Extracts the directory path from a path, or nil if it's a top-level file.
    private func directoryPath(from path: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? nil : dir
    }

    /// Returns an SF Symbol name for the given file extension.
    private func fileIcon(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ex", "exs": return "chevron.left.forwardslash.chevron.right"
        case "swift": return "swift"
        case "zig": return "z.square"
        case "rs": return "r.square"
        case "py": return "p.square"
        case "js", "ts", "jsx", "tsx": return "j.square"
        case "go": return "g.square"
        case "rb": return "r.square.fill"
        case "md": return "doc.text"
        case "json": return "curlybraces"
        case "yml", "yaml": return "list.bullet.indent"
        case "toml": return "text.alignleft"
        default: return "doc"
        }
    }

    /// Returns a color for the file icon based on extension.
    private func fileIconColor(for path: String) -> Color {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ex", "exs": return Color(red: 0.6, green: 0.4, blue: 0.8)
        case "swift": return Color(red: 1.0, green: 0.45, blue: 0.2)
        case "zig": return Color(red: 0.95, green: 0.75, blue: 0.3)
        case "py": return Color(red: 0.3, green: 0.6, blue: 0.85)
        case "js", "ts", "jsx", "tsx": return Color(red: 0.95, green: 0.8, blue: 0.2)
        default: return .secondary
        }
    }
}

// MARK: - Color Blending Extension

private extension Color {
    /// Blends two colors by the given amount (0 = all base, 1 = all target).
    /// Uses NSColor component interpolation for true color mixing.
    static func blend(_ base: Color, with target: Color, amount: Double) -> Color {
        let nsBase = NSColor(base).usingColorSpace(.sRGB) ?? NSColor(base)
        let nsTarget = NSColor(target).usingColorSpace(.sRGB) ?? NSColor(target)
        let t = max(0, min(1, amount))

        let r = nsBase.redComponent * (1 - t) + nsTarget.redComponent * t
        let g = nsBase.greenComponent * (1 - t) + nsTarget.greenComponent * t
        let b = nsBase.blueComponent * (1 - t) + nsTarget.blueComponent * t
        let a = nsBase.alphaComponent * (1 - t) + nsTarget.alphaComponent * t

        return Color(nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: a))
    }
}
