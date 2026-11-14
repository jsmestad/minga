package ui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestComposerHiddenSidebarMetadataMatchesRenderedInputCoordinates(t *testing.T) {
	for _, width := range []uint16{60, 80, 120} {
		for _, status := range []byte{0, 2} {
			for _, fragmented := range []bool{false, true} {
				t.Run(fmt.Sprintf("width%d/status%d/fragmented%t", width, status, fragmented), func(t *testing.T) {
					out := make(chan []byte, 64)
					model := New(80, 24, out, nil)
					draft := strings.Repeat("d", 555) + "\n" + strings.Repeat("t", 556)
					chat := protocol.AgentChat{Visible: true, Status: status, Prompt: draft, PromptVisibleRows: 8, PromptVimMode: 0, InputFocused: false}
					rows := promptRows("row-one", "row-two", "row-three", "row-four", "row-five", "row-six", "row-seven", "row-eight")
					for i := 4; i < len(rows); i++ {
						rows[i].BufferLine = 1
					}
					model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 7, 5, 0, 0, protocol.Selection{}), 825)
					updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
						beginFrame(2, 1),
						{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiSidebars, Sidebars: protocol.Sidebars{Items: []protocol.Sidebar{{ID: "files", PreferredWidth: 24}, {ID: "agent", PreferredWidth: 24}}}}},
						{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiWorkspaces, Spaces: protocol.WorkspaceBar{Spaces: []protocol.Workspace{{ID: 1, Label: "Files", Active: true}, {ID: 2, Label: "Agent"}}}}},
						{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTabBar, Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Label: "Agent", Active: true}}}}},
						transcriptCommand(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: []protocol.AgentChatMessage{{ID: 1, Kind: agentKindSystem, Text: "session ready"}, {ID: 2, Kind: agentKindSystem, Text: "model ready"}, {ID: 3, Kind: agentKindSystem, Text: "workspace ready"}}}),
						focusOwnerCommand(0, 2),
						{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 825}},
						commitFrame(2),
					}})
					model = updated.(Model)
					if model.lastCommittedSeq != 2 {
						t.Fatal("hidden-sidebar header frame rejected")
					}
					updated, _ = model.Update(tea.WindowSizeMsg{Width: int(width), Height: 24})
					model = updated.(Model)
					label, command := "Send", "agent_submit_or_newline"
					if status == 2 {
						label, command = "Stop", "agent_abort"
					}
					x, y := renderedComposerControl(t, model, label)
					wire := []byte(fmt.Sprintf("\x1b[<0;%d;%dM", x+1, y+1))
					var message tea.Msg
					if fragmented {
						message = tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: string(wire[2:])})
					} else {
						var decoder uv.EventDecoder
						n, event := decoder.Decode(wire)
						click, ok := event.(uv.MouseClickEvent)
						if n != len(wire) || !ok {
							t.Fatalf("SGR press decoded as %T after %d bytes", event, n)
						}
						message = tea.MouseClickMsg(click)
					}
					preClickPackets := drainOutboundPackets(out)
					updated, _ = model.Update(message)
					model = updated.(Model)
					packets := drainOutboundPackets(out)
					if len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeGUIExecuteCommand(command)) {
						t.Fatalf("rendered %s press fell through to editor-relative mouse routing: %x", label, packets)
					}
					if model.layout.header.Height != 2 || model.layout.body.Y != 2 || model.layout.body.X != 0 || model.layout.body.Width != int(width) {
						t.Fatalf("hidden sidebar metadata allocated phantom chrome: header=%+v body=%+v", model.layout.header, model.layout.body)
					}
					if width == 60 {
						wantFit := protocol.EncodeGUIAgentPromptFit(protocol.AgentPromptFit{WindowID: protocol.AgentPromptWindowID, Generation: 825, Columns: 44, MaxRows: 17})
						foundFit := false
						for _, packet := range preClickPackets {
							foundFit = foundFit || bytes.Equal(packet, wantFit)
						}
						if !foundFit {
							t.Fatalf("fit did not report the full physical allocation without phantom sidebar chrome: %x", preClickPackets)
						}
					}

					lastX, lastY := renderedComposerControl(t, model, "row-eight")
					cursor := model.View().Cursor
					if cursor == nil || cursor.X != lastX+5 || cursor.Y != lastY {
						t.Fatalf("prompt cursor does not match rendered source cells: %+v, want %d,%d", cursor, lastX+5, lastY)
					}
					textX, textY := renderedComposerControl(t, model, "row-one")
					updated, _ = model.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: textX, Y: textY}))
					model = updated.(Model)
					packets = drainOutboundPackets(out)
					wantText := protocol.EncodeEditorTextEvent(protocol.AgentPromptWindowID, 825, 0, rows[0].ID, 0, 0, 0, protocol.MousePress, 1, 0, 0)
					if len(packets) != 1 || !bytes.Equal(packets[0], wantText) {
						t.Fatalf("rendered prompt text lost its source target: %x", packets)
					}
					updated, _ = model.Update(tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseLeft, X: textX, Y: textY}))
					model = updated.(Model)
					drainOutboundPackets(out)
					updated, _ = model.Update(tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, X: textX, Y: textY}))
					model = updated.(Model)
					packets = drainOutboundPackets(out)
					wantScroll := protocol.EncodeGUIAgentPromptScroll(protocol.AgentPromptScroll{WindowID: protocol.AgentPromptWindowID, Generation: 825, DeltaRows: 1})
					if len(packets) != 1 || !bytes.Equal(packets[0], wantScroll) {
						t.Fatalf("rendered prompt wheel lost its source lease: %x", packets)
					}
				})
			}
		}
	}
}
