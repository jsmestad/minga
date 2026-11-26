package protocol

import (
	"fmt"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func decodeChrome(payload []byte) (ChromePayload, bool, error) {
	opcode := payload[0]
	chrome := ChromePayload{Opcode: opcode, Name: opcodeName(opcode), Bytes: len(payload)}

	switch opcode {
	case generated.OPGuiTabBar:
		chrome.Tabs, chrome.Summary, chrome.Bytes = decodeTabBar(payload)
	case generated.OPGuiWorkspaces:
		chrome.Spaces, chrome.Summary, chrome.Bytes = decodeWorkspaces(payload)
	case generated.OPGuiMinibuffer:
		chrome.Mini, chrome.Summary, chrome.Bytes = decodeMinibuffer(payload)
	case generated.OPGuiCompletion:
		chrome.Complete, chrome.Summary, chrome.Bytes = decodeCompletion(payload)
	case generated.OPGuiWhichKey:
		chrome.Which, chrome.Summary, chrome.Bytes = decodeWhichKey(payload)
	case generated.OPGuiPicker:
		chrome.Picker, chrome.Summary, chrome.Bytes = decodePicker(payload)
	case generated.OPGuiPickerPreview:
		chrome.Preview, chrome.Summary, chrome.Bytes = decodePickerPreview(payload)
	case generated.OPGuiFileTree:
		chrome.Tree, chrome.Summary, chrome.Bytes = decodeFileTree(payload)
	case generated.OPGuiStatusBar:
		var err error
		chrome.Status, chrome.Summary, chrome.Bytes, err = decodeStatus(payload)
		if err != nil {
			return ChromePayload{}, true, err
		}
	case generated.OPGuiTheme:
		chrome.Theme, chrome.Summary, chrome.Bytes = decodeTheme(payload)
	case generated.OPGuiBreadcrumb:
		chrome.Breadcrumb, chrome.Summary, chrome.Bytes = decodeBreadcrumb(payload)
	case generated.OPGuiGitStatus:
		chrome.Git, chrome.Summary, chrome.Bytes = decodeGitStatus(payload)
	case generated.OPGuiSearchState:
		chrome.Search, chrome.Summary, chrome.Bytes = decodeSearchState(payload)
	case generated.OPGuiHoverPopup:
		chrome.Hover, chrome.Summary, chrome.Bytes = decodeHoverPopup(payload)
	case generated.OPGuiHoverAction:
		chrome.HoverAction, chrome.Summary, chrome.Bytes = decodeHoverAction(payload)
	case generated.OPGuiSignatureHelp:
		chrome.Signature, chrome.Summary, chrome.Bytes = decodeSignatureHelp(payload)
	case generated.OPGuiFloatPopup:
		chrome.Float, chrome.Summary, chrome.Bytes = decodeFloatPopup(payload)
	case generated.OPGuiExtensionOverlay:
		chrome.Overlay, chrome.Summary, chrome.Bytes = decodeExtensionOverlay(payload)
	case generated.OPGuiNotifications:
		chrome.Notifications, chrome.Summary, chrome.Bytes = decodeNotifications(payload)
	case generated.OPGuiBottomPanel:
		chrome.Bottom, chrome.Summary, chrome.Bytes = decodeBottomPanel(payload)
	case generated.OPGuiExtensionPanel:
		chrome.Extensions, chrome.Summary, chrome.Bytes = decodeExtensionPanel(payload)
	case generated.OPGuiSidebars:
		chrome.Sidebars, chrome.Summary, chrome.Bytes = decodeSidebars(payload)
	case generated.OPGuiObservatory:
		chrome.Observatory, chrome.Summary, chrome.Bytes = decodeObservatory(payload)
	case generated.OPGuiAgentContext:
		chrome.AgentContext, chrome.Summary, chrome.Bytes = decodeAgentContext(payload)
	case generated.OPGuiAgentChat:
		chrome.AgentChat, chrome.Summary, chrome.Bytes = decodeAgentChat(payload)
	case generated.OPGuiAgentHelp:
		var err error
		chrome.AgentHelp, chrome.Bytes, err = decodeAgentHelp(payload)
		if err != nil {
			return ChromePayload{}, true, err
		}
		chrome.Summary = "agent help"
	case generated.OPGuiAgentQueue:
		size := payloadLen32Size(payload)
		if size == 0 {
			return ChromePayload{}, true, fmt.Errorf("malformed gui_agent_queue: truncated payload")
		}
		queue, end, err := generated.DecodeGuiAgentQueueFields(payload, 5, size)
		if err != nil {
			return ChromePayload{}, true, fmt.Errorf("malformed gui_agent_queue: %w", err)
		}
		if end != size || queue.Visible > 1 || queue.Focused > 1 {
			return ChromePayload{}, true, fmt.Errorf("malformed gui_agent_queue: invalid flag or trailing data")
		}
		for _, rows := range [2][]generated.AgentQueueRow{queue.Pending, queue.Removed} {
			for _, row := range rows {
				if row.ID == 0 || row.Revision == 0 || row.Kind > 1 {
					return ChromePayload{}, true, fmt.Errorf("malformed gui_agent_queue: invalid row")
				}
			}
		}
		chrome.AgentQueue, chrome.Summary, chrome.Bytes = queue, "agent queue", size
	case generated.OPGuiAgentTranscript:
		chrome.AgentTranscript, chrome.Summary, chrome.Bytes = decodeAgentTranscript(payload)
	case generated.OPGuiEditTimeline:
		chrome.Timeline, chrome.Summary, chrome.Bytes = decodeEditTimeline(payload)
	case generated.OPGuiTasksDrawer:
		size := payloadLen32Size(payload)
		if size == 0 {
			return ChromePayload{}, true, fmt.Errorf("malformed gui_tasks_drawer: truncated payload")
		}
		drawer, _, err := generated.DecodeGuiTasksDrawerFields(payload, 5, size)
		if err != nil {
			return ChromePayload{}, true, err
		}
		chrome.TasksDrawer, chrome.Summary, chrome.Bytes = drawer, "tasks drawer", size
	case generated.OPGuiGutterSep:
		chrome.Gutter, chrome.Summary, chrome.Bytes = decodeGutterSeparator(payload)
	case generated.OPGuiCursorline:
		chrome.CursorlineChrome, chrome.Summary, chrome.Bytes = decodeCursorlineChrome(payload)
	case generated.OPGuiGutter:
		chrome.WindowGutter, chrome.Summary, chrome.Bytes = decodeGutter(payload)
	case generated.OPGuiIndentGuides:
		chrome.IndentGuides, chrome.Summary, chrome.Bytes = decodeIndentGuides(payload)
	case generated.OPGuiFileTreeSelection:
		chrome.FileTreeSelection, chrome.Summary, chrome.Bytes = decodeFileTreeSelection(payload)
	case generated.OPGuiCompletionSelection:
		chrome.CompletionSelection, chrome.Summary, chrome.Bytes = decodeCompletionSelection(payload)
	case generated.OPGuiPickerSelection:
		chrome.PickerSelection, chrome.Summary, chrome.Bytes = decodePickerSelection(payload)
	case generated.OPGuiFocusOwner:
		size := payloadLen16Size(payload)
		if size != 13 {
			return ChromePayload{}, true, fmt.Errorf("malformed gui_focus_owner: expected 10-byte payload")
		}
		owner, _, err := generated.DecodeGuiFocusOwnerFields(payload, 3, size)
		if err != nil {
			return ChromePayload{}, true, err
		}
		chrome.FocusOwner, chrome.Summary, chrome.Bytes = owner, "committed focus owner", size
	case generated.OPGuiSplitSeparators:
		chrome.Splits, chrome.Summary, chrome.Bytes = decodeSplitSeparators(payload)
	case generated.OPGuiSurfaceLayout:
		chrome.Placements, chrome.Summary, chrome.Bytes = decodeSurfaceLayout(payload)
	case generated.OPGuiEmptyState:
		chrome.EmptyState, chrome.Summary, chrome.Bytes = decodeEmptyState(payload)
	default:
		return ChromePayload{}, false, nil
	}

	return chrome, true, nil
}
