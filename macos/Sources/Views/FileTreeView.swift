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

    /// PreviewHost can force eager layout for isolated component snapshots, but full-shell previews keep the production LazyVStack path.
    private var usesPreviewEagerLayout: Bool {
        PreviewSnapshotPolicy.shouldUseEagerLayout(for: "FileTreeView")
    }

    @State private var scrollOffset: CGFloat = 0
    @State private var dropTargetEntryId: String? = nil
    @State private var lastClickEntryId: String? = nil
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
        if fileTreeState.entries.isEmpty && fileTreeState.treeState != .ready {
            stateContent
        } else if usesPreviewEagerLayout {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(fileTreeState.entries) { entry in
                        entryRow(entry)
                    }
                }
                .padding(.top, 2)
            }
        } else {
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
                .safeAreaInset(edge: .top, spacing: 0) {
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
    }

    @ViewBuilder
    private var stateContent: some View {
        VStack(spacing: 10) {
            switch fileTreeState.treeState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                stateText(title: "Loading files…", subtitle: "Scanning the project tree.")
            case .empty:
                stateText(title: "No files yet", subtitle: "Create a file or refresh after adding project files.")
                Button("New File…") {
                    encoder?.sendFileTreeNewFile(parentIndex: UInt16(fileTreeState.selectedIndex))
                }
                .buttonStyle(.borderless)
                Button("Refresh") {
                    encoder?.sendFileTreeRefresh()
                }
                .buttonStyle(.borderless)
            case .error:
                stateText(title: "Couldn’t load file tree", subtitle: fileTreeState.errorReason.isEmpty ? "Check project permissions, then refresh." : fileTreeState.errorReason)
                Button("Refresh") {
                    encoder?.sendFileTreeRefresh()
                }
                .buttonStyle(.borderless)
            case .hidden, .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(20)
        .background(theme.treeBg)
    }

    private func stateText(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.treeDirFg)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg.opacity(0.65))
                .multilineTextAlignment(.center)
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
            .background(theme.treeBg)
            .zIndex(1)
            .allowsHitTesting(false)
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
            fileTreeRow(entry, onActivate: {})
                .id(entry.id)
        } else {
            fileTreeRow(entry, onActivate: { activateEntry(id: entry.id) })
                .id(entry.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    activateEntry(id: entry.id)
                }
                .modifier(
                    FileTreeEntryAccessibilityActions(
                        entry: entry,
                        encoder: encoder,
                        resolveEntry: { fileTreeState.entry(withID: $0) }
                    )
                )
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
                    dropTargetEntryId = isTargeted ? entry.id : nil
                }
        }
    }

    private func fileTreeRow(_ entry: FileTreeEntry, onActivate: @escaping () -> Void) -> FileTreeRowView {
        FileTreeRowView(
            entry: entry,
            theme: theme,
            rowHeight: rowHeight,
            indentWidth: indentWidth,
            chevronWidth: chevronWidth,
            isHovered: false,
            isDropTarget: dropTargetEntryId == entry.id,
            animDuration: animDuration,
            onActivate: onActivate,
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
        let entryId = entry.id

        if !entry.isDir {
            Button("Open") {
                withCurrentEntry(entryId) { entry in
                    encoder?.sendFileTreeClick(index: UInt16(entry.index))
                }
            }
            Button("Open in Split") {
                withCurrentEntry(entryId) { entry in
                    encoder?.sendFileTreeOpenInSplit(index: UInt16(entry.index))
                }
            }
            Divider()
        }

        if entry.isDir {
            Button("New File…") {
                withCurrentEntry(entryId) { entry in
                    encoder?.sendFileTreeNewFile(parentIndex: UInt16(entry.index))
                }
            }
            Button("New Folder…") {
                withCurrentEntry(entryId) { entry in
                    encoder?.sendFileTreeNewFolder(parentIndex: UInt16(entry.index))
                }
            }
            Divider()
        }

        Button("Rename") {
            withCurrentEntry(entryId) { entry in
                encoder?.sendFileTreeRename(index: UInt16(entry.index))
            }
        }
        Button("Duplicate") {
            withCurrentEntry(entryId) { entry in
                encoder?.sendFileTreeDuplicate(index: UInt16(entry.index))
            }
        }

        Divider()

        Button("Copy Path") {
            withCurrentEntry(entryId) { entry in
                copyToClipboard(fileTreeState.fullPath(for: entry))
            }
        }
        Button("Copy Relative Path") {
            withCurrentEntry(entryId) { entry in
                copyToClipboard(entry.relPath)
            }
        }

        Divider()

        Button("Reveal in Finder") {
            withCurrentEntry(entryId) { entry in
                let path = fileTreeState.fullPath(for: entry)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        Button("Open in Terminal") {
            withCurrentEntry(entryId) { entry in
                let path = fileTreeState.fullPath(for: entry)
                let dirPath = entry.isDir ? path : (path as NSString).deletingLastPathComponent
                let dirURL = URL(fileURLWithPath: dirPath)
                NSWorkspace.shared.open(
                    [dirURL],
                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                    configuration: NSWorkspace.OpenConfiguration()
                )
            }
        }

        Divider()

        Button(role: .destructive) {
            withCurrentEntry(entryId) { entry in
                encoder?.sendFileTreeDelete(index: UInt16(entry.index))
            }
        } label: {
            Text("Move to Trash")
        }
    }

    private func withCurrentEntry(_ id: String, perform: (FileTreeEntry) -> Void) {
        guard let entry = fileTreeState.entry(withID: id) else { return }
        perform(entry)
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Click handling

    /// Handles single and double-click without SwiftUI's 300ms delay.
    /// Uses the user's system double-click interval.
    private func handleEntryTap(_ entry: FileTreeEntry) {
        let now = Date()
        let timeSinceLastClick = lastClickTime.map { now.timeIntervalSince($0) } ?? .infinity
        let isDoubleClick = lastClickEntryId == entry.id && timeSinceLastClick < NSEvent.doubleClickInterval

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

    private func activateEntry(id: String) {
        guard let entry = fileTreeState.entry(withID: id) else { return }
        handleEntryTap(entry)
    }

    // MARK: - Drop handling

    /// Handles a drop of URLs onto a tree entry by sending intent to the BEAM.
    /// The BEAM validates stale targets, resolves file targets to their parent directory, and performs filesystem work.
    func handleDrop(urls: [URL], onto entry: FileTreeEntry) -> Bool {
        let sourcePaths = urls.map(\.path).filter { !$0.isEmpty }
        guard !sourcePaths.isEmpty else { return false }
        guard let encoder else { return false }

        encoder.sendFileTreeDrop(
            sourcePaths: sourcePaths,
            targetIndex: UInt16(entry.index),
            targetId: entry.id,
            targetPathHash: entry.pathHash,
            targetPath: fileTreeState.fullPath(for: entry),
            targetIsDir: entry.isDir,
            modifiers: currentModifierBits()
        )

        return true
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
        8 + depthOffset(for: entry.depth)
    }

    private func depthOffset(for depth: Int) -> CGFloat {
        let fullIndentDepth = min(depth, 4)
        let compactIndentDepth = max(depth - 4, 0)
        return CGFloat(fullIndentDepth) * indentWidth + CGFloat(compactIndentDepth) * indentWidth * 0.55
    }

    private func currentModifierBits() -> UInt8 {
        var mods: UInt8 = 0
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) { mods |= 0x01 }
        if flags.contains(.control) { mods |= 0x02 }
        if flags.contains(.option) { mods |= 0x04 }
        if flags.contains(.command) { mods |= 0x08 }
        return mods
    }

}

private struct FileTreeEntryAccessibilityActions: ViewModifier {
    let entry: FileTreeEntry
    let encoder: InputEncoder?
    let resolveEntry: (String) -> FileTreeEntry?

    @ViewBuilder
    func body(content: Content) -> some View {
        if entry.isDir {
            content
                .accessibilityAction(named: Text("Toggle Folder")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeToggle(index: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("New File…")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeNewFile(parentIndex: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("New Folder…")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeNewFolder(parentIndex: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("Rename")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeRename(index: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("Move to Trash")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeDelete(index: UInt16(entry.index))
                }
        } else {
            content
                .accessibilityAction(named: Text("Open")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeClick(index: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("Open in Split")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeOpenInSplit(index: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("Rename")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeRename(index: UInt16(entry.index))
                }
                .accessibilityAction(named: Text("Move to Trash")) {
                    guard let entry = resolveEntry(entry.id) else { return }
                    encoder?.sendFileTreeDelete(index: UInt16(entry.index))
                }
        }
    }
}

/// Preference key for tracking scroll offset within the file tree.
private struct ScrollOffsetKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
