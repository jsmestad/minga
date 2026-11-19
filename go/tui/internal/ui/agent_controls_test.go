package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func approvalControlTarget(suffix string) protocol.AgentApprovalTarget {
	return protocol.AgentApprovalTarget{SessionID: "session:" + suffix + " +/%", RequestID: "request:" + suffix, ToolCallID: "tool:" + suffix}
}

// Decode the changed kind0x09 body inside the real resident transcript frame.
func decodedApprovalControlTranscript(t *testing.T, target protocol.AgentApprovalTarget, status byte) protocol.Command {
	t.Helper()
	body := []byte{0x09, status}
	for _, value := range []string{"shell", "inspect command", target.ToolCallID, target.SessionID, target.RequestID} {
		body = binary.BigEndian.AppendUint16(body, uint16(len(value)))
		body = append(body, value...)
	}
	body = append(body, 2, 0, 1)
	preview := "echo safe"
	body = binary.BigEndian.AppendUint16(body, uint16(len(preview)))
	body = append(body, preview...)
	payload := []byte{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	payload = binary.BigEndian.AppendUint32(payload, 41)
	payload = binary.BigEndian.AppendUint32(payload, uint32(len(body)))
	payload = append(payload, body...)
	packet := binary.BigEndian.AppendUint32([]byte{generated.OPGuiAgentTranscript}, uint32(len(payload)))
	packet = append(packet, payload...)
	command, err := protocol.DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	if len(command.Chrome.AgentTranscript.Messages) != 1 || command.Chrome.AgentTranscript.Messages[0].ApprovalTarget != target {
		t.Fatalf("approval target lost at consumer boundary: %+v", command)
	}
	return command
}

func commitAgentControlTranscript(t *testing.T, model Model, command protocol.Command) Model {
	t.Helper()
	seq := model.lastCommittedSeq + 1
	updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
		beginFrame(seq, model.lastCommittedSeq),
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiWorkspaces, Spaces: protocol.WorkspaceBar{Spaces: []protocol.Workspace{{ID: 1, Label: "Files"}, {ID: 2, Label: "Agent", Active: true}}}}},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTabBar, Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Label: "Agent", Active: true}}}}},
		command,
		focusOwnerCommand(0, 2),
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 900}},
		commitFrame(seq),
	}})
	model = updated.(Model)
	if model.lastCommittedSeq != seq {
		t.Fatalf("agent controls frame %d rejected", seq)
	}
	return model
}

func newAgentControlModel(t *testing.T, focused bool) (Model, chan []byte) {
	t.Helper()
	out := make(chan []byte, 128)
	model := New(80, 24, out)
	chat := protocol.AgentChat{Visible: true, Status: 5, ModelName: "anthropic:claude-sonnet-4", ThinkingLevel: "medium", Prompt: "ordinary draft", PromptVisibleRows: 1, InputFocused: focused}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows(chat.Prompt), 0, 4, 0, 0, protocol.Selection{}), 900)
	model = commitAgentControlTranscript(t, model, decodedApprovalControlTranscript(t, approvalControlTarget("A"), 0))
	drainOutboundPackets(out)
	return model, out
}

func driveAgentControlSGR(t *testing.T, model Model, x, y int, ending byte, fragmented bool) Model {
	t.Helper()
	wire := []byte(fmt.Sprintf("\x1b[<0;%d;%d%c", x+1, y+1, ending))
	var message tea.Msg
	if fragmented {
		message = tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: string(wire[2:])})
	} else {
		var decoder uv.EventDecoder
		n, event := decoder.Decode(wire)
		if n != len(wire) {
			t.Fatalf("SGR consumed %d/%d bytes", n, len(wire))
		}
		switch event := event.(type) {
		case uv.MouseClickEvent:
			message = tea.MouseClickMsg(event)
		case uv.MouseReleaseEvent:
			message = tea.MouseReleaseMsg(event)
		default:
			t.Fatalf("SGR decoded as %T", event)
		}
	}
	mouse, ok := normalizeTerminalInput(message).(tea.MouseMsg)
	if !ok || mouse.Mouse().X != x || mouse.Mouse().Y != y {
		t.Fatalf("SGR normalization lost terminal coordinate %d,%d", x, y)
	}
	updated, _ := model.Update(message)
	return updated.(Model)
}

