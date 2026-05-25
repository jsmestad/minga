/// Static registry of native sidebar adapters compiled into the macOS frontend.

import SwiftUI

/// Context passed to native sidebar adapter builders.
@MainActor
struct NativeSidebarContext {
    let guiState: GUIState
    let theme: ThemeColors
    let encoder: InputEncoder?
    let projectName: String
    let gitBranch: String
    let leadingPadding: CGFloat
}

/// Compiled-in adapter for one semantic sidebar kind.
@MainActor
struct NativeSidebarAdapter {
    let kind: String
    let fallbackIcon: String
    let makeHeader: (NativeSidebarContext, SidebarItem) -> AnyView
    let makeBody: (NativeSidebarContext, SidebarItem) -> AnyView
    let sendPrimaryAction: (InputEncoder?, SidebarItem, Bool) -> Void
    let badgeText: (NativeSidebarContext, SidebarItem) -> String?
}

/// Native sidebar registry. This is intentionally static so extensions cannot load arbitrary Swift code at runtime.
@MainActor
enum NativeSidebarRegistry {
    private static let adapters: [String: NativeSidebarAdapter] = [
        fileTree.kind: fileTree,
        gitStatus.kind: gitStatus,
        observatory.kind: observatory
    ]

    static func adapter(for kind: String) -> NativeSidebarAdapter? {
        adapters[kind]
    }

    static func adapterOrFallback(for kind: String) -> NativeSidebarAdapter {
        adapters[kind] ?? genericFallback
    }

    private static let fileTree = NativeSidebarAdapter(
        kind: "file_tree",
        fallbackIcon: "folder",
        makeHeader: { context, _ in
            AnyView(FileTreeHeaderContent(
                fileTreeState: context.guiState.fileTreeState,
                theme: context.theme,
                encoder: context.encoder,
                branchName: context.gitBranch,
                leadingPadding: context.leadingPadding
            ))
        },
        makeBody: { context, _ in
            AnyView(FileTreeView(
                fileTreeState: context.guiState.fileTreeState,
                theme: context.theme,
                encoder: context.encoder
            ))
        },
        sendPrimaryAction: { encoder, item, isActive in
            encoder?.sendSidebarAction(sidebarId: item.id, kind: item.semanticKind, action: isActive ? "toggle" : "activate")
        },
        badgeText: { _, _ in nil }
    )

    private static let gitStatus = NativeSidebarAdapter(
        kind: "git_status",
        fallbackIcon: "point.3.filled.connected.trianglepath.dotted",
        makeHeader: { context, _ in
            AnyView(GitStatusHeaderContent(
                state: context.guiState.gitStatusState,
                theme: context.theme,
                projectName: context.projectName,
                leadingPadding: context.leadingPadding
            ))
        },
        makeBody: { context, _ in
            AnyView(GitStatusView(
                state: context.guiState.gitStatusState,
                theme: context.theme,
                encoder: context.encoder
            ))
        },
        sendPrimaryAction: { encoder, item, isActive in
            encoder?.sendSidebarAction(sidebarId: item.id, kind: item.semanticKind, action: isActive ? "toggle" : "activate")
        },
        badgeText: { context, item in
            let count = item.badgeCount.map(Int.init) ?? context.guiState.gitStatusState.totalCount
            guard count > 0 else { return nil }
            return count > 99 ? "99+" : String(count)
        }
    )

    private static let observatory = NativeSidebarAdapter(
        kind: "observatory",
        fallbackIcon: "network",
        makeHeader: { context, item in
            AnyView(ObservatorySidebarHeader(item: item, state: context.guiState.observatoryState, theme: context.theme, leadingPadding: context.leadingPadding))
        },
        makeBody: { context, _ in
            AnyView(ObservatoryView(
                state: context.guiState.observatoryState,
                theme: context.theme,
                encoder: context.encoder
            ))
        },
        sendPrimaryAction: { encoder, item, isActive in
            encoder?.sendSidebarAction(sidebarId: item.id, kind: item.semanticKind, action: isActive ? "toggle" : "activate")
        },
        badgeText: { _, _ in nil }
    )

    private static let genericFallback = NativeSidebarAdapter(
        kind: "generic_fallback",
        fallbackIcon: "questionmark.square.dashed",
        makeHeader: { context, item in
            AnyView(GenericSidebarFallbackHeader(item: item, theme: context.theme, leadingPadding: context.leadingPadding))
        },
        makeBody: { context, item in
            AnyView(GenericSidebarFallbackView(item: item, theme: context.theme))
        },
        sendPrimaryAction: { encoder, item, isActive in
            encoder?.sendSidebarAction(sidebarId: item.id, kind: item.semanticKind, action: isActive ? "toggle" : "activate")
        },
        badgeText: { _, _ in nil }
    )
}

private struct ObservatorySidebarHeader: View {
    let item: SidebarItem
    let state: ObservatoryState
    let theme: ThemeColors
    let leadingPadding: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon.isEmpty ? "network" : item.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.treeDirFg.opacity(0.85))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.tabActiveFg.opacity(0.85))
                Text("\(state.processCount) processes")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(theme.treeFg.opacity(0.55))
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 12)
    }
}

private struct GenericSidebarFallbackHeader: View {
    let item: SidebarItem
    let theme: ThemeColors
    let leadingPadding: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.treeDirFg.opacity(0.85))

            Text(item.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg.opacity(0.85))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 12)
    }
}

private struct GenericSidebarFallbackView: View {
    let item: SidebarItem
    let theme: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Unsupported sidebar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.tabActiveFg)
            Text("The native frontend does not have an adapter for \"\(item.semanticKind)\".")
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg.opacity(0.65))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.treeBg)
    }
}
