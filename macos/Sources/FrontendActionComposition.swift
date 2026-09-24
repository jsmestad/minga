import Foundation

/// Translates consumer-owned view actions into the canonical outbound protocol action.
public enum FrontendActionComposition {
    @MainActor
    public static func settingsHandler(encoder: OutboundActionEncoding?) -> ViewActionHandler<SettingsView.Action>? {
        translatedHandler(encoder: encoder, translate: outbound)
    }

    @MainActor
    public static func settingsStateHandler(encoder: OutboundActionEncoding?) -> ViewActionHandler<SettingsState.Action>? {
        translatedHandler(encoder: encoder, translate: outbound)
    }

    @MainActor
    private static func translatedHandler<Action: Sendable>(encoder: OutboundActionEncoding?, translate: @escaping @Sendable (Action) -> OutboundAction) -> ViewActionHandler<Action>? {
        guard let encoder else { return nil }
        return { action in encoder.send(translate(action)) }
    }

    public static func outbound(_ action: AgentChatView.Action) -> OutboundAction {
        switch action {
        case .keyPress(let codepoint, let modifiers, let sequence): .keyPress(codepoint: codepoint, modifiers: modifiers, sequence: sequence)
        case .executeCommand(let name): .executeCommand(name: name)
        case .agentToolToggle(let messageID): .agentToolToggle(messageID: messageID)
        case .chatScrolledAwayFromBottom: .chatScrolledAwayFromBottom
        case .chatReturnedToBottom: .chatReturnedToBottom
        }
    }

    public static func outbound(_ action: AgentContextBar.ReviewAction) -> OutboundAction {
        switch action {
        case .approve: .agentApprove
        case .requestChanges: .agentRequestChanges
        case .dismiss: .agentDismiss
        }
    }

    public static func outbound(_ action: WorkspaceHeaderView.Action) -> OutboundAction {
        switch action {
        case .executeCommand(let name): .executeCommand(name: name)
        case .setIcon(let id, let icon): .workspaceSetIcon(id: id, icon: icon)
        case .close(let id): .workspaceClose(id: id)
        case .rename(let id, let name): .workspaceRename(id: id, name: name)
        }
    }

    public static func outbound(_ action: TabBarView.Action) -> OutboundAction {
        switch action {
        case .executeCommand(let name): .executeCommand(name: name)
        case .newTab: .newTab
        case .selectTab(let id): .selectTab(id: id)
        case .closeTab(let id): .closeTab(id: id)
        case .copyPath(let id): .tabCopyPath(id: id)
        case .reorder(let id, let newIndex): .tabReorder(id: id, newIndex: newIndex)
        case .pin(let id): .tabPin(id: id)
        case .unpin(let id): .tabUnpin(id: id)
        case .moveLeft(let id): .tabMoveLeft(id: id)
        case .moveRight(let id): .tabMoveRight(id: id)
        case .closeWorkspace(let id): .workspaceClose(id: id)
        case .setWorkspaceIcon(let id, let icon): .workspaceSetIcon(id: id, icon: icon)
        case .renameWorkspace(let id, let name): .workspaceRename(id: id, name: name)
        }
    }

    public static func outbound(_ action: BreadcrumbBar.Action) -> OutboundAction {
        switch action {
        case .executeCommand(let name): .executeCommand(name: name)
        }
    }

    public static func outbound(_ action: SearchToolbar.Action) -> OutboundAction {
        switch action {
        case .focus(let replaceMode): .searchFocus(replaceMode: replaceMode)
        case .query(let sessionID, let editSequence, let query, let flags): .searchQuery(sessionID: sessionID, editSequence: editSequence, query: query, flags: flags)
        case .next: .searchNext
        case .previous: .searchPrevious
        case .replace(let replacement): .searchReplace(replacement: replacement)
        case .replaceAll(let replacement): .searchReplaceAll(replacement: replacement)
        case .dismiss: .searchDismiss
        }
    }

    public static func outbound(_ action: EditTimelineView.Action) -> OutboundAction {
        switch action {
        case .navigate(let index): .timelineNavigate(index: index)
        }
    }

    public static func outbound(_ action: BottomPanelView.Action) -> OutboundAction {
        switch action {
        case .switchTab(let index): .panelSwitchTab(index: index)
        case .dismiss: .panelDismiss
        case .resize(let heightPercent): .panelResize(heightPercent: heightPercent)
        case .openFile(let path): .openFile(path: path)
        }
    }

    public static func outbound(_ action: EmptyStateView.Action) -> OutboundAction {
        switch action {
        case .activate(let id): .emptyStateActivate(id: id)
        }
    }

    public static func outbound(_ action: StatusBarView.Action) -> OutboundAction {
        switch action {
        case .executeCommand(let name): .executeCommand(name: name)
        case .togglePanel(let panel): .togglePanel(panel: panel)
        }
    }

    public static func outbound(_ action: MinibufferView.Action) -> OutboundAction {
        switch action {
        case .select(let index): .minibufferSelect(index: index)
        }
    }

    public static func outbound(_ action: CompletionOverlay.Action) -> OutboundAction {
        switch action {
        case .select(let generation, let itemID): .semanticItemActivate(surface: .completion, intent: 1, generation: generation, itemID: Data(itemID.utf8))
        }
    }

