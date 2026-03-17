/// Custom-drawn file tree sidebar for the hybrid GUI.
///
/// Renders file tree entries as a vertical list with Nerd Font icons,
/// theme colors, git status indicators, and whitespace indentation.
/// No stock SwiftUI List widget. No box-drawing characters.
/// Styled to match Zed's sidebar aesthetic.

import SwiftUI

/// The file tree sidebar rendered on the left side of the window.
struct FileTreeView: View {
    let fileTreeState: FileTreeState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let rowHeight: CGFloat = 22
    private let indentWidth: CGFloat = 16
    private let iconFontSize: CGFloat = 13
    private let nameFontSize: CGFloat = 12.5

    var body: some View {
        VStack(spacing: 0) {
            // Project name header
            projectHeader

            // 1px separator under header
            Rectangle()
                .fill(theme.treeSeparatorFg)
                .frame(height: 1)

            // Scrollable entry list
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(fileTreeState.entries) { entry in
                            fileTreeRow(entry)
                        }
                    }
                }
                .onChange(of: fileTreeState.selectedIndex) { _, newIndex in
                    withAnimation(nil) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: CGFloat(fileTreeState.treeWidth) * 8)
        .background(theme.treeBg)
        .focusable(false)
        .focusEffectDisabled()
    }

    // MARK: - Project header

    @ViewBuilder
    private var projectHeader: some View {
        HStack(spacing: 6) {
            Text("\u{F024B}")
                .font(.custom("Symbols Nerd Font Mono", size: iconFontSize))
                .foregroundStyle(theme.treeHeaderFg)

            Text(projectName)
                .font(.system(size: nameFontSize, weight: .semibold))
                .foregroundStyle(theme.treeHeaderFg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(theme.treeHeaderBg)
    }

    private var projectName: String {
        // Extract project name from the first entry's path or use "Project"
        if let first = fileTreeState.entries.first {
            // The root is depth 0; its name is the project folder
            if first.depth == 0 && first.isDir {
                return first.name
            }
        }
        return "Project"
    }

    // MARK: - Entry row

    @ViewBuilder
    private func fileTreeRow(_ entry: FileTreeEntry) -> some View {
        HStack(spacing: 5) {
            // Nerd Font icon
            Text(entry.icon)
                .font(.custom("Symbols Nerd Font Mono", size: iconFontSize))
                .foregroundStyle(iconColor(entry))
                .frame(width: 18, alignment: .center)

            // File/directory name
            Text(entry.name)
                .font(.system(size: nameFontSize))
                .foregroundStyle(nameColor(entry))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Git status dot
            if entry.gitStatus > 0 {
                Circle()
                    .fill(gitStatusColor(entry.gitStatus))
                    .frame(width: 5, height: 5)
                    .padding(.trailing, 6)
            }
        }
        .padding(.leading, CGFloat(entry.depth) * indentWidth + 8)
        .padding(.trailing, 4)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(entry.isSelected ? theme.treeSelectionBg : Color.clear)
        .id(entry.id)
        .onTapGesture(count: 2) {
            // Double-click: open file or toggle directory
            (encoder as? ProtocolEncoder)?.sendFileTreeClick(index: UInt16(entry.id))
        }
        .onTapGesture {
            // Single click: select entry
            (encoder as? ProtocolEncoder)?.sendFileTreeClick(index: UInt16(entry.id))
        }
    }

    // MARK: - Colors

    private func iconColor(_ entry: FileTreeEntry) -> Color {
        if entry.isDir {
            return theme.treeDirFg
        }
        return theme.treeFg
    }

    private func nameColor(_ entry: FileTreeEntry) -> Color {
        if entry.isSelected {
            return theme.treeSelectionFg
        }
        switch entry.gitStatus {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        default: return entry.isDir ? theme.treeDirFg : theme.treeFg
        }
    }

    private func gitStatusColor(_ status: UInt8) -> Color {
        switch status {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        default: return theme.treeFg
        }
    }
}
