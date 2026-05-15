/// Visual row component for the semantic file tree.
///
/// FileTreeView owns list behavior and action wiring. This view owns the row anatomy and visual layers:
/// disclosure, icon, name, spacer, diagnostic marker, dirty marker, git marker, then background/accent layers.

import SwiftUI

struct FileTreeRowView: View {
    let entry: FileTreeEntry
    let theme: ThemeColors
    let rowHeight: CGFloat
    let indentWidth: CGFloat
    let chevronWidth: CGFloat
    let isHovered: Bool
    let isDropTarget: Bool
    let animDuration: Double
    let onEditCommit: (String) -> Void
    let onEditCancel: () -> Void

    var body: some View {
        rowContent
            .padding(.leading, leadingPadding)
            .padding(.trailing, 8)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                activeFileAccent
            }
            .overlay(alignment: .leading) {
                indentGuides
            }
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityHint(accessibilityHintText)
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack(spacing: 0) {
            disclosureChevron

            Text(entry.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(iconColor)
                .frame(width: 16, alignment: .center)

            Spacer().frame(width: 4)

            if entry.isEditing {
                InlineEditField(
                    initialText: entry.editingText,
                    selectStem: entry.editingType == 2,
                    onCommit: onEditCommit,
                    onCancel: onEditCancel
                )
                .frame(height: rowHeight)
            } else {
                Text(entry.name)
                    .font(.system(size: 12, weight: entry.showsActiveAccent ? .semibold : .regular))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                diagnosticMarker
                dirtyMarker
                gitStatusDot
            }
        }
    }