    public static func outbound(_ action: PickerOverlay.Action) -> OutboundAction {
        switch action {
        case .queryChanged(let generation, let editSequence, let text): .pickerQueryChanged(generation: generation, editSequence: editSequence, text: text)
        case .keyPress(let codepoint, let modifiers, let sequence): .keyPress(codepoint: codepoint, modifiers: modifiers, sequence: sequence)
        case .activateItem(let generation, let activationID): .semanticItemActivate(surface: .picker, intent: 1, generation: generation, itemID: activationID.bigEndianData)
        case .activateAction(let generation, let activationID): .semanticItemActivate(surface: .picker, intent: 2, generation: generation, itemID: activationID.bigEndianData)
        }
    }

    public static func outbound(_ action: NotificationCenterView.Action) -> OutboundAction {
        switch action {
        case .dismiss(let id): .notificationDismiss(id: id)
        case .invoke(let id, let actionID): .notificationAction(id: id, actionID: actionID)
        }
    }

    public static func outbound(_ action: ActivityBar.Action) -> OutboundAction {
        switch action {
        case .activate(let sidebarID, let kind, let action): .sidebarAction(sidebarID: sidebarID, kind: kind, action: action)
        }
    }

    public static func outbound(_ action: SidebarContainer.Action) -> OutboundAction {
        switch action {
        case .fileTreeHeader(let action): outbound(action)
        case .fileTree(let action): outbound(action)
        case .gitStatus(let action): outbound(action)
        case .observatory(let action): outbound(action)
        }
    }

    public static func outbound(_ action: FileTreeHeaderView.Action) -> OutboundAction {
        switch action {
        case .newFile(let parentIndex): .fileTreeNewFile(parentIndex: parentIndex)
        case .newFolder(let parentIndex): .fileTreeNewFolder(parentIndex: parentIndex)
        case .refresh: .fileTreeRefresh
        case .collapseAll: .fileTreeCollapseAll
        }
    }

    public static func outbound(_ action: FileTreeView.Action) -> OutboundAction {
        switch action {
        case .click(let index): .fileTreeClick(index: index)
        case .toggle(let index): .fileTreeToggle(index: index)
        case .openInSplit(let index): .fileTreeOpenInSplit(index: index)
        case .newFile(let parentIndex): .fileTreeNewFile(parentIndex: parentIndex)
        case .newFolder(let parentIndex): .fileTreeNewFolder(parentIndex: parentIndex)
        case .editConfirm(let token, let text): .fileTreeEditConfirm(token: token, text: text)
        case .editCancel: .fileTreeEditCancel
        case .delete(let index): .fileTreeDelete(index: index)
        case .rename(let index): .fileTreeRename(index: index)
        case .duplicate(let index): .fileTreeDuplicate(index: index)
        case .drop(let sourcePaths, let targetIndex, let targetID, let targetPathHash, let targetPath, let targetIsDirectory, let modifiers): .fileTreeDrop(sourcePaths: sourcePaths, targetIndex: targetIndex, targetID: targetID, targetPathHash: targetPathHash, targetPath: targetPath, targetIsDirectory: targetIsDirectory, modifiers: modifiers)
        case .refresh: .fileTreeRefresh
        case .semantic(let intent, let generation, let itemID): .semanticItemActivate(surface: .fileTree, intent: intent.rawValue, generation: generation, itemID: Data(itemID.utf8))
        }
    }

    public static func outbound(_ action: GitStatusView.Action) -> OutboundAction {
        switch action {
        case .discardFile(let path): .gitDiscardFile(path: path)
        case .unstageAll: .gitUnstageAll
        case .stageAll: .gitStageAll
        case .openFile(let path): .gitOpenFile(path: path)
        case .openDiff(let path, let section): .gitOpenDiff(path: path, section: section)
        case .stageFile(let path): .gitStageFile(path: path)
        case .unstageFile(let path): .gitUnstageFile(path: path)
        case .pull: .gitPull
        case .push: .gitPush
        case .fetch: .gitFetch
        case .commit(let message): .gitCommit(message: message)
        case .amend(let message): .gitCommitAmend(message: message)
        case .pullAndRetry: .gitPullAndRetry
        }
    }

    public static func outbound(_ action: ObservatoryView.Action) -> OutboundAction {
        switch action {
        case .inspect(let pid): .observatoryInspect(pid: pid)
        }
    }

    public static func outbound(_ action: SettingsView.Action) -> OutboundAction {
        switch action {
        case .executeCommand(let name): .executeCommand(name: name)
        case .query: .configQuery
        case .update(let key, let value): .configUpdate(key: key, value: value)
        }
    }

    public static func outbound(_ action: SettingsState.Action) -> OutboundAction {
        switch action {
        case .query: .configQuery
        case .update(let key, let value): .configUpdate(key: key, value: value)
        }
    }

    public static func outbound(_ action: FrontendExtensionViewContext.Action) -> OutboundAction {
        switch action {
        case .invoke(let extensionID, let action, let payload): .extensionAction(extensionID: extensionID, action: action, payload: payload)
        }
    }
}

private extension UInt32 {
    var bigEndianData: Data {
        Data([
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ])
    }
}
