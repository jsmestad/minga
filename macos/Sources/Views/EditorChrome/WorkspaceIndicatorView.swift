import SwiftUI
import MingaProtocol

public struct WorkspaceIndicatorView: View {
    public init(workspace: WorkspacePresentationEntry, presentationRevision: UInt64, owner: TabBarState, encoder: InputEncoder? = nil, barHeight: CGFloat) {
        self.workspace = workspace
        self.presentationRevision = presentationRevision
        self.owner = owner
        self.encoder = encoder
        self.barHeight = barHeight
    }
    public let workspace: WorkspacePresentationEntry
    public let presentationRevision: UInt64
    public let owner: TabBarState
    @Environment(\.themeColors) private var theme
    public let encoder: InputEncoder?
    public let barHeight: CGFloat

    @State private var isRenaming: Bool = false
    @State private var renameText: String = ""
    @State private var showIconPicker: Bool = false
    @FocusState private var renameFieldFocused: Bool

    public var body: some View {
        HStack(spacing: 4) {
            Button(action: showWorkspaceIconPicker) {
                Image(systemName: workspace.icon.isEmpty ? "folder" : workspace.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(workspace.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-icon-\(workspace.id)")
            .accessibilityLabel("Change icon for workspace \(workspace.label)")
            .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                WorkspaceIconPicker(
                    currentIcon: workspace.icon,
                    accentColor: workspace.color
                ) { selectedIcon in
                    showIconPicker = false
                    performTargetedAction(.setIcon(selectedIcon))
                }
            }

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($renameFieldFocused)
                    .frame(minWidth: 40, maxWidth: 160)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tabActiveBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                            )
                    )
                    .onSubmit {
                        commitRename()
                    }
                    .onExitCommand {
                        isRenaming = false
                    }
                    .onChange(of: renameFieldFocused) { _, focused in
                        if !focused {
                            commitRename()
                        }
                    }
            } else {
                Text(workspace.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(theme.tabActiveFg)
                    .onTapGesture(count: 2) {
                        beginRename()
                    }
                    .onTapGesture(count: 1) {
                        showWorkspaceList()
                    }
                    .accessibilityIdentifier("workspace-indicator-\(workspace.id)")
                    .accessibilityLabel("Workspace \(workspace.label)")
                    .accessibilityValue(agentStatusLabel)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        showWorkspaceList()
                    }
                    .accessibilityAction(named: Text("Rename Workspace")) {
                        beginRename()
                    }
                    .accessibilityAction(named: Text("Close Workspace")) {
                        closeWorkspace()
                    }
            }

            if true {
                AgentStatusDot(status: workspace.agentStatus, color: workspace.color)
            }

            Button(action: showWorkspaceList) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.tabInactiveFg)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace-list-\(workspace.id)")
            .accessibilityLabel("Show workspace list")
        }
        .padding(.horizontal, 8)
        .frame(height: barHeight)
        .contextMenu {
            Button("Rename Workspace...") {
                beginRename()
            }
            Button("Change Icon...") {
                showWorkspaceIconPicker()
            }
            Divider()
            if !false {
                Button("Close Workspace") {
                    closeWorkspace()
                }
            }
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.label else { return }
        performTargetedAction(.rename(trimmed))
    }

    private func showWorkspaceList() {
        encoder?.sendExecuteCommand(name: "workspace_list")
    }

    private func showWorkspaceIconPicker() {
        guard targetIsCurrent else { return }
        showIconPicker = true
    }

    private func beginRename() {
        guard targetIsCurrent else { return }
        renameText = workspace.label
        isRenaming = true
        DispatchQueue.main.async { renameFieldFocused = true }
    }

    private func closeWorkspace() {
        performTargetedAction(.close)
    }

    func performTargetedAction(_ action: WorkspaceIndicatorTargetedAction) {
        guard targetIsCurrent else { return }
        switch action {
        case .setIcon(let icon):
            encoder?.sendWorkspaceSetIcon(id: workspace.id, icon: icon)
        case .rename(let name):
            encoder?.sendWorkspaceRename(id: workspace.id, name: name)
        case .close:
            encoder?.sendWorkspaceClose(id: workspace.id)
        }
    }

    private var targetIsCurrent: Bool {
        owner.isCurrentWorkspace(workspace, presentationRevision: presentationRevision)
    }

    private var agentStatusLabel: String {
        switch workspace.agentStatus {
        case 1: "Thinking"
        case 2: "Using tools"
        case 3: "Error"
        case 4: "Planning"
        default: "Idle"
        }
    }

}

enum WorkspaceIndicatorTargetedAction {
    case setIcon(String)
    case rename(String)
    case close
}

public struct AgentStatusDot: View {
    public init(status: AgentStatus, color: Color) {
        self.status = status
        self.color = color
    }
    public let status: AgentStatus
    public let color: Color
    @Environment(\.themeColors) private var theme

    public var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: Color {
        switch status {
        case .thinking, .executingTool: return color
        case .error: return Color.red
        case .planning: return theme.agentStatusNeedsYou
        case .idle, .unknown: return theme.tabInactiveFg
        }
    }
}