func agentControlCanvasText(model Model) string {
	canvas := lipgloss.NewCanvas(model.width, model.height)
	canvas.Compose(lipgloss.NewLayer(model.View().Content))
	var text strings.Builder
	for y := range model.height {
		for x := range model.width {
			if cell := canvas.CellAt(x, y); cell != nil && cell.Content != "" {
				text.WriteString(cell.Content)
			} else {
				text.WriteByte(' ')
			}
		}
		text.WriteByte('\n')
	}
	return text.String()
}

func TestRenderedAgentNamedControlsUseSemanticSGRAcrossResize(t *testing.T) {
	for _, focused := range []bool{false, true} {
		for _, fragmented := range []bool{false, true} {
			t.Run(fmt.Sprintf("focused%t/fragmented%t", focused, fragmented), func(t *testing.T) {
				model, out := newAgentControlModel(t, focused)
				for _, size := range [][2]int{{80, 24}, {60, 24}, {140, 40}, {80, 24}} {
					updated, _ := model.Update(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
					model = updated.(Model)
					for _, control := range []struct {
						label  string
						zone   string
						packet []byte
					}{
						{"model", zoneIDAgentModel, protocol.EncodeGUIExecuteCommand("agent_pick_model")},
						{"Help", zoneIDAgentHeaderHelp, protocol.EncodeGUIExecuteCommand("agent_toggle_help")},
						{"[y] Approve", "", protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), generated.AgentApprovalDecisionApprove)},
						{"[n] Reject", "", protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), generated.AgentApprovalDecisionReject)},
						{"[a] Approve session", "", protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), generated.AgentApprovalDecisionApproveSession)},
						{"[t] Approve turn", "", protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), generated.AgentApprovalDecisionApproveTurn)},
					} {
						var x, y int
						if control.zone != "" {
							_ = model.View()
							zone := waitForZone(t, model, control.zone)
							x, y = zone.EndX, zone.StartY
						} else {
							x, y = renderedComposerControl(t, model, control.label)
						}
						drainOutboundPackets(out)
						model = driveAgentControlSGR(t, model, x, y, 'M', fragmented)
						packets := drainOutboundPackets(out)
						if len(packets) != 1 || !bytes.Equal(packets[0], control.packet) {
							t.Fatalf("%dx%d rendered %s sent %x, want only %x", size[0], size[1], control.label, packets, control.packet)
						}
						chat, _ := model.agentChat()
						if chat.InputFocused != focused || chat.Prompt != "ordinary draft" {
							t.Fatalf("%s changed composer focus or draft: %+v", control.label, chat)
						}
						model = driveAgentControlSGR(t, model, x, y, 'm', fragmented)
						for _, packet := range drainOutboundPackets(out) {
							if bytes.Equal(packet, control.packet) || (len(packet) > 0 && packet[0] == generated.OPKeyPress) {
								t.Fatalf("%s release repeated operation or synthesized a key: %x", control.label, packet)
							}
						}
					}
				}
			})
		}
	}
}

func TestApprovalKeyboardShortcutsRemainAuthoritativeAndComposerText(t *testing.T) {
	for _, focused := range []bool{false, true} {
		model, out := newAgentControlModel(t, focused)
		for _, key := range "yant?" {
			drainOutboundPackets(out)
			updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: key, Text: string(key)}))
			model = updated.(Model)
			packets := drainOutboundPackets(out)
			if len(packets) != 1 || len(packets[0]) != 10 || packets[0][0] != generated.OPKeyPress || binary.BigEndian.Uint32(packets[0][1:5]) != uint32(key) || packets[0][5] != 0 {
				t.Fatalf("focused=%t ordinary %q did not stay backend key input: %x", focused, key, packets)
			}
			chat, _ := model.agentChat()
			if chat.InputFocused != focused || chat.Prompt != "ordinary draft" {
				t.Fatal("ordinary key changed frontend composer state")
			}
		}
	}
}

