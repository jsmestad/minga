package protocol

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestSemanticFrontendOpcodesAreAccountedFor(t *testing.T) {
	classifications := map[byte]string{
		generated.OPBeginFrame:              "frame transaction begin",
		generated.OPCommitFrame:             "frame transaction commit",
		generated.OPSetCursorShape:          "terminal cursor shape",
		generated.OPSetTitle:                "terminal title",
		generated.OPSetWindowBg:             "terminal background",
		generated.OPSetLinkCursor:           "Terminal does not expose native pointer cursor shapes",
		generated.OPApplicationQuitResponse: "Native application quit negotiation is not used by the TUI",
		generated.OPPresentationTarget:      "Native presentation targeting is not used by the TUI",
		generated.OPPresentationOperation:   "Native presentation operations are not used by the TUI",
		generated.OPProtocolError:           "blocking protocol error",
		generated.OPSetFont:                 "Terminal controls font selection",
		generated.OPSetFontFallback:         "Terminal controls font fallback",
		generated.OPRegisterFont:            "Terminal controls font registration",
		generated.OPClipboardWrite:          "terminal clipboard write",
		generated.OPGuiAgentTranscript:      "resident agent transcript",
		generated.OPGuiRequest:              "Native file dialogs are not used by the TUI",
		generated.OPGuiExtensionRuntime:     "extension runtime dispatch",
		generated.OPGuiSurfaceLayout:        "authoritative surface placements",
		generated.OPGuiEmptyState:           "rendered launchpad",
		generated.OPGuiCompletionSelection:  "stateful completion selection",
		generated.OPGuiPickerSelection:      "stateful picker selection",
		generated.OPGuiTextPresentation:     "immutable text presentation",
		generated.OPGuiResidentSemantics:    "resident semantic layers",
		generated.OPGuiTabBar:               "rendered header",
		generated.OPGuiWhichKey:             "rendered overlay",
		generated.OPGuiCompletion:           "rendered overlay",
		generated.OPGuiTheme:                "stateful renderer theme",
		generated.OPGuiBreadcrumb:           "rendered fallback header",
		generated.OPGuiStatusBar:            "rendered footer/modeline",
		generated.OPGuiPicker:               "rendered overlay",
		generated.OPGuiAgentChat:            "rendered overlay",
		generated.OPGuiGutterSep:            "decoded compatibility chrome",
		generated.OPGuiCursorline:           "rendered fallback cursorline",
		generated.OPGuiGutter:               "rendered window gutter",
		generated.OPGuiBottomPanel:          "rendered overlay",
		generated.OPGuiPickerPreview:        "rendered picker sidecar",
		generated.OPGuiMinibuffer:           "rendered footer overlay",
		generated.OPGuiWindowContent:        "rendered window content",
		generated.OPGuiHoverPopup:           "rendered overlay",
		generated.OPGuiSignatureHelp:        "rendered overlay",
		generated.OPGuiFloatPopup:           "rendered overlay",
		generated.OPGuiSplitSeparators:      "rendered content separators",
		generated.OPGuiGitStatus:            "rendered header/status",
		generated.OPGuiAgentContext:         "rendered overlay",
		generated.OPGuiHoverAction:          "rendered hover sidecar",
		generated.OPGuiConfigState:          "Native settings state is not used by the TUI",
		generated.OPGuiWorkspaces:           "rendered header",
		generated.OPGuiNotifications:        "rendered overlay",
		generated.OPGuiObservatory:          "rendered overlay",
		generated.OPGuiEditTimeline:         "rendered overlay",
		generated.OPGuiExtensionOverlay:     "rendered overlay",
		generated.OPGuiExtensionPanel:       "rendered overlay",
		generated.OPGuiSearchState:          "rendered footer status",
		generated.OPGuiSidebars:             "rendered content sidebars",
		generated.OPGuiWindowOverlayDelta:   "stateful window delta",
		generated.OPGuiWindowViewportDelta:  "stateful window delta",
		generated.OPGuiWindowRowsDelta:      "stateful window delta",
		generated.OPGuiIndentGuides:         "rendered window indent guides",
		generated.OPGuiLineSpacing:          "Terminal controls line spacing",
		generated.OPGuiFileTree:             "rendered content sidebar",
		generated.OPGuiFileTreeSelection:    "stateful file tree selection",
		generated.OPGuiCursorAnimation:      "Terminal controls cursor animation",
	}
	payloads := map[byte][]byte{
		generated.OPBeginFrame:              {generated.OPBeginFrame, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1},
		generated.OPCommitFrame:             {generated.OPCommitFrame, 0, 0, 0, 1, 0, 0, 0, 0},
		generated.OPSetCursorShape:          {generated.OPSetCursorShape, 0},
		generated.OPSetTitle:                {generated.OPSetTitle, 0, 0},
		generated.OPSetWindowBg:             {generated.OPSetWindowBg, 0, 0, 0},
		generated.OPSetLinkCursor:           {generated.OPSetLinkCursor, 0},
		generated.OPApplicationQuitResponse: {generated.OPApplicationQuitResponse, 0, 11, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0},
		generated.OPPresentationTarget:      {generated.OPPresentationTarget, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0},
		generated.OPPresentationOperation:   {generated.OPPresentationOperation, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0},
		generated.OPProtocolError:           {generated.OPProtocolError, 0, 0},
		generated.OPSetFont:                 {generated.OPSetFont, 0, 12, 0, 0, 0, 0},
		generated.OPSetFontFallback:         {generated.OPSetFontFallback, 0},
		generated.OPRegisterFont:            {generated.OPRegisterFont, 0, 0, 0},
		generated.OPClipboardWrite:          {generated.OPClipboardWrite, 0, 0, 0, 5, 0, 0, 0, 0, 0},
		generated.OPGuiAgentTranscript:      {generated.OPGuiAgentTranscript, 0, 0, 0, 11, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0},
		generated.OPGuiRequest:              {generated.OPGuiRequest, 0, 7, 0, 0, 0, 1, 0, 0, 0},
		generated.OPGuiExtensionRuntime:     {generated.OPGuiExtensionRuntime, 0, 0, 0, 4, 0, 0, 0, 0},
		generated.OPGuiSurfaceLayout:        {generated.OPGuiSurfaceLayout, 1, 1, 0, 2, 0, 0},
		generated.OPGuiEmptyState:           {generated.OPGuiEmptyState, 0, 1, 0},
		generated.OPGuiCompletionSelection:  {generated.OPGuiCompletionSelection, 0, 7, 0, 0, 0, 1, 0, 0, 0},
		generated.OPGuiPickerSelection:      {generated.OPGuiPickerSelection, 0, 12, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0},
		generated.OPGuiTextPresentation:     {generated.OPGuiTextPresentation, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1},
		generated.OPGuiResidentSemantics:    semanticResidentSemantics(),
		generated.OPGuiTabBar:               {generated.OPGuiTabBar, 0, 0},
		generated.OPGuiWhichKey:             {generated.OPGuiWhichKey, 0},
		generated.OPGuiCompletion:           {generated.OPGuiCompletion, 0},
		generated.OPGuiTheme:                {generated.OPGuiTheme, 0},
		generated.OPGuiBreadcrumb:           {generated.OPGuiBreadcrumb, 0},
		generated.OPGuiStatusBar:            {generated.OPGuiStatusBar, 0},
		generated.OPGuiPicker:               {generated.OPGuiPicker, 0},
		generated.OPGuiAgentChat:            {generated.OPGuiAgentChat, 0},
		generated.OPGuiGutterSep:            {generated.OPGuiGutterSep, 0, 0, 0, 0, 0},
		generated.OPGuiCursorline:           {generated.OPGuiCursorline, 0xFF, 0xFF, 0, 0, 0},
		generated.OPGuiGutter:               {generated.OPGuiGutter, 0},
		generated.OPGuiBottomPanel:          {generated.OPGuiBottomPanel, 0},
		generated.OPGuiPickerPreview:        {generated.OPGuiPickerPreview, 0},
		generated.OPGuiMinibuffer:           {generated.OPGuiMinibuffer, 0},
		generated.OPGuiWindowContent:        semanticWindowContent(),
		generated.OPGuiHoverPopup:           {generated.OPGuiHoverPopup, 0},
		generated.OPGuiSignatureHelp:        {generated.OPGuiSignatureHelp, 0},
		generated.OPGuiFloatPopup:           {generated.OPGuiFloatPopup, 0},
		generated.OPGuiSplitSeparators:      {generated.OPGuiSplitSeparators, 0, 0, 0, 0},
		generated.OPGuiGitStatus:            {generated.OPGuiGitStatus, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		generated.OPGuiAgentContext:         {generated.OPGuiAgentContext, 0, 0},
		generated.OPGuiHoverAction:          {generated.OPGuiHoverAction, 0, 1, 0},
		generated.OPGuiConfigState:          {generated.OPGuiConfigState, 0, 0},
		generated.OPGuiWorkspaces:           {generated.OPGuiWorkspaces, 0, 6, 2, 0, 0, 0, 0, 0},
		generated.OPGuiNotifications:        {generated.OPGuiNotifications, 0, 3, 0, 0, 0},
		generated.OPGuiObservatory:          {generated.OPGuiObservatory, 0, 0, 0, 0},
		generated.OPGuiEditTimeline:         {generated.OPGuiEditTimeline, 0, 4, 0, 0, 0, 0},
		generated.OPGuiExtensionOverlay:     {generated.OPGuiExtensionOverlay, 0, 2, 0, 0},
		generated.OPGuiExtensionPanel:       {generated.OPGuiExtensionPanel, 0, 1, 0},
		generated.OPGuiSearchState:          {generated.OPGuiSearchState, 0, 21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		generated.OPGuiSidebars:             {generated.OPGuiSidebars, 0, 0, 0, 0},
		generated.OPGuiWindowOverlayDelta:   {generated.OPGuiWindowOverlayDelta, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0},
		generated.OPGuiWindowViewportDelta:  append(append([]byte{generated.OPGuiWindowViewportDelta, 2}, section32Semantic(0x01, []byte{0, 8, 0x12, 0x34, 0x56, 0x78, 0x01, 0, 0, 0x02, 0, 2, 0, 0})...), section32Semantic(0x02, []byte{0, 0, 0, 0})...),
		generated.OPGuiWindowRowsDelta:      append(append([]byte{generated.OPGuiWindowRowsDelta, 2}, section32Semantic(0x01, []byte{0, 7, 0x12, 0x34, 0x56, 0x78, 0x00, 0, 0, 0x02, 0, 2, 0, 0})...), section32Semantic(0x02, []byte{0, 0, 0, 0})...),
		generated.OPGuiIndentGuides:         {generated.OPGuiIndentGuides, 0, 6, 0, 1, 2, 0xFF, 0xFF, 0},
		generated.OPGuiLineSpacing:          {generated.OPGuiLineSpacing, 0, 2, 0, 100},
		generated.OPGuiFileTree:             {generated.OPGuiFileTree, 0, 0, 0, 0},
		generated.OPGuiFileTreeSelection:    {generated.OPGuiFileTreeSelection, 0, 1, 0},
		generated.OPGuiCursorAnimation:      {generated.OPGuiCursorAnimation, 0, 1, 0},
	}

	schemaOpcodes := make(map[byte]struct{}, len(generated.GoRequiredOpcodes)+len(generated.GoSkippedOpcodes))
	for opcode, name := range generated.GoRequiredOpcodes {
		if name == "" {
			t.Fatalf("required opcode 0x%02X has no schema name", opcode)
		}
		schemaOpcodes[opcode] = struct{}{}
	}
	for opcode, reason := range generated.GoSkippedOpcodes {
		if _, required := generated.GoRequiredOpcodes[opcode]; required {
			t.Fatalf("opcode 0x%02X is both required and skipped", opcode)
		}
		if reason == "" {
			t.Fatalf("skipped opcode 0x%02X has no reason", opcode)
		}
		if classifications[opcode] != reason {
			t.Fatalf("skipped opcode 0x%02X classification = %q, want schema reason %q", opcode, classifications[opcode], reason)
		}
		schemaOpcodes[opcode] = struct{}{}
	}
	for opcode := range schemaOpcodes {
		if classifications[opcode] == "" {
			t.Fatalf("schema opcode %s (0x%02X) has no semantic parity classification", generated.GoRequiredOpcodes[opcode], opcode)
		}
		if _, ok := payloads[opcode]; !ok {
			t.Fatalf("schema opcode %s (0x%02X) has no decode payload", generated.GoRequiredOpcodes[opcode], opcode)
		}
	}
	for opcode, classification := range classifications {
		if _, ok := schemaOpcodes[opcode]; !ok {
			t.Fatalf("classified opcode 0x%02X is absent from the generated consumer contract", opcode)
		}
		if classification == "" {
			t.Fatalf("opcode 0x%02X has empty semantic parity classification", opcode)
		}
	}
	for opcode, payload := range payloads {
		if _, ok := schemaOpcodes[opcode]; !ok {
			t.Fatalf("payload opcode 0x%02X is absent from the generated consumer contract", opcode)
		}
		if len(payload) == 0 || payload[0] != opcode {
			t.Fatalf("opcode 0x%02X has mismatched decode payload %v", opcode, payload)
		}
	}

	for opcode, payload := range payloads {
		t.Run(opcodeName(opcode), func(t *testing.T) {
			command, err := DecodeCommand(payload)
			if err != nil {
				t.Fatalf("DecodeCommand returned error: %v", err)
			}
			if command.Size != len(payload) {
				t.Fatalf("DecodeCommand size = %d, want payload size %d for opcode 0x%02X", command.Size, len(payload), opcode)
			}
			if _, skipped := generated.GoSkippedOpcodes[opcode]; skipped {
				if command.Kind != CommandNoop {
					t.Fatalf("skipped opcode 0x%02X returned kind %v, want CommandNoop", opcode, command.Kind)
				}
				batch := append(append([]byte(nil), payload...), generated.OPCommitFrame, 0, 0, 0, 1, 0, 0, 0, 0)
				bounded, err := DecodeCommand(batch)
				if err != nil || bounded.Kind != CommandNoop || bounded.Size != len(payload) {
					t.Fatalf("skipped opcode 0x%02X swallowed the following command: command=%+v error=%v", opcode, bounded, err)
				}
			} else if command.Kind == CommandNoop {
				t.Fatalf("required opcode %s (0x%02X) silently returned CommandNoop", generated.GoRequiredOpcodes[opcode], opcode)
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

func semanticResidentSemantics() []byte {
	// Empty keyframe: version/mode/window, revisions/row extent/row identities,
	// flags/cursor, tab width/active guide, and three empty counted arrays.
	body := []byte{1, 0, 0, 1}
	body = append(body, make([]byte, 36)...)
	body = append(body, 0, 0, 0, 0, 0, 0, 0, 2, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0)
	return append([]byte{generated.OPGuiResidentSemantics, 0, 0, 0, byte(len(body))}, body...)
}
