package protocol

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// Every GUI sender must use a reviewed surviving sub-opcode. In particular,
// adding an index-addressed sender back into events.go fails this inventory.
func TestGUISendersUseOnlyRemainingActions(t *testing.T) {
	remaining := map[string]bool{
		"GUIActionSelectTab":                  false,
		"GUIActionTabReorder":                 false,
		"GUIActionFileTreeDrop":               false,
		"GUIActionExecuteCommand":             false,
		"GUIActionAgentToolToggle":            false,
		"GUIActionSemanticItemActivate":       false,
		"GUIActionHoverOpenAction":            false,
		"GUIActionSidebarAction":              false,
		"GUIActionNotificationDismiss":        false,
		"GUIActionNotificationAction":         false,
		"GUIActionObservatoryInspect":         false,
		"GUIActionFloatPopupDismiss":          false,
		"GUIActionEmptyStateActivate":         false,
		"GUIActionChatScrolledAwayFromBottom": false,
		"GUIActionChatReturnedToBottom":       false,
		"GUIActionFoldToggleAtLine":           false,
	}
	file, err := parser.ParseFile(token.NewFileSet(), "events.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	ast.Inspect(file, func(node ast.Node) bool {
		selector, ok := node.(*ast.SelectorExpr)
		if !ok || !strings.HasPrefix(selector.Sel.Name, "GUIAction") {
			return true
		}
		if _, ok := remaining[selector.Sel.Name]; !ok {
			t.Errorf("retired or unreviewed GUI sender: %s", selector.Sel.Name)
			return true
		}
		remaining[selector.Sel.Name] = true
		return true
	})
	for name, seen := range remaining {
		if !seen {
			t.Errorf("remaining GUI action inventory is stale: %s has no sender", name)
		}
	}
}

func TestDecodeMinibufferIdentityTrailerStopsAtNextCommand(t *testing.T) {
	packet := []byte{generated.OPGuiMinibuffer, 1, 0, 0, 3}
	packet = append(packet, string8("M-x ")...)
	packet = append(packet, string16("org")...)
	packet = append(packet, string16("")...)
	packet = appendWireU16(packet, 1)
	packet = appendWireU16(packet, 2)
	packet = appendWireU16(packet, 20)
	for _, label := range []string{"org-mode", "org-agenda"} {
		packet = append(packet, 99)
		packet = append(packet, string16(label)...)
		packet = append(packet, string16("description")...)
		packet = append(packet, string16("key")...)
		packet = append(packet, 2, 0, 0, 0, 2)
	}
	packet = appendWireU32(packet, 0x01020304)
	packet = append(packet, string16("id-mode")...)
	packet = append(packet, string16("id-agenda")...)
	boundary := len(packet)
	packet = append(packet, generated.OPGuiMinibuffer, 0)
	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	mini := command.Chrome.Mini
	if command.Size != boundary || mini.Generation != 0x01020304 || len(mini.Items) != 2 {
		t.Fatalf("minibuffer boundary or identity: %+v size=%d want=%d", mini, command.Size, boundary)
	}
	if mini.Items[0].ID != "id-mode" || mini.Items[1].ID != "id-agenda" || mini.Items[1].MatchPositions[1] != 2 {
		t.Fatalf("candidate identities or positions: %+v", mini.Items)
	}
	for end := boundary - 1; end >= boundary-4; end-- {
		command, err := DecodeCommand(packet[:end])
		if err == nil && command.Chrome.Mini.Visible {
			t.Fatalf("truncated identity trailer at %d published visible candidates", end)
		}
	}
}

func TestEncodeFoldIncludesObservedWindowGeneration(t *testing.T) {
	got := EncodeGUIFoldToggleAtLine(7, 0x0102030405060708, 42)
	want := []byte{generated.OPGuiAction, generated.GUIActionFoldToggleAtLine,
		0, 7, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 42}
	if !bytes.Equal(got, want) {
		t.Fatalf("fold target packet = %v, want %v", got, want)
	}
}

func TestDecodeWindowAccessibilityGeneration(t *testing.T) {
	header := []byte{0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	identity := []byte{1, 2, 3, 4, 5, 6, 7, 8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0}
	packet := windowContentPacket(
		section32(0x01, header),
		section32(0x02, []byte{0, 0, 0, 0}),
		section32(0x0C, identity),
	)
	command, err := DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	if !command.Window.AccessibilitySet || command.Window.AccessibilityGeneration != 0x0102030405060708 {
		t.Fatalf("window identity = %+v", command.Window)
	}
}

func TestTimelineTrailerRejectsTruncatedIdentity(t *testing.T) {
	body := []byte{1, 0xFF, 0xFF, 1, 0}
	body = append(body, string8("apply_patch")...)
	body = appendWireU32(body, 4)
	body = append(body, 0) // file count
	body = appendWireU32(body, 7)
	body = append(body, string16("path:call")...)
	for trim := range 4 {
		truncated := body[:len(body)-trim-1]
		packet := []byte{generated.OPGuiEditTimeline, byte(len(truncated) >> 8), byte(len(truncated))}
		packet = append(packet, truncated...)
		command, err := DecodeCommand(packet)
		if err == nil && command.Chrome.Timeline.Visible {
			t.Fatalf("truncated timeline identity published navigation target: %+v", command.Chrome.Timeline)
		}
	}
}
