/// Compiler-checked composition for native sidebars built into the macOS frontend.

import SwiftUI

/// The fixed native sidebar implementations understood by the macOS frontend.
public enum NativeSidebarKind: Equatable {
    case fileTree
    case gitStatus
    case observatory
    case unsupported(String)

    /// Parses the semantic sidebar kind supplied by the BEAM while preserving unsupported identities.
    public init(_ semanticKind: String) {
        switch semanticKind {
        case "file_tree": self = .fileTree
        case "git_status": self = .gitStatus
        case "observatory": self = .observatory
        default: self = .unsupported(semanticKind)
        }
    }

    /// The original wire value used for actions, warnings, and fallback identity.
    public var wireValue: String {
        switch self {
        case .fileTree: "file_tree"
        case .gitStatus: "git_status"
        case .observatory: "observatory"
        case let .unsupported(semanticKind): semanticKind
        }
    }

    /// Whether this frontend has a compiled-in view for the kind.
    public var isSupported: Bool {
        switch self {
        case .fileTree, .gitStatus, .observatory: true
        case .unsupported: false
        }
    }

    /// The SF Symbol used when metadata does not supply an icon.
    public var fallbackIcon: String {
        switch self {
        case .fileTree: "folder"
        case .gitStatus: "point.3.filled.connected.trianglepath.dotted"
        case .observatory: "network"
        case .unsupported: "questionmark.square.dashed"
        }
    }

    /// Returns the activity-bar badge for this sidebar kind.
    public func badgeText(metadataCount: UInt16?, gitStatusCount: Int) -> String? {
        guard self == .gitStatus else { return nil }
        let count = metadataCount.map(Int.init) ?? gitStatusCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }
}

@MainActor
struct NativeSidebarHeader: View {
    let input: ShellHostInput
    let item: SidebarItem
    let sendAction: ViewActionHandler<SidebarContainer.Action>?
    let projectName: String
    let gitBranch: String
    let leadingPadding: CGFloat

    @ViewBuilder
    var body: some View {
        switch item.semanticKind {
        case .fileTree:
            FileTreeHeaderView(
                fileTreeState: input.fileTreeState,
                sendAction: headerAction,
                branchName: gitBranch,
                leadingPadding: leadingPadding
            )
        case .gitStatus:
            GitStatusHeaderView(
                state: input.gitStatusState,
                projectName: projectName,
                leadingPadding: leadingPadding
            )
        case .observatory:
            ObservatorySidebarHeader(
                item: item,
                state: input.observatoryState,
                leadingPadding: leadingPadding
            )
        case .unsupported:
            GenericSidebarFallbackHeader(item: item, leadingPadding: leadingPadding)
        }
    }

    private var headerAction: ViewActionHandler<FileTreeHeaderView.Action>? {
        guard let sendAction else { return nil }
        return { sendAction(.fileTreeHeader($0)) }
    }
}

@MainActor
struct NativeSidebarBody: View {
    let input: ShellHostInput
    let item: SidebarItem
    let sendAction: ViewActionHandler<SidebarContainer.Action>?
    let frameProbe: ContentViewFrameProbe?

    @ViewBuilder
    var body: some View {
        switch item.semanticKind {
        case .fileTree:
            FileTreeView(fileTreeState: input.fileTreeState, sendAction: fileTreeAction)
                .background {
                    if let frameProbe {
                        frameProbe.makeView(
                            .fileTree,
                            input.fileTreeState.entries.first(where: \.isSelected)?.name ?? "",
                            input.fileTreeState
                        )
                    }
                }
        case .gitStatus:
            GitStatusView(state: input.gitStatusState, sendAction: gitStatusAction)
        case .observatory:
            ObservatoryView(state: input.observatoryState, sendAction: observatoryAction)
        case .unsupported:
            GenericSidebarFallbackView(item: item)
        }
    }

    private var fileTreeAction: ViewActionHandler<FileTreeView.Action>? {
        guard let sendAction else { return nil }
        return { sendAction(.fileTree($0)) }
    }

    private var gitStatusAction: ViewActionHandler<GitStatusView.Action>? {
        guard let sendAction else { return nil }
        return { sendAction(.gitStatus($0)) }
    }

    private var observatoryAction: ViewActionHandler<ObservatoryView.Action>? {
        guard let sendAction else { return nil }
        return { sendAction(.observatory($0)) }
    }
}

private struct ObservatorySidebarHeader: View {
    let item: SidebarItem
    let state: ObservatoryState
    @Environment(\.themeColors) private var theme

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
            Text("The native frontend does not have an adapter for \"\(item.semanticKind.wireValue)\".")
                .font(.system(size: 11))
                .foregroundStyle(theme.treeFg.opacity(0.65))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.treeBg)
    }
}
