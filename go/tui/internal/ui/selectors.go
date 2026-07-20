package ui

import "github.com/jsmestad/minga/go/tui/internal/protocol"

func (m Model) workspaceBar() (protocol.WorkspaceBar, bool) {
	for _, payload := range m.chrome {
		if len(payload.Spaces.Spaces) > 0 {
			return payload.Spaces, true
		}
	}
	return protocol.WorkspaceBar{}, false
}

func (m Model) tabBar() (protocol.TabBar, bool) {
	for _, payload := range m.chrome {
		if len(payload.Tabs.Tabs) > 0 {
			return payload.Tabs, true
		}
	}
	return protocol.TabBar{}, false
}

func (m Model) minibuffer() (protocol.Minibuffer, bool) {
	for _, payload := range m.chrome {
		if payload.Mini.Visible {
			return payload.Mini, true
		}
	}
	return protocol.Minibuffer{}, false
}

func (m Model) completion() (protocol.Completion, bool) {
	for _, payload := range m.chrome {
		if payload.Complete.Visible {
			return payload.Complete, true
		}
	}
	return protocol.Completion{}, false
}

func (m Model) whichKey() (protocol.WhichKey, bool) {
	for _, payload := range m.chrome {
		if payload.Which.Visible {
			return payload.Which, true
		}
	}
	return protocol.WhichKey{}, false
}

func (m Model) picker() (protocol.Picker, bool) {
	for _, payload := range m.chrome {
		if payload.Picker.Visible {
			return payload.Picker, true
		}
	}
	return protocol.Picker{}, false
}

func (m Model) pickerPreview() (protocol.PickerPreview, bool) {
	for _, payload := range m.chrome {
		if payload.Preview.Visible {
			return payload.Preview, true
		}
	}
	return protocol.PickerPreview{}, false
}

func (m Model) fileTree() (protocol.FileTree, bool) {
	for _, payload := range m.chrome {
		if payload.Tree.Visible || len(payload.Tree.Rows) > 0 {
			return payload.Tree, true
		}
	}
	return protocol.FileTree{}, false
}

func (m Model) statusBar() (protocol.StatusBar, bool) {
	for _, payload := range m.chrome {
		if payload.Status.Filename != "" || payload.Status.Message != "" || payload.Status.Operation != nil || payload.Status.Line != 0 || len(payload.Status.Left) > 0 || len(payload.Status.Right) > 0 {
			return payload.Status, true
		}
	}
	return protocol.StatusBar{}, false
}

func (m Model) windowGutter(windowID uint16) (protocol.Gutter, bool) {
	gutter, ok := m.gutters[windowID]
	if ok && (len(gutter.Entries) > 0 || gutter.LineNumberWidth > 0 || gutter.SignColWidth > 0) {
		return gutter, true
	}
	return protocol.Gutter{}, false
}

func (m Model) breadcrumb() (protocol.Breadcrumb, bool) {
	for _, payload := range m.chrome {
		if len(payload.Breadcrumb.Segments) > 0 {
			return payload.Breadcrumb, true
		}
	}
	return protocol.Breadcrumb{}, false
}

func (m Model) gitStatus() (protocol.GitStatus, bool) {
	for _, payload := range m.chrome {
		if payload.Git.Branch != "" || len(payload.Git.Entries) > 0 {
			return payload.Git, true
		}
	}
	return protocol.GitStatus{}, false
}

func (m Model) searchState() (protocol.SearchState, bool) {
	for _, payload := range m.chrome {
		if payload.Search.Active {
			return payload.Search, true
		}
	}
	return protocol.SearchState{}, false
}

func (m Model) changeSummary() (protocol.ChangeSummary, bool) {
	for _, payload := range m.chrome {
		if payload.Change.Visible || len(payload.Change.Entries) > 0 {
			return payload.Change, true
		}
	}
	return protocol.ChangeSummary{}, false
}