    @ViewBuilder
    private var disclosureChevron: some View {
        if entry.isDir {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.treeFg.opacity(0.5))
                .rotationEffect(.degrees(entry.isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: animDuration), value: entry.isExpanded)
                .frame(width: chevronWidth, height: rowHeight)
        } else {
            Spacer().frame(width: chevronWidth)
        }
    }

    @ViewBuilder
    private var diagnosticMarker: some View {
        if let text = diagnosticMarkerText, let color = diagnosticMarkerColor {
            Text(text)
                .font(.system(size: 9, weight: entry.highestDiagnosticSeverity == .hint ? .medium : .bold))
                .foregroundStyle(color)
                .padding(.trailing, 4)
        }
    }

    private var diagnosticMarkerText: String? {
        guard let severity = entry.highestDiagnosticSeverity else { return nil }
        let base = diagnosticMarkerSymbol(severity)
        let countText = diagnosticMarkerCountText(entry.highestDiagnosticCount)
        return countText.isEmpty ? base : "\(base)\(countText)"
    }

    private func diagnosticMarkerCountText(_ count: UInt16) -> String {
        if count > 9 { return "9+" }
        if count > 1 { return String(count) }
        return ""
    }

    private func diagnosticMarkerSymbol(_ severity: FileTreeDiagnosticSeverity) -> String {
        switch severity {
        case .error: return "✖"
        case .warning: return "⚠"
        case .info: return "ℹ"
        case .hint: return "·"
        }
    }

    private var diagnosticMarkerColor: Color? {
        guard let severity = entry.highestDiagnosticSeverity else { return nil }
        switch severity {
        case .error: return theme.gutterErrorFg
        case .warning: return theme.gutterWarningFg
        case .info: return theme.gutterInfoFg
        case .hint: return theme.gutterHintFg
        }
    }

    @ViewBuilder
    private var dirtyMarker: some View {
        if entry.showsDirtyMarker {
            Text("●")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.treeGitModified)
                .padding(.trailing, entry.showsGitMarker ? 4 : 2)
        }
    }

    @ViewBuilder
    private var gitStatusDot: some View {
        if let color = gitDotColor {
            Circle()
                .fill(color)
                .frame(width: entry.hasConflictStatus ? 7 : 6, height: entry.hasConflictStatus ? 7 : 6)
                .padding(.trailing, 2)
        }
    }

    private var gitDotColor: Color? {
        switch entry.gitStatusValue {
        case .modified: return theme.treeGitModified
        case .staged: return theme.treeGitStaged
        case .untracked: return theme.treeGitUntracked
        case .conflict: return theme.gutterErrorFg
        case .renamed: return theme.treeGitStaged
        case .deleted: return theme.gitDeletedFg
        case .clean: return nil
        }
    }

    @ViewBuilder
    private var indentGuides: some View {
        if !entry.guides.isEmpty {
            Canvas { context, size in
                for (level, shouldDraw) in entry.guides.enumerated() where shouldDraw {
                    let x = 8 + CGFloat(level) * indentWidth + chevronWidth / 2
                    let rect = CGRect(x: x, y: 0, width: 1, height: size.height)
                    context.fill(Path(rect), with: .color(theme.treeGuideFg))
                }
            }
            .allowsHitTesting(false)
            .frame(height: rowHeight)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if entry.isEditing {
            rowFill(theme.treeSelectionBg)
        } else if isDropTarget {
            rowFill(theme.treeSelectionBg.opacity(0.55))
        } else if entry.isSelected {
            rowFill(theme.treeSelectionBg.opacity(entry.isFocused ? 1.0 : 0.42))
        } else if isHovered {
            rowFill(theme.treeFg.opacity(0.06))
                .animation(.easeInOut(duration: animDuration), value: isHovered)
        }
    }

    @ViewBuilder
    private var activeFileAccent: some View {
        if entry.showsActiveAccent {
            RoundedRectangle(cornerRadius: 1)
                .fill(theme.treeActiveFg)
                .frame(width: 2, height: rowHeight - 8)
                .padding(.leading, 4)
        }
    }

    private func rowFill(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .padding(.horizontal, 4)
    }

    private var leadingPadding: CGFloat {
        8 + CGFloat(entry.depth) * indentWidth
    }

    private var iconColor: Color {
        if entry.showsActiveAccent {
            return theme.treeActiveFg
        }
        if entry.isDir {
            return theme.treeDirFg
        }
        return theme.treeFg.opacity(0.7)
    }

    private var nameColor: Color {
        if entry.showsActiveAccent {
            return theme.treeActiveFg
        }
        if entry.isSelected {
            return theme.treeSelectionFg
        }
        return entry.isDir ? theme.treeDirFg : theme.treeFg
    }

    var accessibilityLabelText: String {
        let base: String
        if entry.isEditing {
            base = "Editing: \(entry.name)"
        } else {
            base = entry.isDir ? "Folder: \(entry.name)" : "File: \(entry.name)"
        }

        let statuses = accessibilityStatusText
        return statuses.isEmpty ? base : "\(base), \(statuses)"
    }

    private var accessibilityStatusText: String {
        statusAccessibilityParts.joined(separator: ", ")
    }

    private var statusAccessibilityParts: [String] {
        diagnosticAccessibilityParts + dirtyAccessibilityParts + gitAccessibilityParts
    }

    private var diagnosticAccessibilityParts: [String] {
        guard let severity = entry.highestDiagnosticSeverity else { return [] }
        let count = entry.highestDiagnosticCount
        let label = count == 1 ? diagnosticSingularLabel(severity) : diagnosticPluralLabel(severity)
        return ["\(count) \(label)"]
    }

    private var dirtyAccessibilityParts: [String] {
        entry.showsDirtyMarker ? ["unsaved changes"] : []
    }

    private var gitAccessibilityParts: [String] {
        switch entry.gitStatusValue {
        case .clean: return []
        case .modified: return ["git modified"]
        case .staged: return ["git staged"]
        case .untracked: return ["git untracked"]
        case .conflict: return ["git conflict"]
        case .renamed: return ["git renamed"]
        case .deleted: return ["git deleted"]
        }
    }

    private func diagnosticSingularLabel(_ severity: FileTreeDiagnosticSeverity) -> String {
        switch severity {
        case .error: return "error"
        case .warning: return "warning"
        case .info: return "info diagnostic"
        case .hint: return "hint"
        }
    }

    private func diagnosticPluralLabel(_ severity: FileTreeDiagnosticSeverity) -> String {
        switch severity {
        case .error: return "errors"
        case .warning: return "warnings"
        case .info: return "info diagnostics"
        case .hint: return "hints"
        }
    }

    var accessibilityHintText: String {
        if entry.isEditing {
            return "Type a new name, then press Return to confirm or Escape to cancel."
        }
        if entry.isDir {
            return entry.isExpanded ? "Expanded folder. Press Return to collapse." : "Collapsed folder. Press Return to expand."
        }
        return "Press Return to open."
    }
}