func TestDisplayedApprovalKeepsIdentityWhenResidentMessageIsReplaced(t *testing.T) {
	model, out := newAgentControlModel(t, true)
	x, y := renderedComposerControl(t, model, "[a] Approve session")
	// The terminal still displays A. Reuse the same resident ID for B before
	// another View, as a session/turn switch can do. Input must not look up B.
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 2, Messages: []protocol.AgentChatMessage{{ID: 41, Kind: agentKindApprovalTool, Name: "shell", ApprovalTarget: approvalControlTarget("B")}}})
	chat, _ := model.agentChat()
	chat.Pending = "a newer approval in session B"
	model.chrome[generated.OPGuiAgentChat] = protocol.ChromePayload{Opcode: generated.OPGuiAgentChat, AgentChat: chat}
	drainOutboundPackets(out)
	model = driveAgentControlSGR(t, model, x, y, 'M', false)
	packets := drainOutboundPackets(out)
	want := protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), generated.AgentApprovalDecisionApproveSession)
	if len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("old displayed approval was retargeted: %x, want %x", packets, want)
	}
	// After repaint, the new displayed control carries B, not the cache's A.
	x, y = renderedComposerControl(t, model, "[a] Approve session")
	model = driveAgentControlSGR(t, model, x, y, 'M', true)
	packets = drainOutboundPackets(out)
	want = protocol.EncodeGUIAgentToolApproval(approvalControlTarget("B"), generated.AgentApprovalDecisionApproveSession)
	if len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("repainted approval did not acquire B identity: %x", packets)
	}
}

func assertNoAgentNamedOperation(t *testing.T, packets [][]byte) {
	t.Helper()
	for _, packet := range packets {
		if len(packet) >= 2 && packet[0] == generated.OPGuiAction && (packet[1] == generated.GUIActionAgentToolApproval || packet[1] == generated.GUIActionExecuteCommand) {
			t.Fatalf("hidden/disabled control emitted a named operation: %x", packet)
		}
		if len(packet) > 0 && packet[0] == generated.OPKeyPress {
			t.Fatalf("mouse synthesized a key: %x", packet)
		}
	}
}

func TestApprovalScrollClippingRemovesOldHitTargets(t *testing.T) {
	model, out := newAgentControlModel(t, true)
	x, y := renderedComposerControl(t, model, "[y] Approve")
	messages := testTranscriptMessages(model.transcript)
	for index := range 40 {
		messages = append(messages, protocol.AgentChatMessage{ID: uint32(100 + index), Kind: agentKindSystem, Text: fmt.Sprintf("new transcript row %d", index)})
	}
	model = commitAgentControlTranscript(t, model, transcriptCommand(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: messages}))
	if strings.Contains(agentControlCanvasText(model), "[y] Approve") {
		t.Fatal("old approval remained on screen after scrolling to newer transcript rows")
	}
	drainOutboundPackets(out)
	model = driveAgentControlSGR(t, model, x, y, 'M', false)
	assertNoAgentNamedOperation(t, drainOutboundPackets(out))
	// Scroll back through the production wheel path and find the old message.
	updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseWheelUp}))
	model = updated.(Model)
	model.transcript.scrollBy(-10000)
	updated, _ = model.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	model = updated.(Model)
	x, y = renderedComposerControl(t, model, "[t] Approve turn")
	drainOutboundPackets(out)
	model = driveAgentControlSGR(t, model, x, y, 'M', true)
	want := protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), generated.AgentApprovalDecisionApproveTurn)
	assertPacketCount(t, drainOutboundPackets(out), want, 1)
	// Shrinking the aperture must not keep zones for clipped transcript rows.
	updated, _ = model.Update(tea.WindowSizeMsg{Width: 60, Height: 5})
	model = updated.(Model)
	if strings.Contains(agentControlCanvasText(model), "[t] Approve turn") {
		t.Fatal("tiny composer aperture still displays an approval")
	}
	drainOutboundPackets(out)
	model = driveAgentControlSGR(t, model, min(x, model.width-1), min(y, model.height-1), 'M', false)
	assertNoAgentNamedOperation(t, drainOutboundPackets(out))
}