func (m Model) hoverPopup() (protocol.HoverPopup, bool) {
	for _, payload := range m.chrome {
		if payload.Hover.Visible {
			return payload.Hover, true
		}
	}
	return protocol.HoverPopup{}, false
}

func (m Model) hoverAction() (protocol.HoverAction, bool) {
	for _, payload := range m.chrome {
		if payload.HoverAction.Visible {
			return payload.HoverAction, true
		}
	}
	return protocol.HoverAction{}, false
}

func (m Model) signatureHelp() (protocol.SignatureHelp, bool) {
	for _, payload := range m.chrome {
		if payload.Signature.Visible {
			return payload.Signature, true
		}
	}
	return protocol.SignatureHelp{}, false
}

func (m Model) floatPopup() (protocol.FloatPopup, bool) {
	for _, payload := range m.chrome {
		if payload.Float.Visible {
			return payload.Float, true
		}
	}
	return protocol.FloatPopup{}, false
}

func (m Model) extensionOverlay() (protocol.ExtensionOverlay, bool) {
	for _, payload := range m.chrome {
		if len(payload.Overlay.Entries) > 0 {
			return payload.Overlay, true
		}
	}
	return protocol.ExtensionOverlay{}, false
}

func (m Model) notifications() (protocol.Notifications, bool) {
	for _, payload := range m.chrome {
		if payload.Notifications.Visible || len(payload.Notifications.Items) > 0 {
			return payload.Notifications, true
		}
	}
	return protocol.Notifications{}, false
}

func (m Model) bottomPanel() (protocol.BottomPanel, bool) {
	for _, payload := range m.chrome {
		if payload.Bottom.Visible {
			return payload.Bottom, true
		}
	}
	return protocol.BottomPanel{}, false
}

func (m Model) extensionPanel() (protocol.ExtensionPanel, bool) {
	for _, payload := range m.chrome {
		if len(payload.Extensions.Panels) > 0 {
			return payload.Extensions, true
		}
	}
	return protocol.ExtensionPanel{}, false
}

func (m Model) sidebars() (protocol.Sidebars, bool) {
	for _, payload := range m.chrome {
		if payload.Sidebars.Visible || len(payload.Sidebars.Items) > 0 {
			return payload.Sidebars, true
		}
	}
	return protocol.Sidebars{}, false
}

func (m Model) observatory() (protocol.Observatory, bool) {
	for _, payload := range m.chrome {
		if payload.Observatory.Visible || len(payload.Observatory.Nodes) > 0 {
			return payload.Observatory, true
		}
	}
	return protocol.Observatory{}, false
}

func (m Model) agentContext() (protocol.AgentContext, bool) {
	for _, payload := range m.chrome {
		if payload.AgentContext.Visible || payload.AgentContext.Task != "" {
			return payload.AgentContext, true
		}
	}
	return protocol.AgentContext{}, false
}

func (m Model) agentChat() (protocol.AgentChat, bool) {
	for _, payload := range m.chrome {
		if payload.AgentChat.Visible {
			return payload.AgentChat, true
		}
	}
	return protocol.AgentChat{}, false
}

func (m Model) agentChatVisible() bool {
	chat, ok := m.agentChat()
	return ok && chat.Visible
}

func (m Model) editTimeline() (protocol.EditTimeline, bool) {
	for _, payload := range m.chrome {
		if payload.Timeline.Visible {
			return payload.Timeline, true
		}
	}
	return protocol.EditTimeline{}, false
}

func (m Model) emptyState() (protocol.EmptyState, bool) {
	for _, payload := range m.chrome {
		if payload.EmptyState.Visible {
			return payload.EmptyState, true
		}
	}
	return protocol.EmptyState{}, false
}

func (m Model) splitSeparators() (protocol.SplitSeparators, bool) {
	for _, payload := range m.chrome {
		if len(payload.Splits.Verticals) > 0 || len(payload.Splits.Horizontals) > 0 {
			return payload.Splits, true
		}
	}
	return protocol.SplitSeparators{}, false
}
