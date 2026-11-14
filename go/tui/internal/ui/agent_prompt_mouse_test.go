package ui

import (
	"bytes"
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

// renderedComposerControl finds the visible label in the full terminal frame without consulting allocation or hit-test geometry.
func renderedComposerControl(t *testing.T, model Model, label string) (int, int) {
	t.Helper()
	canvas := lipgloss.NewCanvas(model.width, model.height)
	canvas.Compose(lipgloss.NewLayer(model.View().Content))
	foundX, foundY := -1, -1
	for y := range model.height {
		for x := range max(model.width-len(label)+1, 0) {
			matches := true
			for offset, letter := range label {
				cell := canvas.CellAt(x+offset, y)
				if cell == nil || cell.Content != string(letter) {
					matches = false
					break
				}
			}
			if matches {
				if foundX != -1 {
					t.Fatalf("ambiguous rendered %s labels", label)
				}
				foundX, foundY = x, y
			}
		}
	}
	if foundX == -1 {
		t.Fatalf("no rendered %s control", label)
	}
	return foundX, foundY
}

func TestComposerSGRClickTargetsRenderedControlAfterResize(t *testing.T) {
	for _, status := range []byte{0, 2} {
		for _, focused := range []bool{false, true} {
			t.Run(fmt.Sprintf("status%d/focused%t", status, focused), func(t *testing.T) {
				out := make(chan []byte, 64)
				model := New(80, 24, out, nil)
				chat := protocol.AgentChat{Visible: true, Status: status, Prompt: strings.Repeat("draft ", 100), PromptVisibleRows: 8, PromptVimMode: 0, InputFocused: focused}
				rows := promptRows("visible row one", "visible row two", "visible row three", "visible row four", "visible row five", "visible row six", "visible row seven", "visible row eight")
				model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 7, 5, 0, 0, protocol.Selection{}), 821)
				updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
					beginFrame(2, 1),
					{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiWorkspaces, Spaces: protocol.WorkspaceBar{Spaces: []protocol.Workspace{{ID: 1, Label: "Files", Active: true}, {ID: 2, Label: "Agent"}}}}},
					{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTabBar, Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Label: "Agent", Active: true}}}}},
					transcriptCommand(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: []protocol.AgentChatMessage{{ID: 1, Kind: agentKindSystem, Text: "session ready"}, {ID: 2, Kind: agentKindSystem, Text: "model ready"}, {ID: 3, Kind: agentKindSystem, Text: "workspace ready"}}}),
					focusOwnerCommand(0, 2),
					{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 821}},
					commitFrame(2),
				}})
				model = updated.(Model)
				if model.lastCommittedSeq != 2 {
					t.Fatal("two-header transcript frame rejected")
				}
				updated, _ = model.Update(tea.WindowSizeMsg{Width: 60, Height: 24})
				model = updated.(Model)
				model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 7, 5, 0, 0, protocol.Selection{}), 822)
				label, command := "Send", "agent_submit_or_newline"
				if status == 2 {
					label, command = "Stop", "agent_abort"
				}
				x, y := renderedComposerControl(t, model, label)
				if x != 2 || y != 21 {
					t.Fatalf("rendered control at %d,%d, want live capture position 2,21", x, y)
				}
				drainOutboundPackets(out)
				for _, fragmented := range []bool{false, true} {
					var decoder uv.EventDecoder
					for _, ending := range []byte{'M', 'm'} {
						wire := []byte(fmt.Sprintf("\x1b[<0;%d;%d%c", x+1, y+1, ending))
						var message tea.Msg
						if fragmented {
							message = tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: string(wire[2:])})
						} else {
							n, event := decoder.Decode(wire)
							if n != len(wire) {
								t.Fatalf("SGR consumed %d of %d bytes", n, len(wire))
							}
							switch event := event.(type) {
							case uv.MouseClickEvent:
								message = tea.MouseClickMsg(event)
							case uv.MouseReleaseEvent:
								message = tea.MouseReleaseMsg(event)
							default:
								t.Fatalf("SGR decoded as %T, not a mouse event", event)
							}
						}
						normalized := normalizeTerminalInput(message).(tea.MouseMsg).Mouse()
						if normalized.X != x || normalized.Y != y {
							t.Fatalf("SGR normalized to %d,%d, want %d,%d", normalized.X, normalized.Y, x, y)
						}
						updated, _ = model.Update(message)
						model = updated.(Model)
						packets := drainOutboundPackets(out)
						if ending == 'M' && (len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeGUIExecuteCommand(command))) {
							t.Fatalf("rendered %s press (fragmented=%t) bypassed authoritative action: %x", label, fragmented, packets)
						}
						if ending == 'm' {
							for _, packet := range packets {
								if bytes.Equal(packet, protocol.EncodeGUIExecuteCommand(command)) {
									t.Fatal("control action duplicated on release")
								}
							}
						}
					}
				}
			})
		}
	}
}

