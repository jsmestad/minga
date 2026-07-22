package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestSemanticFrontendOpcodesAreAccountedFor(t *testing.T) {
	classifications := map[byte]string{
		generated.OPGuiTabBar:              "rendered header",
		generated.OPGuiWhichKey:            "rendered overlay",
		generated.OPGuiCompletion:          "rendered overlay",
		generated.OPGuiTheme:               "stateful renderer theme",
		generated.OPGuiBreadcrumb:          "rendered fallback header",
		generated.OPGuiStatusBar:           "rendered footer/modeline",
		generated.OPGuiPicker:              "rendered overlay",
		generated.OPGuiAgentChat:           "rendered overlay",
		generated.OPGuiGutterSep:           "decoded compatibility chrome",
		generated.OPGuiCursorline:          "rendered fallback cursorline",
		generated.OPGuiGutter:              "rendered window gutter",
		generated.OPGuiBottomPanel:         "rendered overlay",
		generated.OPGuiPickerPreview:       "rendered picker sidecar",
		generated.OPGuiMinibuffer:          "rendered footer overlay",
		generated.OPGuiWindowContent:       "rendered window content",
		generated.OPGuiHoverPopup:          "rendered overlay",
		generated.OPGuiSignatureHelp:       "rendered overlay",
		generated.OPGuiFloatPopup:          "rendered overlay",
		generated.OPGuiSplitSeparators:     "rendered content separators",
		generated.OPGuiGitStatus:           "rendered header/status",
		generated.OPGuiAgentContext:        "rendered overlay",
		generated.OPGuiHoverAction:         "rendered hover sidecar",
		generated.OPGuiConfigState:         "intentional TUI no-op state",
		generated.OPGuiWorkspaces:          "rendered header",
		generated.OPGuiNotifications:       "rendered overlay",
		generated.OPGuiObservatory:         "rendered overlay",
		generated.OPGuiEditTimeline:        "rendered overlay",
		generated.OPGuiExtensionOverlay:    "rendered overlay",
		generated.OPGuiExtensionPanel:      "rendered overlay",
		generated.OPGuiSearchState:         "rendered footer status",
		generated.OPGuiSidebars:            "rendered content sidebars",
		generated.OPGuiWindowOverlayDelta:  "stateful window delta",
		generated.OPGuiWindowViewportDelta: "stateful window delta",
		generated.OPGuiWindowRowsDelta:     "stateful window delta",
		generated.OPGuiIndentGuides:        "rendered window indent guides",
		generated.OPGuiLineSpacing:         "intentional TUI no-op state",
		generated.OPGuiFileTree:            "rendered content sidebar",
		generated.OPGuiFileTreeSelection:   "stateful file tree selection",
		generated.OPGuiCursorAnimation:     "intentional TUI no-op state",
	}
	payloads := map[byte][]byte{
		generated.OPGuiTabBar:              {generated.OPGuiTabBar, 0, 0},
		generated.OPGuiWhichKey:            {generated.OPGuiWhichKey, 0},
		generated.OPGuiCompletion:          {generated.OPGuiCompletion, 0},
		generated.OPGuiTheme:               {generated.OPGuiTheme, 0},
		generated.OPGuiBreadcrumb:          {generated.OPGuiBreadcrumb, 0},
		generated.OPGuiStatusBar:           {generated.OPGuiStatusBar, 0},
		generated.OPGuiPicker:              {generated.OPGuiPicker, 0},
		generated.OPGuiAgentChat:           {generated.OPGuiAgentChat, 0},
		generated.OPGuiGutterSep:           {generated.OPGuiGutterSep, 0, 0, 0, 0, 0},
		generated.OPGuiCursorline:          {generated.OPGuiCursorline, 0xFF, 0xFF, 0, 0, 0},
		generated.OPGuiGutter:              {generated.OPGuiGutter, 0},
		generated.OPGuiBottomPanel:         {generated.OPGuiBottomPanel, 0},
		generated.OPGuiPickerPreview:       {generated.OPGuiPickerPreview, 0},
		generated.OPGuiMinibuffer:          {generated.OPGuiMinibuffer, 0},
		generated.OPGuiWindowContent:       semanticWindowContent(),
		generated.OPGuiHoverPopup:          {generated.OPGuiHoverPopup, 0},
		generated.OPGuiSignatureHelp:       {generated.OPGuiSignatureHelp, 0},
		generated.OPGuiFloatPopup:          {generated.OPGuiFloatPopup, 0},
		generated.OPGuiSplitSeparators:     {generated.OPGuiSplitSeparators, 0, 0, 0, 0},
		generated.OPGuiGitStatus:           {generated.OPGuiGitStatus, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		generated.OPGuiAgentContext:        {generated.OPGuiAgentContext, 0, 0},
		generated.OPGuiHoverAction:         {generated.OPGuiHoverAction, 0, 1, 0},
		generated.OPGuiConfigState:         {generated.OPGuiConfigState, 0, 0},
		generated.OPGuiWorkspaces:          {generated.OPGuiWorkspaces, 0, 6, 2, 0, 0, 0, 0, 0},
		generated.OPGuiNotifications:       {generated.OPGuiNotifications, 0, 3, 0, 0, 0},
		generated.OPGuiObservatory:         {generated.OPGuiObservatory, 0, 0, 0, 0, 0},
		generated.OPGuiEditTimeline:        {generated.OPGuiEditTimeline, 0, 4, 0, 0, 0, 0},
		generated.OPGuiExtensionOverlay:    {generated.OPGuiExtensionOverlay, 0, 2, 0, 0},
		generated.OPGuiExtensionPanel:      {generated.OPGuiExtensionPanel, 0, 1, 0},
		generated.OPGuiSearchState:         {generated.OPGuiSearchState, 0, 5, 0, 0, 0, 0, 0},
		generated.OPGuiSidebars:            {generated.OPGuiSidebars, 0, 0, 0, 0, 0},
		generated.OPGuiWindowOverlayDelta:  {generated.OPGuiWindowOverlayDelta, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0},
		generated.OPGuiWindowViewportDelta: append(append([]byte{generated.OPGuiWindowViewportDelta, 2}, section32Semantic(0x01, []byte{0, 8, 0x12, 0x34, 0x56, 0x78, 0x01, 0, 0, 0x02, 0, 2, 0, 0})...), section32Semantic(0x02, []byte{0, 0, 0, 0})...),
		generated.OPGuiWindowRowsDelta:     append(append([]byte{generated.OPGuiWindowRowsDelta, 2}, section32Semantic(0x01, []byte{0, 7, 0x12, 0x34, 0x56, 0x78, 0x00, 0, 0, 0x02, 0, 2, 0, 0})...), section32Semantic(0x02, []byte{0, 0, 0, 0})...),
		generated.OPGuiIndentGuides:        {generated.OPGuiIndentGuides, 0, 6, 0, 1, 2, 0xFF, 0xFF, 0},
		generated.OPGuiLineSpacing:         {generated.OPGuiLineSpacing, 0, 2, 0, 100},
		generated.OPGuiFileTree:            {generated.OPGuiFileTree, 0, 0, 0, 0},
		generated.OPGuiFileTreeSelection:   {generated.OPGuiFileTreeSelection, 0, 1, 0},
		generated.OPGuiCursorAnimation:     {generated.OPGuiCursorAnimation, 0, 1, 0},
	}

	for opcode := range payloads {
		if classifications[opcode] == "" {
			t.Fatalf("opcode 0x%02X has payload coverage but no semantic parity classification", opcode)
		}
	}
	for opcode, classification := range classifications {
		if classification == "" {
			t.Fatalf("opcode 0x%02X has empty semantic parity classification", opcode)
		}
		if _, ok := payloads[opcode]; !ok {
			t.Fatalf("opcode 0x%02X has semantic parity classification but no decode payload", opcode)
		}
	}

	for opcode, payload := range payloads {
		t.Run(opcodeName(opcode), func(t *testing.T) {
			command, err := DecodeCommand(payload)
			if err != nil {
				t.Fatalf("DecodeCommand returned error: %v", err)
			}
			if command.Size <= 0 {
				t.Fatalf("DecodeCommand returned non-positive size for opcode 0x%02X: %+v", opcode, command)
			}
		})
	}
}

func semanticWindowContent() []byte {
	header := []byte{0, 7, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	body := []byte{2}
	body = append(body, section32Semantic(0x01, header)...)
	body = append(body, section32Semantic(0x02, []byte{0, 0, 0, 0})...)
	result := []byte{generated.OPGuiWindowContent, 0, 0, 0, byte(len(body))}
	return append(result, body...)
}

func section32Semantic(id byte, payload []byte) []byte {
	section := []byte{id, 0, 0, 0, byte(len(payload))}
	return append(section, payload...)
}
