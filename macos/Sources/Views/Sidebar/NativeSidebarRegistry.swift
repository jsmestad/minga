/// Static registry of native sidebar adapters compiled into the macOS frontend.

import SwiftUI

/// Context passed to native sidebar adapter builders.
@MainActor
public struct NativeSidebarContext {
    public init(input: ShellHostInput, theme: ThemeColors, encoder: InputEncoder? = nil, projectName: String, gitBranch: String, leadingPadding: CGFloat) {
        self.input = input
        self.theme = theme
        self.encoder = encoder
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.leadingPadding = leadingPadding
    }
    public let input: ShellHostInput
    public let theme: ThemeColors
    public let encoder: InputEncoder?
    public let projectName: String
    public let gitBranch: String
    public let leadingPadding: CGFloat
}

/// Compiled-in adapter for one semantic sidebar kind.
@MainActor
public struct NativeSidebarAdapter {
    public init(kind: String, fallbackIcon: String, makeHeader: @escaping (NativeSidebarContext, SidebarItem) -> AnyView, makeBody: @escaping (NativeSidebarContext, SidebarItem) -> AnyView, sendPrimaryAction: @escaping (InputEncoder?, SidebarItem, Bool) -> Void, badgeText: @escaping (NativeSidebarContext, SidebarItem) -> String?) {
        self.kind = kind
        self.fallbackIcon = fallbackIcon
        self.makeHeader = makeHeader
        self.makeBody = makeBody
        self.sendPrimaryAction = sendPrimaryAction
        self.badgeText = badgeText
    }
    public let kind: String
    public let fallbackIcon: String
    public let makeHeader: (NativeSidebarContext, SidebarItem) -> AnyView
    public let makeBody: (NativeSidebarContext, SidebarItem) -> AnyView
    public let sendPrimaryAction: (InputEncoder?, SidebarItem, Bool) -> Void
    public let badgeText: (NativeSidebarContext, SidebarItem) -> String?
}

/// Native sidebar registry. This is intentionally static so extensions cannot load arbitrary Swift code at runtime.
@MainActor
public enum NativeSidebarRegistry {
    private static let adapters: [String: NativeSidebarAdapter] = [
        fileTree.kind: fileTree,
        gitStatus.kind: gitStatus,
        observatory.kind: observatory
    ]

    public static func adapter(for kind: String) -> NativeSidebarAdapter? {
        adapters[kind]
    }

    public static func adapterOrFallback(for kind: String) -> NativeSidebarAdapter {
        adapters[kind] ?? genericFallback
    }

    private static let fileTree = NativeSidebarAdapter(
        kind: "file_tree",
        fallbackIcon: "folder",
        makeHeader: { context, _ in
            AnyView(FileTreeHeaderView(
                fileTreeState: context.input.fileTreeState,
                encoder: context.encoder,
                branchName: context.gitBranch,
                leadingPadding: context.leadingPadding
            ))
        },
        makeBody: { context, _ in
            AnyView(FileTreeView(
                fileTreeState: context.input.fileTreeState,
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
            AnyView(GitStatusHeaderView(
                state: context.input.gitStatusState,
                projectName: context.projectName,
                leadingPadding: context.leadingPadding
            ))
        },
        makeBody: { context, _ in
            AnyView(GitStatusView(
                state: context.input.gitStatusState,
                encoder: context.encoder
            ))
        },
        sendPrimaryAction: { encoder, item, isActive in
            encoder?.sendSidebarAction(sidebarId: item.id, kind: item.semanticKind, action: isActive ? "toggle" : "activate")
        },
        badgeText: { context, item in
            let count = item.badgeCount.map(Int.init) ?? context.input.gitStatusState.totalCount
            guard count > 0 else { return nil }
            return count > 99 ? "99+" : String(count)
        }
    )

    private static let observatory = NativeSidebarAdapter(
        kind: "observatory",
        fallbackIcon: "network",
        makeHeader: { context, item in
            AnyView(ObservatorySidebarHeader(item: item, state: context.input.observatoryState, leadingPadding: context.leadingPadding))
        },
        makeBody: { context, _ in
            AnyView(ObservatoryView(
                state: context.input.observatoryState,
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
            AnyView(GenericSidebarFallbackHeader(item: item, leadingPadding: context.leadingPadding))
        },
        makeBody: { context, item in
            AnyView(GenericSidebarFallbackView(item: item))
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
    @Environment(\.themeColors) private var theme
    @Environment(\.guiFrameVersion) private var frameVersion
    let leadingPadding: CGFloat

    var body: some View {
        let _ = frameVersion
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
    @Environment(\.themeColors) private var theme
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
    @Environment(\.themeColors) private var theme

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
