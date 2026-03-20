/// Custom-drawn file tree sidebar matching Zed's visual style.
///
/// Dense, clean rows with Nerd Font icons, disclosure chevrons,
/// indent guides, hover highlights, and git status color tints.
/// No box-drawing characters, no stock List widget. Styled for
/// tight vertical rhythm with native macOS feel.

import SwiftUI

/// The file tree sidebar rendered on the left side of the window.
struct FileTreeView: View {
    let fileTreeState: FileTreeState
    let theme: ThemeColors
    let encoder: InputEncoder?

    private let rowHeight: CGFloat = 22
    private let indentWidth: CGFloat = 14
    private let chevronWidth: CGFloat = 12
    private let sidebarMinWidth: CGFloat = 180
    private let sidebarMaxWidth: CGFloat = 360

    /// Chevron/hover animation duration. Respects reduced motion.
    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    @State private var sidebarWidth: CGFloat = 240
    @State private var isDraggingResize: Bool = false
    @State private var hoveredEntryId: UInt32? = nil

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

            resizeHandle
        }
    }

    // MARK: - Resize handle

    /// 8px hit target with a 1px visible separator line.
    @ViewBuilder
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isDraggingResize ? theme.treeActiveFg.opacity(0.3) : theme.treeSeparatorFg.opacity(0.4))
                    .frame(width: 1)
            }
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

    // MARK: - Project header

    @ViewBuilder
    private var projectHeader: some View {
        HStack(spacing: 6) {
            Text("\u{F024B}")
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(theme.treeDirFg)

            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.treeHeaderFg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            headerActions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.treeBg)
    }

    // MARK: - Header action icons

    /// Small icon buttons in the project header (New File, New Folder, Refresh, Collapse All).
    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 2) {
            headerButton(systemName: "doc.badge.plus", tooltip: "New File…") {
                encoder?.sendFileTreeNewFile()
            }
            headerButton(systemName: "folder.badge.plus", tooltip: "New Folder…") {
                encoder?.sendFileTreeNewFolder()
            }
            headerButton(systemName: "arrow.clockwise", tooltip: "Refresh") {
                encoder?.sendFileTreeRefresh()
            }
            headerButton(systemName: "arrow.down.right.and.arrow.up.left", tooltip: "Collapse All") {
                encoder?.sendFileTreeCollapseAll()
            }
        }
    }

    @ViewBuilder
    private func headerButton(systemName: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
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
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(fileTreeState.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.top, 2)
            }
            .onChange(of: fileTreeState.selectedIndex) { _, newIndex in
                // Look up the stable ID of the selected entry to scroll to it.
                if let selectedEntry = fileTreeState.entries.first(where: { $0.index == newIndex }) {
                    withAnimation(nil) {
                        proxy.scrollTo(selectedEntry.id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Entry row

    @ViewBuilder
    private func entryRow(_ entry: FileTreeEntry) -> some View {
        HStack(spacing: 0) {
            // Disclosure chevron (directories) or alignment spacer (files)
            disclosureChevron(entry)

            // Nerd Font icon
            Text(entry.icon)
                .font(.custom("Symbols Nerd Font Mono", size: 12))
                .foregroundStyle(iconColor(entry))
                .frame(width: 16, alignment: .center)

            Spacer().frame(width: 4)

            // Name
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(nameColor(entry))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            // Git status dot
            gitStatusDot(entry)
        }
        .padding(.leading, leadingPadding(entry))
        .padding(.trailing, 8)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(entry))
        .overlay(alignment: .leading) {
            indentGuides(entry)
        }
        .id(entry.id)
        .contentShape(Rectangle())
        .onHover { isHovered in
            hoveredEntryId = isHovered ? entry.id : nil
        }
        .onTapGesture(count: 2) {
            // Double-click: always open (files open permanently)
            encoder?.sendFileTreeClick(index: UInt16(entry.index))
        }
        .onTapGesture {
            // Single-click: toggle directories, select/preview files
            if entry.isDir {
                encoder?.sendFileTreeToggle(index: UInt16(entry.index))
            } else {
                encoder?.sendFileTreeClick(index: UInt16(entry.index))
            }
        }
        .contextMenu { entryContextMenu(entry) }
        .accessibilityLabel(entry.isDir ? "Folder: \(entry.name)" : "File: \(entry.name)")
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryContextMenu(_ entry: FileTreeEntry) -> some View {
        if entry.isDir {
            Button("New File…") {
                encoder?.sendFileTreeNewFile()
            }
            Button("New Folder…") {
                encoder?.sendFileTreeNewFolder()
            }
            Divider()
        }

        Button("Copy Path") {
            copyToClipboard(fileTreeState.fullPath(for: entry))
        }
        Button("Copy Relative Path") {
            copyToClipboard(entry.relPath)
        }
        Divider()
        Button("Reveal in Finder") {
            let path = fileTreeState.fullPath(for: entry)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Disclosure chevron

    @ViewBuilder
    private func disclosureChevron(_ entry: FileTreeEntry) -> some View {
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

    // MARK: - Indent guides

    // MARK: - Git status dot

    /// Small colored dot indicating git status, right-aligned in the row.
    @ViewBuilder
    private func gitStatusDot(_ entry: FileTreeEntry) -> some View {
        if let color = gitDotColor(entry) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.trailing, 2)
        }
    }

    private func gitDotColor(_ entry: FileTreeEntry) -> Color? {
        switch entry.gitStatus {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        case 4: return theme.gutterErrorFg  // conflict
        default: return nil
        }
    }

    /// Draws thin vertical indent guide lines using a lightweight Canvas.
    @ViewBuilder
    private func indentGuides(_ entry: FileTreeEntry) -> some View {
        if entry.depth > 0 {
            Canvas { context, size in
                for level in 0..<entry.depth {
                    // Align guide with the center of each ancestor's chevron column
                    let x = 8 + CGFloat(level) * indentWidth + chevronWidth / 2
                    let rect = CGRect(x: x, y: 0, width: 1, height: size.height)
                    context.fill(Path(rect), with: .color(theme.treeGuideFg))
                }
            }
            .allowsHitTesting(false)
            .frame(height: rowHeight)
        }
    }

    // MARK: - Row background (selection + hover)

    @ViewBuilder
    private func rowBackground(_ entry: FileTreeEntry) -> some View {
        if entry.isSelected {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.treeSelectionBg)
                .padding(.horizontal, 4)
        } else if hoveredEntryId == entry.id {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.treeFg.opacity(0.06))
                .padding(.horizontal, 4)
                .animation(.easeInOut(duration: animDuration), value: hoveredEntryId)
        } else {
            Color.clear
        }
    }

    // MARK: - Layout helpers

    private func leadingPadding(_ entry: FileTreeEntry) -> CGFloat {
        8 + CGFloat(entry.depth) * indentWidth
    }

    // MARK: - Colors

    private func iconColor(_ entry: FileTreeEntry) -> Color {
        if entry.isDir {
            return theme.treeDirFg
        }
        switch entry.gitStatus {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        default: return theme.treeFg.opacity(0.7)
        }
    }

    private func nameColor(_ entry: FileTreeEntry) -> Color {
        if entry.isSelected {
            return theme.treeSelectionFg
        }
        switch entry.gitStatus {
        case 1: return theme.treeGitModified
        case 2: return theme.treeGitStaged
        case 3: return theme.treeGitUntracked
        default:
            return entry.isDir ? theme.treeDirFg : theme.treeFg
        }
    }
}
