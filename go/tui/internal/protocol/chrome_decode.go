package protocol

import "github.com/jsmestad/minga/go/tui/internal/generated"

func decodeChrome(payload []byte) ChromePayload {
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
		chrome.Status, chrome.Summary, chrome.Bytes = decodeStatus(payload)
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
	case generated.OPGuiAgentTranscript:
		chrome.AgentTranscript, chrome.Summary, chrome.Bytes = decodeAgentTranscript(payload)
	case generated.OPGuiEditTimeline:
		chrome.Timeline, chrome.Summary, chrome.Bytes = decodeEditTimeline(payload)
	case generated.OPGuiGutterSep:
		chrome.Gutter, chrome.Summary, chrome.Bytes = decodeGutterSeparator(payload)
	case generated.OPGuiCursorline:
		chrome.CursorlineChrome, chrome.Summary, chrome.Bytes = decodeCursorlineChrome(payload)
	case generated.OPGuiGutter:
		chrome.WindowGutter, chrome.Summary, chrome.Bytes = decodeGutter(payload)
	case generated.OPGuiIndentGuides:
		chrome.IndentGuides, chrome.Summary, chrome.Bytes = decodeIndentGuides(payload)
	case generated.OPGuiLineSpacing:
		chrome.LineSpacing, chrome.Summary, chrome.Bytes = decodeLineSpacing(payload)
	case generated.OPGuiFileTreeSelection:
		chrome.FileTreeSelection, chrome.Summary, chrome.Bytes = decodeFileTreeSelection(payload)
	case generated.OPGuiCursorAnimation:
		chrome.CursorAnimation, chrome.Summary, chrome.Bytes = decodeCursorAnimation(payload)
	case generated.OPGuiConfigState:
		chrome.ConfigState, chrome.Summary, chrome.Bytes = decodeConfigState(payload)
	case generated.OPGuiSplitSeparators:
		chrome.Splits, chrome.Summary, chrome.Bytes = decodeSplitSeparators(payload)
	case generated.OPGuiSurfaceLayout:
		chrome.Placements, chrome.Summary, chrome.Bytes = decodeSurfaceLayout(payload)
	case generated.OPGuiEmptyState:
		chrome.EmptyState, chrome.Summary, chrome.Bytes = decodeEmptyState(payload)
	default:
		// Size unhandled chrome through the schema authority; fall back to the
		// sectioned envelope only if the opcode is not generically sized.
		if size, status := generated.CommandSize(payload); status == generated.CommandSizeOK {
			chrome.Bytes = size
		} else if size := sectionedSize(payload); size > 0 {
			chrome.Bytes = size
		}
	}

	return chrome
}
