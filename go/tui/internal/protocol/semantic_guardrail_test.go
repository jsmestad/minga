package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestSemanticFrontendOpcodesAreAccountedFor(t *testing.T) {
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
		generated.OPGuiToolManager:         {generated.OPGuiToolManager, 0},
		generated.OPGuiMinibuffer:          {generated.OPGuiMinibuffer, 0},
		generated.OPGuiWindowContent:       {generated.OPGuiWindowContent, 0},
		generated.OPGuiHoverPopup:          {generated.OPGuiHoverPopup, 0},
		generated.OPGuiSignatureHelp:       {generated.OPGuiSignatureHelp, 0},
		generated.OPGuiFloatPopup:          {generated.OPGuiFloatPopup, 0},
		generated.OPGuiSplitSeparators:     {generated.OPGuiSplitSeparators, 0, 0, 0, 0},
		generated.OPGuiBoard:               append([]byte{generated.OPGuiBoard, 0, 1}, []byte{0}...),
		generated.OPGuiAgentContext:        {generated.OPGuiAgentContext, 0, 0},
		generated.OPGuiChangeSummary:       {generated.OPGuiChangeSummary, 0},
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
		generated.OPGuiWindowViewportDelta: {generated.OPGuiWindowViewportDelta, 0},
		generated.OPGuiWindowRowsDelta:     {generated.OPGuiWindowRowsDelta, 0},
		generated.OPGuiIndentGuides:        {generated.OPGuiIndentGuides, 0, 6, 0, 1, 2, 0xFF, 0xFF, 0},
		generated.OPGuiLineSpacing:         {generated.OPGuiLineSpacing, 0, 2, 0, 100},
		generated.OPGuiFileTree:            {generated.OPGuiFileTree, 0, 0, 0, 0},
		generated.OPGuiFileTreeSelection:   {generated.OPGuiFileTreeSelection, 0, 1, 0},
		generated.OPGuiCursorAnimation:     {generated.OPGuiCursorAnimation, 0, 1, 0},
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