func TestAgentControlsDoNotClickThroughNoninteractiveOverlay(t *testing.T) {
	for _, label := range []string{"anthropic / claude", "Help", "[n] Reject"} {
		t.Run(label, func(t *testing.T) {
			model, out := newAgentControlModel(t, true)
			x, y := renderedComposerControl(t, model, label)
			model.chrome[generated.OPGuiFloatPopup] = protocol.ChromePayload{Opcode: generated.OPGuiFloatPopup, Float: protocol.FloatPopup{Visible: true, Title: "Covered control", Lines: []string{"overlay owns input"}}}
			model.surfacePlacements = []generated.SurfacePlacement{{SurfaceID: surfaceIDFloatPopup, Rect: generated.Rect{Row: uint16(y), Col: 0, Width: uint16(model.width), Height: 1}, Z: 201, HitKind: 8}}
			if !strings.Contains(agentControlCanvasText(model), "Covered control") {
				t.Fatal("occluding overlay was not composed")
			}
			drainOutboundPackets(out)
			model = driveAgentControlSGR(t, model, x, y, 'M', false)
			assertNoAgentNamedOperation(t, drainOutboundPackets(out))
		})
	}
}

func TestAgentControlsDoNotClickThroughModalOverlays(t *testing.T) {
	for _, opcode := range []byte{generated.OPGuiPicker, generated.OPGuiWhichKey} {
		model, out := newAgentControlModel(t, true)
		x, y := renderedComposerControl(t, model, "[y] Approve")
		label := "SPC"
		if opcode == generated.OPGuiPicker {
			label = "Choose a model"
			model.chrome[opcode] = protocol.ChromePayload{Opcode: opcode, Picker: protocol.Picker{Visible: true, Title: label}}
		} else {
			model.chrome[opcode] = protocol.ChromePayload{Opcode: opcode, Which: protocol.WhichKey{
				Visible: true, Prefix: label,
				Bindings: []protocol.WhichKeyBinding{{Key: "a", Description: "Agent actions"}},
			}}
		}
		if !strings.Contains(agentControlCanvasText(model), label) {
			t.Fatalf("modal overlay was not rendered: %s", label)
		}
		drainOutboundPackets(out)
		model = driveAgentControlSGR(t, model, x, y, 'M', true)
		assertNoAgentNamedOperation(t, drainOutboundPackets(out))
	}
}

func TestApprovalDisabledAndWaitingPresentationsHaveNoActions(t *testing.T) {
	for _, test := range []struct {
		status byte
		target protocol.AgentApprovalTarget
		label  string
	}{
		{1, approvalControlTarget("A"), "Waiting for approval update"},
		{0, protocol.AgentApprovalTarget{ToolCallID: "orphan"}, "Approval unavailable"},
	} {
		model, out := newAgentControlModel(t, true)
		x, y := renderedComposerControl(t, model, "[y] Approve")
		model = commitAgentControlTranscript(t, model, decodedApprovalControlTranscript(t, test.target, test.status))
		text := agentControlCanvasText(model)
		if !strings.Contains(text, test.label) || strings.Contains(text, "[y] Approve") {
			t.Fatalf("disabled approval presentation = %q", text)
		}
		drainOutboundPackets(out)
		model = driveAgentControlSGR(t, model, x, y, 'M', false)
		assertNoAgentNamedOperation(t, drainOutboundPackets(out))
	}
}