func TestWorkingAgentContextCannotCoverRenderedStop(t *testing.T) {
	for _, width := range []uint16{60, 80, 120} {
		for _, visibleRows := range []byte{1, 8} {
			t.Run(fmt.Sprintf("width%d/rows%d", width, visibleRows), func(t *testing.T) {
				out := make(chan []byte, 64)
				model := New(width, 24, out, nil)
				chat := protocol.AgentChat{Visible: true, Status: 1, Prompt: "draft", PromptVisibleRows: visibleRows, InputFocused: true}
				rows := promptRows("row one", "row two", "row three", "row four", "row five", "row six", "row seven", "row eight")
				model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows[:visibleRows], 0, 0, 0, 0, protocol.Selection{}), 823)
				context := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiAgentContext, AgentContext: protocol.AgentContext{Visible: true, Status: 1, Task: "Thinking", Progress: protocol.AgentProgress{ActiveAction: "Thinking"}}}}
				placement := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiSurfaceLayout, Placements: []generated.SurfacePlacement{{SurfaceID: surfaceIDAgentContext, Rect: generated.Rect{Row: 16, Col: 0, Width: width, Height: 8}, Z: 260, HitKind: 8}}}}
				updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
					beginFrame(2, 1), context, placement,
					{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 823}},
					commitFrame(2),
				}})
				model = updated.(Model)
				if model.lastCommittedSeq != 2 {
					t.Fatal("working context frame rejected")
				}
				x, y := renderedComposerControl(t, model, "Stop")
				if strings.Contains(model.View().Content, "Agent context") {
					t.Fatal("compact editor context still overlays full chat")
				}
				drainOutboundPackets(out)
				updated, _ = model.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: x, Y: y}))
				model = updated.(Model)
				packets := drainOutboundPackets(out)
				if len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeGUIExecuteCommand("agent_abort")) {
					t.Fatalf("visible Stop did not abort: %x", packets)
				}

				editor := New(width, 24, nil, nil)
				updated, _ = editor.Update(port.PacketMsg{Commands: frame(context, placement)})
				editor = updated.(Model)
				if editor.overlayLayer() == nil || !strings.Contains(editor.View().Content, "Agent context") {
					t.Fatal("compact context stopped rendering over ordinary editor")
				}
			})
		}
	}
}

func TestFragmentedPromptWheelPassesThroughInputFilterBeforeSourceDispatch(t *testing.T) {
	out := make(chan []byte, 64)
	filter := NewInputFilter()
	model := New(80, 24, out, filter)
	chat := protocol.AgentChat{Visible: true, Prompt: "draft", PromptVisibleRows: 8, InputFocused: true}
	rows := promptRows("row-one", "row-two", "row-three", "row-four", "row-five", "row-six", "row-seven", "row-eight")
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 7, 0, 0, 0, protocol.Selection{}), 824)
	x, y := renderedComposerControl(t, model, "row-one")
	drainOutboundPackets(out)
	tail := tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: fmt.Sprintf("<65;%d;%dM", x+1, y+1)})
	message := filter.Filter(model, tail)
	if _, ok := message.(tea.MouseWheelMsg); !ok {
		t.Fatalf("filter did not normalize SGR wheel before coalescing: %T", message)
	}
	updated, _ := model.Update(message)
	model = updated.(Model)
	packets := drainOutboundPackets(out)
	want := protocol.EncodeGUIAgentPromptScroll(protocol.AgentPromptScroll{WindowID: protocol.AgentPromptWindowID, Generation: 824, DeltaRows: 1})
	if len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("filtered SGR wheel lost source lease or coalesced delta: %x", packets)
	}
}

func TestInteriorFullWidthPromptCaretFollowsTheLastRenderedGrapheme(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(80, 24, out, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "initial\nnext", PromptVisibleRows: 2, InputFocused: true}
	rows := promptRows("initial", "next")
	rows[1].BufferLine = 1
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 0, 0, 0, 0, protocol.Selection{}), 825)
	columns := int(model.agent.lastPromptFit.Columns)
	if columns < 7 {
		t.Fatal("fixture did not receive enough physical columns")
	}
	line := "edge-" + strings.Repeat("x", columns-7) + "界"
	chat.Prompt = line + "\nnext"
	rows = promptRows(line, "next")
	rows[0].ContentHash++
	rows[1].BufferLine = 1
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 0, uint16(columns), 0, 0, protocol.Selection{}), 826)
	x, y := renderedComposerControl(t, model, "edge-")
	cursor := model.View().Cursor
	if cursor == nil || cursor.X != x+lipgloss.Width(line) || cursor.Y != y || cursor.Shape != tea.CursorBar {
		t.Fatalf("interior EOL caret must follow the final rendered wide grapheme: %+v", cursor)
	}
}
