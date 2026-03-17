/// Custom-drawn file tree sidebar matching Zed's visual style.
///
/// Dense, clean rows with Nerd Font icons, whitespace indentation,
/// and git status color tints. No box-drawing characters, no stock
/// List widget. Styled for tight vertical rhythm.

import SwiftUI

/// The file tree sidebar rendered on the left side of the window.
struct FileTreeView: View {
    let fileTreeState: FileTreeState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let rowHeight: CGFloat = 22
    private let indentWidth: CGFloat = 14
    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 360

    @State private var sidebarWidth: CGFloat = 240
    @State private var isDraggingResize: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                projectHeader
                entryList
            }
            .frame(width: sidebarWidth)
            .background(theme.treeBg)
            .focusable(false)
            .focusEffectDisabled()
            .onAppear {
                sidebarWidth = CGFloat(fileTreeState.treeWidth) * 7.5
            }

            // Resize handle (drag to resize sidebar)
            Rectangle()
                .fill(isDraggingResize ? theme.treeActiveFg.opacity(0.5) : Color.clear)
                .frame(width: 4)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            isDraggingResize = true
                            let newWidth = sidebarWidth + value.translation.width
                            sidebarWidth = min(max(newWidth, sidebarMinWidth), sidebarMaxWidth)
                        }
                        .onEnded { _ in
                            isDraggingResize = false
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    // MARK: - Project header

    @ViewBuilder
    private var projectHeader: some View {
        HStack(spacing: 6) {
            // Folder icon
            Text("\u{F024B}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg)

            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.treeHeaderFg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.treeBg)
    }

    private var projectName: String {
        if let first = fileTreeState.entries.first, first.depth == 0, first.isDir {
            return first.name
        }
        return "Project"
    }

    // MARK: - Entry list

    @ViewBuilder
    private var entryList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(fileTreeState.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.top, 2)
            }
            .onChange(of: fileTreeState.selectedIndex) { _, newIndex in
                withAnimation(nil) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - Entry row

    @ViewBuilder
    private func entryRow(_ entry: FileTreeEntry) -> some View {
        HStack(spacing: 4) {
            // Nerd Font icon
            Text(entry.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(iconColor(entry))
                .frame(width: 16, alignment: .center)

            // Name
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(nameColor(entry))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingPadding(entry))
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selectionBackground(entry))
        .id(entry.id)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            (encoder as? ProtocolEncoder)?.sendFileTreeClick(index: UInt16(entry.id))
        }
        .onTapGesture {
            (encoder as? ProtocolEncoder)?.sendFileTreeClick(index: UInt16(entry.id))
        }
    }

    // MARK: - Layout helpers

    private func leadingPadding(_ entry: FileTreeEntry) -> CGFloat {
        // Base padding + depth indentation
        8 + CGFloat(entry.depth) * indentWidth
    }

    @ViewBuilder
    private func selectionBackground(_ entry: FileTreeEntry) -> some View {
        if entry.isSelected {
            // Subtle rounded selection background, like Zed
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.treeSelectionBg.opacity(0.6))
                .padding(.horizontal, 4)
        } else {
            Color.clear
        }
    }

    // MARK: - Colors

    private func iconColor(_ entry: FileTreeEntry) -> Color {
        if entry.isDir {
            return theme.treeDirFg
        }
        // Git status tints the icon too
        switch entry.gitStatus {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        default: return theme.treeFg.opacity(0.7)
        }
    }

    private func nameColor(_ entry: FileTreeEntry) -> Color {
        if entry.isSelected {
            return theme.treeActiveFg
        }
        // Git status colors on the name
        switch entry.gitStatus {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        default:
            return entry.isDir ? theme.treeDirFg : theme.treeFg
        }
    }
}
