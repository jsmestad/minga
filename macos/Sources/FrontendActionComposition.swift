import Foundation

/// Translates consumer-owned view actions into the canonical outbound protocol action.
nonisolated public enum FrontendActionComposition {
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
        case .toolApproval(let approval): outbound(approval)
        case .executeCommand(let name): .executeCommand(name: name)
        case .agentToolToggle(let messageID): .agentToolToggle(messageID: messageID)
        case .agentReadRetainedOutput(let messageID, let offer): .agentReadRetainedOutput(messageID: messageID, offer: offer)
        case .composerSubmit(let generation, let offer): .agentComposerSubmit(generation: generation, offer: offer)
        case .composerQueue(let generation, let offer, let followUp, let target):
            .agentComposerQueue(generation: generation, offer: offer, followUp: followUp, target: target)
        case .openQuestion(let offer): .agentOpenQuestion(offer: offer)
        case .stopTurn(let target): .agentStopTurn(target)
        case .startRemedy(let kind): .agentStartRemedy(kind)
        case .chatScrolledAwayFromBottom: .chatScrolledAwayFromBottom
        case .chatReturnedToBottom: .chatReturnedToBottom
        }
    }
    public static func outbound(_ action: AgentApprovalCard.Action) -> OutboundAction {
        switch action {
        case .approve(let sessionId, let requestId, let toolCallId):
            .agentToolApproval(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId, decision: .approve)
        case .trustSession(let sessionId, let requestId, let toolCallId):
            .agentToolApproval(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId, decision: .approveSession)
        case .trustTurn(let sessionId, let requestId, let toolCallId):
            .agentToolApproval(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId, decision: .approveTurn)
        case .deny(let sessionId, let requestId, let toolCallId):
            .agentToolApproval(sessionId: sessionId, requestId: requestId, toolCallId: toolCallId, decision: .reject)
        }
    }


    public static func outbound(_ action: WhichKeyOverlay.Action) -> OutboundAction {
        switch action {
        case .press(let path, let codepoint, let modifiers): .whichKeyPress(path: path, codepoint: codepoint, modifiers: modifiers)
        case .back(let path): .whichKeyBack(path: path)
        }
    }

    public static func outbound(_ action: AgentHelpView.Action) -> OutboundAction {
        switch action {
        case .dismiss: .executeCommand(name: "agent_dismiss_help")
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
        case .navigate(let generation, let entryID): .semanticItemActivate(surface: .timeline, intent: 1, generation: generation, itemID: Data(entryID.utf8))
        case .reviewFile(let generation, let path): .semanticItemActivate(surface: .timeline, intent: 2, generation: generation, itemID: Data(path.utf8))
        case .browseFiles: .executeCommand(name: "timeline_browse_files")
        }
    }

    public static func outbound(_ action: BottomPanelView.Action) -> OutboundAction {
        switch action {
        case .dismiss: .panelDismiss
        case .resize(let heightPercent): .panelResize(heightPercent: heightPercent)
        case .openFile(let path): .openFile(path: path)
        }
    }

    public static func outbound(_ action: TasksDrawerView.Action) -> OutboundAction {
        switch action {
        case .rowAction(let rowID, let action): .tasksDrawerAction(rowID: rowID, action: action)
        case .runCommand(let name): .executeCommand(name: name)
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
        case .reviewBack(let generation, let itemID):
            .semanticItemActivate(surface: .review, intent: 1, generation: generation, itemID: Data(itemID.utf8))
        case .reviewLatest(let generation, let itemID):
            .semanticItemActivate(surface: .review, intent: 2, generation: generation, itemID: Data(itemID.utf8))
        case .reviewKeepMine(let generation, let itemID):
            .semanticItemActivate(surface: .review, intent: 3, generation: generation, itemID: Data(itemID.utf8))
        case .reviewUseAgentVersion(let generation, let itemID):
            .semanticItemActivate(surface: .review, intent: 4, generation: generation, itemID: Data(itemID.utf8))
        }
    }

    public static func outbound(_ action: MinibufferView.Action) -> OutboundAction {
        switch action {
        case .select(let generation, let itemID): .semanticItemActivate(surface: .commandCompletion, intent: 1, generation: generation, itemID: Data(itemID.utf8))
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
        case .fitChanged(let generation, let rows): .pickerFit(generation: generation, rows: rows)
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
        case .newFile(let generation, let parentID): .semanticItemActivate(surface: .fileTree, intent: 7, generation: generation, itemID: Data(parentID.utf8))
        case .newFolder(let generation, let parentID): .semanticItemActivate(surface: .fileTree, intent: 8, generation: generation, itemID: Data(parentID.utf8))
        case .refresh: .fileTreeRefresh
        case .collapseAll: .fileTreeCollapseAll
        }
    }

    public static func outbound(_ action: FileTreeView.Action) -> OutboundAction {
        switch action {
        case .editConfirm(let token, let text): .fileTreeEditConfirm(token: token, text: text)
        case .editCancel: .fileTreeEditCancel
        case .drop(let sourcePaths, let targetIndex, let targetID, let targetPathHash, let targetPath, let targetIsDirectory, let modifiers, let generation): .fileTreeDrop(sourcePaths: sourcePaths, targetIndex: targetIndex, targetID: targetID, targetPathHash: targetPathHash, targetPath: targetPath, targetIsDirectory: targetIsDirectory, modifiers: modifiers, generation: generation)
        case .refresh: .fileTreeRefresh
        case .semantic(let intent, let generation, let itemID): .semanticItemActivate(surface: .fileTree, intent: intent.rawValue, generation: generation, itemID: Data(itemID.utf8))
        case .executeCommand(let name): .executeCommand(name: name)
        }
    }

    public static func outbound(_ action: GitStatusView.Action) -> OutboundAction {
        switch action {
        case .discardFile(let target): .gitDiscardFile(target)
        case .unstageAll(let panelID): .gitUnstageAll(panelID: panelID)
        case .stageAll(let panelID): .gitStageAll(panelID: panelID)
        case .openFile(let target): .gitOpenFile(target)
        case .openDiff(let target): .gitOpenDiff(target)
        case .stageFile(let target): .gitStageFile(target)
        case .unstageFile(let target): .gitUnstageFile(target)
        case .pull(let panelID): .gitPull(panelID: panelID)
        case .push(let panelID): .gitPush(panelID: panelID)
        case .fetch(let panelID): .gitFetch(panelID: panelID)
        case .commit(let panelID, let message): .gitCommit(panelID: panelID, message: message)
        case .amend(let panelID, let message): .gitCommitAmend(panelID: panelID, message: message)
        case .pullAndRetry(let toastID): .gitPullAndRetry(toastID: toastID)
        case .executeCommand(let name): .executeCommand(name: name)
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
    nonisolated var bigEndianData: Data {
        Data([
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF)
        ])
    }
}
