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

    /// Chevron/hover animation duration. Respects reduced motion.
    private var animDuration: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
    }

    @State private var hoveredEntryId: UInt32? = nil
    @State private var scrollOffset: CGFloat = 0
    @State private var dropTargetEntryId: UInt32? = nil
    @State private var lastClickEntryId: UInt32? = nil
    @State private var lastClickTime: Date? = nil

    var body: some View {
        VStack(spacing: 0) {
            entryList
        }
        .focusable(false)
        .focusEffectDisabled()
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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ScrollOffsetKey.self,
                            value: geo.frame(in: .named("fileTreeScroll")).minY
                        )
                    }
                )
            }
            .coordinateSpace(name: "fileTreeScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { value in
                scrollOffset = value
            }
            .overlay(alignment: .top) {
                stickyParentHeader
            }
            .onChange(of: fileTreeState.selectedIndex) { _, newIndex in
                if let selectedEntry = fileTreeState.entries.first(where: { $0.index == newIndex }) {
                    withAnimation(nil) {
                        proxy.scrollTo(selectedEntry.id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Sticky parent header

    /// The parent directory chain for the top visible entry, pinned at the
    /// top of the scroll view. Only shows when the user has scrolled past
    /// a directory's own row so you always know where you are in the tree.
    @ViewBuilder
    private var stickyParentHeader: some View {
        let parents = stickyParentEntries()
        if !parents.isEmpty {
            VStack(spacing: 0) {
                ForEach(parents) { parent in
                    HStack(spacing: 0) {
                        // Match the indent of the actual entry row
                        disclosureChevron(parent)

                        Text(parent.icon)
                            .font(.custom("Symbols Nerd Font Mono", size: 12))
                            .foregroundStyle(theme.treeDirFg)
                            .frame(width: 16, alignment: .center)

                        Spacer().frame(width: 4)

                        Text(parent.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.treeDirFg)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)
                    }
                    .padding(.leading, leadingPadding(parent))
                    .padding(.trailing, 8)
                    .frame(height: rowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.treeBg)
                }

                // Subtle bottom separator
                Rectangle()
                    .fill(theme.treeSeparatorFg.opacity(0.3))
                    .frame(height: 1)
            }
        }
    }

    /// Computes the parent directory entries that should be pinned at the top.
    /// Returns directories whose rows have scrolled off the top, ordered by depth.
    private func stickyParentEntries() -> [FileTreeEntry] {
        let entries = fileTreeState.entries
        guard !entries.isEmpty else { return [] }

        // The 2px top padding shifts the content down. scrollOffset is negative
        // when scrolled down (content moves up).
        let adjustedOffset = -(scrollOffset - 2)
        guard adjustedOffset > 0 else { return [] }

        let topIndex = min(Int(adjustedOffset / rowHeight), entries.count - 1)
        let topEntry = entries[topIndex]

        // Only show sticky headers when the top visible entry is nested
        guard topEntry.depth > 0 else { return [] }

        // Walk backwards from topIndex to find the parent directory at each
        // depth level that has scrolled off screen.
        var parents: [FileTreeEntry] = []
        var neededDepths = Set(0..<topEntry.depth)

        for i in stride(from: topIndex, through: 0, by: -1) {
            let entry = entries[i]
            if entry.isDir && neededDepths.contains(entry.depth) {
                parents.append(entry)
                neededDepths.remove(entry.depth)
                if neededDepths.isEmpty { break }
            }
        }

        // Sort by depth so they stack correctly (shallowest on top)
        return parents.sorted { $0.depth < $1.depth }
    }

    // MARK: - Entry row

    @ViewBuilder
    private func entryRow(_ entry: FileTreeEntry) -> some View {
        if entry.isEditing {
            fileTreeRow(entry)
                .id(entry.id)
        } else {
            fileTreeRow(entry)
                .id(entry.id)
                .contentShape(Rectangle())
                .onHover { isHovered in
                    hoveredEntryId = isHovered ? entry.id : nil
                    if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                .onTapGesture {
                    handleEntryTap(entry)
                }
                .contextMenu { entryContextMenu(entry) }
                .draggable(URL(fileURLWithPath: fileTreeState.fullPath(for: entry))) {
                    HStack(spacing: 4) {
                        Text(entry.icon)
                            .font(.system(size: 12))
                        Text(entry.name)
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.popupBg, in: RoundedRectangle(cornerRadius: 4))
                }
                .dropDestination(for: URL.self) { urls, _ in
                    handleDrop(urls: urls, onto: entry)
                } isTargeted: { isTargeted in
                    dropTargetEntryId = isTargeted && entry.isDir ? entry.id : nil
                }
        }
    }

    private func fileTreeRow(_ entry: FileTreeEntry) -> FileTreeRowView {
        FileTreeRowView(
            entry: entry,
            theme: theme,
            rowHeight: rowHeight,
            indentWidth: indentWidth,
            chevronWidth: chevronWidth,
            isHovered: hoveredEntryId == entry.id,
            isDropTarget: dropTargetEntryId == entry.id,
            animDuration: animDuration,
            onEditCommit: { text in
                encoder?.sendFileTreeEditConfirm(text: text)
            },
            onEditCancel: {
                encoder?.sendFileTreeEditCancel()
            }
        )
    }

    // MARK: - Context menu

    @ViewBuilder
    private func entryContextMenu(_ entry: FileTreeEntry) -> some View {
        if !entry.isDir {
            Button("Open") {
                encoder?.sendFileTreeClick(index: UInt16(entry.index))
            }
            Button("Open in Split") {
                encoder?.sendFileTreeOpenInSplit(index: UInt16(entry.index))
            }
            Divider()
        }

        if entry.isDir {
            Button("New File…") {
                encoder?.sendFileTreeNewFile(parentIndex: UInt16(entry.index))
            }
            Button("New Folder…") {
                encoder?.sendFileTreeNewFolder(parentIndex: UInt16(entry.index))
            }
            Divider()
        }

        Button("Rename") {
            encoder?.sendFileTreeRename(index: UInt16(entry.index))
        }
        Button("Duplicate") {
            encoder?.sendFileTreeDuplicate(index: UInt16(entry.index))
        }

        Divider()

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
        Button("Open in Terminal") {
            let path = fileTreeState.fullPath(for: entry)
            let dirPath = entry.isDir ? path : (path as NSString).deletingLastPathComponent
            let dirURL = URL(fileURLWithPath: dirPath)
            NSWorkspace.shared.open(
                [dirURL],
                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }

        Divider()

        Button(role: .destructive) {
            encoder?.sendFileTreeDelete(index: UInt16(entry.index))
        } label: {
            Text("Move to Trash")
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Click handling

    /// Handles single and double-click without SwiftUI's 300ms delay.
    /// Uses a 250ms window to detect double-clicks internally.
    private func handleEntryTap(_ entry: FileTreeEntry) {
        let now = Date()
        let timeSinceLastClick = lastClickTime.map { now.timeIntervalSince($0) } ?? .infinity
        let isDoubleClick = lastClickEntryId == entry.id && timeSinceLastClick < 0.25

        if isDoubleClick {
            // Double-click: always open (files open permanently)
            encoder?.sendFileTreeClick(index: UInt16(entry.index))
            lastClickEntryId = nil
            lastClickTime = nil
        } else {
            // Single-click: toggle directories, select/preview files
            if entry.isDir {
                encoder?.sendFileTreeToggle(index: UInt16(entry.index))
            } else {
                encoder?.sendFileTreeClick(index: UInt16(entry.index))
            }
            lastClickEntryId = entry.id
            lastClickTime = now
        }
    }

    // MARK: - Drop handling

    /// Handles a drop of URLs onto a tree entry.
    /// Internal moves (within the project) are sent to the BEAM as move operations.
    /// External files (from Finder) are copied into the target directory.
    private func handleDrop(urls: [URL], onto entry: FileTreeEntry) -> Bool {
        let targetDir: String
        if entry.isDir {
            targetDir = fileTreeState.fullPath(for: entry)
        } else {
            targetDir = (fileTreeState.fullPath(for: entry) as NSString).deletingLastPathComponent
        }

        let projectRoot = fileTreeState.projectRoot
        var handledAny = false

        for url in urls {
            let sourcePath = url.path
            let isInternal = sourcePath.hasPrefix(projectRoot)

            if isInternal {
                // Internal move: find the source entry index and send move to BEAM
                if let sourceEntry = fileTreeState.entries.first(where: {
                    fileTreeState.fullPath(for: $0) == sourcePath
                }) {
                    encoder?.sendFileTreeMove(
                        sourceIndex: UInt16(sourceEntry.index),
                        targetDirIndex: UInt16(entry.index)
                    )
                    handledAny = true
                }
            } else {
                // External file: copy into target directory
                let destPath = (targetDir as NSString).appendingPathComponent(url.lastPathComponent)
                let destURL = URL(fileURLWithPath: destPath)
                do {
                    try FileManager.default.copyItem(at: url, to: destURL)
                    handledAny = true
                } catch {
                    encoder?.sendLog(level: 3, message: "Drop copy failed: \(error.localizedDescription)")
                }
            }
        }

        if handledAny {
            // Refresh tree after external copies
            encoder?.sendFileTreeRefresh()
        }

        return handledAny
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

    // MARK: - Layout helpers

    private func leadingPadding(_ entry: FileTreeEntry) -> CGFloat {
        8 + CGFloat(entry.depth) * indentWidth
    }

}

/// Preference key for tracking scroll offset within the file tree.
private struct ScrollOffsetKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
