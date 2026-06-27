import SwiftUI

struct WorkspaceIndicatorView: View {
    let workspace: WorkspaceEntry
    @Environment(\.themeColors) private var theme
    let encoder: InputEncoder?
    let barHeight: CGFloat

    @State private var isRenaming: Bool = false
    @State private var renameText: String = ""
    @State private var showIconPicker: Bool = false
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: workspace.icon.isEmpty ? "folder" : workspace.icon)
                .font(.system(size: 10))
                .foregroundStyle(workspace.color)
                .contentShape(Rectangle())
                .onTapGesture {
                    showIconPicker = true
                }
                .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                    WorkspaceIconPicker(
                        currentIcon: workspace.icon,
                        accentColor: workspace.color
                    ) { selectedIcon in
                        showIconPicker = false
                        encoder?.sendWorkspaceSetIcon(id: workspace.id, icon: selectedIcon)
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
                        renameText = workspace.label
                        isRenaming = true
                        DispatchQueue.main.async { renameFieldFocused = true }
                    }
                    .onTapGesture(count: 1) {
                        encoder?.sendExecuteCommand(name: "workspace_list")
                    }
            }

            if true {
                AgentStatusDot(status: workspace.agentStatus, color: workspace.color)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(theme.tabInactiveFg)
                .onTapGesture {
                    encoder?.sendExecuteCommand(name: "workspace_list")
                }
        }
        .padding(.horizontal, 8)
        .frame(height: barHeight)
        .contextMenu {
            Button("Rename Workspace...") {
                renameText = workspace.label
                isRenaming = true
                DispatchQueue.main.async { renameFieldFocused = true }
            }
            Button("Change Icon...") {
                showIconPicker = true
            }
            Divider()
            if !false {
                Button("Close Workspace") {
                    encoder?.sendWorkspaceClose(id: workspace.id)
                }
            }
        }
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.label else { return }
        encoder?.sendWorkspaceRename(id: workspace.id, name: trimmed)
    }

}

struct AgentStatusDot: View {
    let status: UInt8
    let color: Color
    @Environment(\.themeColors) private var theme

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
    }

    private var dotColor: Color {
        switch status {
        case 1: return color
        case 2: return color
        case 3: return Color.red
        case 4: return theme.agentStatusNeedsYou
        default: return theme.tabInactiveFg
        }
    }
}
