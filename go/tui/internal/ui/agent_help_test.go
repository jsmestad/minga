package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func agentHelpCommand(t *testing.T, visible bool, count int) protocol.Command {
	t.Helper()
	body := []byte{1, 0}
	if visible {
		body[1] = 1
		body = append(body, 1)
		title := "Review shortcuts"
		body = binary.BigEndian.AppendUint16(body, uint16(len(title)))
		body = append(body, []byte(title)...)
		body = append(body, byte(count))
		for index := range count {
			body = append(body, 1, 'j')
			text := fmt.Sprintf("Binding %02d", index)
			body = binary.BigEndian.AppendUint16(body, uint16(len(text)))
			body = append(body, []byte(text)...)
		}
	}
	packet := binary.BigEndian.AppendUint32([]byte{generated.OPGuiAgentHelp}, uint32(len(body)))
	command, err := protocol.DecodeCommand(append(packet, body...))
	if err != nil {
		t.Fatal(err)
	}
	return command
}

func helpPlacement(width, height uint16) protocol.Command {
	return protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiSurfaceLayout,
		Placements: []generated.SurfacePlacement{{
			SurfaceID: surfaceIDAgentHelp, Rect: generated.Rect{Row: 3, Col: 4, Width: width, Height: height}, Z: 300, HitKind: 8,
		}},
	}}
}

func helpModel(t *testing.T, width, height uint16) Model {
	t.Helper()
	model := New(80, 24, nil)
	applyProductionFrame(&model, 1, 0, 1, testThemeCommand(), focusOwnerCommand(0, 0),
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
			Opcode:    generated.OPGuiAgentChat,
			AgentChat: protocol.AgentChat{Visible: false, Prompt: "unfinished é draft", PromptCursorCol: 5, PromptVimMode: 1},
		}}, agentHelpCommand(t, true, 30), helpPlacement(width, height))
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return model
}

func TestAgentHelpRendersWhileChatHiddenOnlyWithinCommittedContainment(t *testing.T) {
	model := helpModel(t, 30, 7)
	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "Review shortcuts") || !strings.Contains(view, "Binding 00") || model.agentChatVisible() {
		t.Fatalf("independent Help requires Chat visibility: %q", view)
	}
	layer := model.overlayLayer()
	if layer == nil || layer.GetX() != 4 || layer.GetY() != 4 || layer.Width() != 30 || layer.Height() != 7 {
		t.Fatalf("Help escaped the authored content rect: %+v", layer)
	}
	if layers := model.floatingOverlayLayers(); len(layers) != 1 {
		t.Fatal("Help paints an unauthored shadow outside its containment")
	}
	// A replacement layout removes placement without changing Help visibility.
	applyProductionFrame(&model, 2, 1, 1, protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiSurfaceLayout}})
	if model.overlayLayer() != nil || strings.Contains(ansi.Strip(model.View().Content), "Review shortcuts") {
		t.Fatal("visible but unplaced Help guessed an overlay rectangle")
	}
}

func TestAgentHelpCommitIsAtomicAndHiddenPayloadResetsScroll(t *testing.T) {
	model := helpModel(t, 30, 7)
	model.scrollAgentHelp(12)
	model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandBeginFrame, FrameSeq: 2, BaseFrameSeq: 1, Generation: 1},
		agentHelpCommand(t, false, 0),
	})
	if help, _ := model.agentHelp(); !help.Visible || model.agentHelpScroll != 12 {
		t.Fatal("uncommitted Help hide changed the visible model or scroll")
	}
	model.applyCommands([]protocol.Command{{Kind: protocol.CommandCommitFrame, FrameSeq: 2}})
	if help, _ := model.agentHelp(); help.Visible || len(help.Groups) != 0 || model.agentHelpScroll != 0 || model.overlayLayer() != nil {
		t.Fatalf("hidden Help did not reset committed content/presentation: %+v scroll=%d", help, model.agentHelpScroll)
	}
	applyProductionFrame(&model, 3, 2, 1, agentHelpCommand(t, true, 30))
	if model.agentHelpScroll != 0 || !strings.Contains(ansi.Strip(model.View().Content), "Binding 00") {
		t.Fatal("reopened Help retained its old scroll")
	}
}

func TestAgentHelpWheelAndKeyboardScrollAreBoundedAndPreserveInputOwnership(t *testing.T) {
	model := helpModel(t, 30, 7)
	out := make(chan []byte, 64)
	model.out = out
	chat := model.chrome[generated.OPGuiAgentChat].AgentChat
	owner := model.chrome[generated.OPGuiFocusOwner].FocusOwner
	for range 20 {
		updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: 8, Y: 5}))
		model = updated.(Model)
	}
	if model.agentHelpScroll != 25 {
		t.Fatalf("Help wheel offset = %d, want bounded maximum 25", model.agentHelpScroll)
	}
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("presentation wheel leaked to underlying editor: %x", packets)
	}
	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "Binding 29") || strings.Contains(view, "Binding 00") {
		t.Fatalf("wheel did not reveal the end of Help: %q", view)
	}
	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyHome}))
	model = updated.(Model)
	if model.agentHelpScroll != 0 {
		t.Fatal("Home failed to return Help to its beginning")
	}
	updated, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyPgDown}))
	model = updated.(Model)
	if model.agentHelpScroll != 6 {
		t.Fatalf("PageDown scrolled Help by %d rows, want 6", model.agentHelpScroll)
	}
	updated, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnd}))
	model = updated.(Model)
	if model.agentHelpScroll != 25 {
		t.Fatal("End did not bound Help at the last page")
	}
	packets := drainOutboundPackets(out)
	if len(packets) != 3 {
		t.Fatalf("Help presentation must still forward all original keys: %x", packets)
	}
	for index, want := range []uint32{57360, 57363, 57361} {
		if len(packets[index]) != 10 || packets[index][0] != generated.OPKeyPress ||
			binary.BigEndian.Uint32(packets[index][1:5]) != want {
			t.Fatalf("Help changed canonical navigation delivery: %x", packets[index])
		}
	}
	if !reflect.DeepEqual(chat, model.chrome[generated.OPGuiAgentChat].AgentChat) || owner != model.chrome[generated.OPGuiFocusOwner].FocusOwner {
		t.Fatal("Help scrolling altered prompt data or committed root ownership")
	}
	// Replacing content and geometry clamps the retained presentation at commit.
	applyProductionFrame(&model, 2, 1, 1, agentHelpCommand(t, true, 2), helpPlacement(30, 7))
	if model.agentHelpScroll != 0 {
		t.Fatal("shorter committed Help did not clamp the local offset")
	}
}

