import SwiftUI

/// Workspace header row rendered above active-workspace file tabs.
struct WorkspaceHeaderView: View {
    let workspaceState: WorkspaceState
    let theme: ThemeColors
    let encoder: InputEncoder?

    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showIconPicker = false
    @FocusState private var renameFieldFocused: Bool

    private let rowHeight: CGFloat = 26

    var body: some View {
        HStack(spacing: 8) {
            if let activeWorkspace = workspaceState.activeWorkspace {
                activeWorkspacePill(activeWorkspace)

                if workspaceState.workspaces.count > 1 {
                    workspaceSwitcher
                }

                if activeWorkspace.isAgent {
                    agentStatusButton(activeWorkspace)
                }

                badges(for: activeWorkspace)
                backgroundBadges

                Spacer(minLength: 8)

                if activeWorkspace.isCloseable {
                    closeButton(activeWorkspace)
                }
            } else {
                Text("Workspace")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.tabInactiveFg)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(theme.tabBg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.tabSeparatorFg.opacity(0.16))
                .frame(height: 1)
        }
        .accessibilityIdentifier("workspace-header")
    }

    private func activeWorkspacePill(_ workspace: WorkspaceSummaryEntry) -> some View {
        HStack(spacing: 6) {
            workspaceIcon(workspace)
            workspaceTitle(workspace)
        }
        .padding(.horizontal, 4)
        .frame(height: rowHeight)
        .accessibilityIdentifier("workspace-label-\(workspace.id)")
        .accessibilityLabel("Workspace \(workspace.label)")
        .accessibilityValue(workspaceValue(workspace))
        .contextMenu {
            Button("Rename Workspace…") { beginRename(workspace) }
            Button("Change Icon…") { showIconPicker = true }
        }
        .onTapGesture(count: 2) { beginRename(workspace) }
        .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
            WorkspaceIconPicker(currentIcon: workspace.icon, accentColor: workspace.color, theme: theme) { selectedIcon in
                encoder?.sendWorkspaceSetIcon(id: workspace.id, icon: selectedIcon)
                showIconPicker = false
            }
            .frame(width: 320, height: 260)
        }
    }

    @ViewBuilder
    private func workspaceTitle(_ workspace: WorkspaceSummaryEntry) -> some View {
        if isRenaming {
            TextField("Workspace name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .frame(minWidth: 90, maxWidth: 180)
                .focused($renameFieldFocused)
                .onSubmit { commitRename(workspace) }
                .onExitCommand { isRenaming = false }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused { commitRename(workspace) }
                }
        } else {
            Text(workspace.label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(theme.tabActiveFg)
        }
    }

    private var workspaceSwitcher: some View {
        Menu {
            ForEach(workspaceState.workspaces) { workspace in
                Button {
                    encoder?.sendExecuteCommand(name: workspaceState.switchCommand(for: workspace))
                } label: {
                    Label(workspace.label, systemImage: workspaceSystemImage(workspace))
                }
                .accessibilityIdentifier("workspace-row-\(workspace.id)")
            }
        } label: {
            Image(systemName: "rectangle.grid.1x2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.tabInactiveFg)
                .frame(width: 24, height: rowHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("workspace-switcher")
        .accessibilityLabel("Workspace switcher")
        .help("Switch workspace")
    }

    private func agentStatusButton(_ workspace: WorkspaceSummaryEntry) -> some View {
        Button {
            encoder?.sendExecuteCommand(name: "toggle_agentic_view")
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(agentStatusColor(workspace.agentStatus, accent: workspace.color))
                    .frame(width: 7, height: 7)
                Text(agentStatusLabel(workspace.agentStatus))
                    .font(.system(size: 11))
            }
            .foregroundStyle(theme.tabInactiveFg)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace-agent-button")
        .accessibilityLabel("Agent status")
        .accessibilityValue(agentStatusLabel(workspace.agentStatus))
        .help(agentStatusHelp(workspace.agentStatus))
    }

    @ViewBuilder
    private func badges(for workspace: WorkspaceSummaryEntry) -> some View {
        HStack(spacing: 5) {
            if workspace.runningBackgroundCount > 0 {
                badge("⚡\(workspace.runningBackgroundCount)", help: "Agent running in this workspace")
            }
            if workspace.draftCount > 0 {
                badge("✓\(workspace.draftCount)", help: "Workspace drafts need review")
            }
            if workspace.conflictCount > 0 {
                badge("⚠︎\(workspace.conflictCount)", help: "Workspace conflicts need resolution", color: .orange)
            }
            if workspace.hasAttention {
                badge("!", help: "Workspace needs attention", color: .red)
            }
        }
        .accessibilityLabel("Workspace badges")
    }

    @ViewBuilder
    private var backgroundBadges: some View {
        HStack(spacing: 5) {
            if workspaceState.backgroundRunningCount > 0 {
                badge("bg ⚡\(workspaceState.backgroundRunningCount)", help: "Background workspace agents are running")
            }
            if workspaceState.backgroundDraftCount > 0 {
                badge("bg ✓\(workspaceState.backgroundDraftCount)", help: "Background workspace drafts need review")
            }
            if workspaceState.backgroundConflictCount > 0 {
                badge("bg ⚠︎\(workspaceState.backgroundConflictCount)", help: "Background workspace conflicts need resolution", color: .orange)
            }
            if workspaceState.backgroundAttentionCount > 0 {
                badge("bg !\(workspaceState.backgroundAttentionCount)", help: "Background workspaces need attention", color: .red)
            }
            if workspaceState.backgroundErrorCount > 0 {
                badge("bg ✕\(workspaceState.backgroundErrorCount)", help: "Background workspace agents have errors", color: .red)
            }
        }
        .accessibilityLabel("Background workspace badges")
    }

    private func closeButton(_ workspace: WorkspaceSummaryEntry) -> some View {
        Button {
            encoder?.sendWorkspaceClose(id: workspace.id)
        } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(theme.tabInactiveFg)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close workspace \(workspace.label)")
        .help("Close workspace")
    }

    private func badge(_ text: String, help: String, color: Color? = nil) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((color ?? theme.tabInactiveFg).opacity(0.18)))
            .foregroundStyle(color ?? theme.tabInactiveFg)
            .help(help)
            .accessibilityLabel(help)
    }

    @ViewBuilder
    private func workspaceIcon(_ workspace: WorkspaceSummaryEntry) -> some View {
        if workspace.isManual {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(workspace.color)
        } else {
            Image(systemName: workspace.icon.isEmpty ? "cpu" : workspace.icon)
                .font(.system(size: 12))
                .foregroundStyle(workspace.color)
        }
    }

    private func workspaceSystemImage(_ workspace: WorkspaceSummaryEntry) -> String {
        workspace.isManual ? "folder" : (workspace.icon.isEmpty ? "cpu" : workspace.icon)
    }

    private func beginRename(_ workspace: WorkspaceSummaryEntry) {
        renameText = workspace.label
        isRenaming = true
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func commitRename(_ workspace: WorkspaceSummaryEntry) {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.label else { return }
        encoder?.sendWorkspaceRename(id: workspace.id, name: trimmed)
    }

    private func workspaceValue(_ workspace: WorkspaceSummaryEntry) -> String {
        [workspace.isManual ? "manual" : "agent", agentStatusLabel(workspace.agentStatus)]
            .joined(separator: ", ")
    }

    private func agentStatusLabel(_ status: UInt8) -> String {
        switch status {
        case 1: return "Thinking"
        case 2: return "Using tools"
        case 3: return "Error"
        case 4: return "Planning"
        default: return "Idle"
        }
    }

    private func agentStatusHelp(_ status: UInt8) -> String {
        "Agent status: \(agentStatusLabel(status))"
    }

    private func agentStatusColor(_ status: UInt8, accent: Color) -> Color {
        switch status {
        case 1, 2: return accent
        case 3: return .red
        case 4: return theme.agentStatusNeedsYou
        default: return theme.tabInactiveFg
        }
    }
}