func TestApprovalZoneRejectsUnknownDecisionAndMalformedIdentity(t *testing.T) {
	target := approvalControlTarget("A")
	for _, decision := range []generated.AgentApprovalDecision{generated.AgentApprovalDecisionUnknown, 5, 255} {
		if packet := agentApprovalZonePacket(zoneIDAgentApproval(target, decision)); packet != nil {
			t.Fatalf("unknown zone decision %d became an operation: %x", decision, packet)
		}
	}
	for _, id := range []string{"agent:approval:1:s:r", "agent:approval:1:%ZZ:r:t", "agent:approval:256:s:r:t", "agent:approval:1::r:t"} {
		if packet := agentApprovalZonePacket(id); packet != nil {
			t.Fatalf("malformed displayed target emitted %x", packet)
		}
	}
}

func TestNarrowApprovalOnlyOffersFullyVisibleDecisions(t *testing.T) {
	model, out := newAgentControlModel(t, true)
	updated, _ := model.Update(tea.WindowSizeMsg{Width: 10, Height: 24})
	model = updated.(Model)
	text := agentControlCanvasText(model)
	if strings.Contains(text, "[n]") || strings.Contains(text, "[t]") {
		t.Fatalf("narrow fixture unexpectedly shows the second action column: %q", text)
	}
	for _, control := range []struct {
		label    string
		decision generated.AgentApprovalDecision
	}{{"[y]", generated.AgentApprovalDecisionApprove}, {"[a]", generated.AgentApprovalDecisionApproveSession}} {
		x, y := renderedComposerControl(t, model, control.label)
		drainOutboundPackets(out)
		model = driveAgentControlSGR(t, model, x, y, 'M', true)
		want := protocol.EncodeGUIAgentToolApproval(approvalControlTarget("A"), control.decision)
		assertPacketCount(t, drainOutboundPackets(out), want, 1)
		// The adjacent clipped column/border must not retain an invisible action.
		model = driveAgentControlSGR(t, model, min(x+5, model.width-1), y, 'M', false)
		assertNoAgentNamedOperation(t, drainOutboundPackets(out))
	}
}

func TestAgentHeaderStatusAndThinkingAreNotNamedButtons(t *testing.T) {
	model, out := newAgentControlModel(t, true)
	_ = model.View()
	identity := waitForZone(t, model, zoneIDAgentModel)
	help := waitForZone(t, model, zoneIDAgentHeaderHelp)
	if identity.EndX+1 >= help.StartX {
		t.Fatal("fixture must present the static status and thinking area between model and Help")
	}
	for x := identity.EndX + 1; x < help.StartX; x++ {
		drainOutboundPackets(out)
		model = driveAgentControlSGR(t, model, x, identity.StartY, 'M', false)
		assertNoAgentNamedOperation(t, drainOutboundPackets(out))
	}
}

func TestApprovalReplacementRetainsTargetOccurrencesAndResourceTotals(t *testing.T) {
	t.Parallel()
	first := protocol.AgentChatMessage{Kind: agentKindApprovalTool, ApprovalTarget: approvalControlTarget("A")}
	second := first
	second.ApprovalTarget = approvalControlTarget("longer-B")
	transcript := newResidentTranscript()
	if reason := transcript.apply(replaceFrame(1, first, second)); reason != transcriptApplied {
		t.Fatal(reason)
	}
	firstSlot, secondSlot := transcript.entry(0).slot, transcript.entry(1).slot
	if reason := transcript.apply(replaceFrame(1, second, first)); reason != transcriptApplied {
		t.Fatal(reason)
	}
	if transcript.entry(0).slot != secondSlot || transcript.entry(1).slot != firstSlot {
		t.Fatal("replacement matched different approval targets as the same occurrence")
	}
	var expected uint64
	for _, message := range []protocol.AgentChatMessage{first, second} {
		target := message.ApprovalTarget
		expected += uint64(len(target.SessionID) + len(target.RequestID) + len(target.ToolCallID))
	}
	if transcript.payloadBytes != expected {
		t.Fatalf("approval identity bytes=%d, want %d", transcript.payloadBytes, expected)
	}
}