func TestAgentHelpCloseStaysReachableAtNarrowWidthsAndAfterScrolling(t *testing.T) {
	for _, width := range []uint16{1, 4, 5, 10, 11, 16, 30} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			model := helpModel(t, width, 4)
			_ = model.View()
			first := *waitForZone(t, model, zoneIDAgentHelpClose)
			model.scrollAgentHelp(1000)
			_ = model.View()
			close := waitForZone(t, model, zoneIDAgentHelpClose)
			if *close != first || close.StartY != 4 || close.EndY != 4 || close.StartX < 4 || close.EndX >= 4+int(width) {
				t.Fatalf("Close moved/clipped at width %d: %+v -> %+v", width, first, close)
			}
			click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: close.StartX, Y: close.StartY})
			packet, handled := model.semanticMousePacket(click)
			if !handled || !bytes.Equal(packet, protocol.EncodeGUIExecuteCommand("agent_dismiss_help")) {
				t.Fatalf("Close must be directional named dismissal: %x handled=%v", packet, handled)
			}
			// Every non-control cell in containment is modal, not an underlying
			// timeline Review, composer, or editor text action.
			click.X, click.Y = 4, close.EndY+1
			if packet, handled := model.semanticMousePacket(click); !handled || packet != nil {
				t.Fatalf("Help body activated underlying content: %x handled=%v", packet, handled)
			}
		})
	}
}

func TestAgentHelpRespectsHigherModalPrecedenceAndCommittedOwner(t *testing.T) {
	model := helpModel(t, 30, 7)
	// Completion participates in the same authored placement ordering.
	completion := completionChrome(3, 0)
	placement := helpPlacement(30, 7)
	placement.Chrome.Placements = append(placement.Chrome.Placements, generated.SurfacePlacement{
		SurfaceID: surfaceIDCompletionMenu, Rect: generated.Rect{Row: 3, Col: 4, Width: 30, Height: 4}, Z: 400,
	})
	applyProductionFrame(&model, 2, 1, 1, protocol.Command{Kind: protocol.CommandChrome, Chrome: completion}, placement, focusOwnerCommand(0, 9))
	if winner, ok := model.overlayWinner(); !ok || winner.surfaceID != surfaceIDCompletionMenu {
		t.Fatal("Help displaced a higher-priority completion")
	}
	if model.presentAgentHelpKey(tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}), "completion") || model.agentHelpScroll != 0 {
		t.Fatal("Help captured completion's local presentation")
	}
	// Global picker stays above Help using its existing modal compositor.
	applyProductionFrame(&model, 3, 2, 1, protocol.Command{Kind: protocol.CommandChrome, Chrome: pickerChrome(3, 0)},
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiCompletion}}, focusOwnerCommand(1, 8))
	if _, ok := model.activeAgentHelpRect(); ok || model.floatingPickerLayer() == nil {
		t.Fatal("Help remained interactive above the picker")
	}
	// Missing ownership never authorizes a local keyboard interceptor.
	model = helpModel(t, 30, 7)
	delete(model.chrome, generated.OPGuiFocusOwner)
	if model.presentAgentHelpKey(tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}), "") || model.agentHelpScroll != 0 {
		t.Fatal("Help inferred keyboard ownership from visibility")
	}
}

func TestAgentHeaderHelpUsesNamedCommandWithoutChangingDraft(t *testing.T) {
	model := New(80, 24, nil)
	chat := protocol.AgentChat{Visible: true, ModelName: "provider/model", Prompt: "unchanged draft", PromptCursorCol: 4, PromptVimMode: 1}
	model.chrome[generated.OPGuiAgentChat] = protocol.ChromePayload{AgentChat: chat}
	model.viewport.SetContent(model.content())
	_ = model.View()
	zone := waitForZone(t, model, zoneIDAgentHeaderHelp)
	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
	packet, ok := model.semanticMousePacket(click)
	if !ok || !bytes.Equal(packet, protocol.EncodeGUIExecuteCommand("agent_toggle_help")) {
		t.Fatalf("header Help routed through mode-dependent typing: %x", packet)
	}
	if !reflect.DeepEqual(chat, model.chrome[generated.OPGuiAgentChat].AgentChat) {
		t.Fatal("header Help changed the draft")
	}
}
