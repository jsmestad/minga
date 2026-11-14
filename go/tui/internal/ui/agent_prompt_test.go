package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// These fixtures cross the production wire decoder and atomic frame commit.
// Rows are already broken by the core: the TUI must never reflow them.
func decodedPromptCommand(t *testing.T, rows []protocol.WindowRow, cursorRow, cursorCol uint16, anchorLine uint32, continuation uint16, selection protocol.Selection) protocol.Command {
	t.Helper()
	header := binary.BigEndian.AppendUint16(nil, protocol.AgentPromptWindowID)
	header = append(header, 2)
	header = binary.BigEndian.AppendUint16(header, cursorRow)
	header = binary.BigEndian.AppendUint16(header, cursorCol)
	header = append(header, 1, 0, 0)
	header = binary.BigEndian.AppendUint32(header, 17)
	encodedRows := binary.BigEndian.AppendUint32(nil, uint32(len(rows)))
	for _, row := range rows {
		encodedRows = append(encodedRows, row.Kind)
		encodedRows = binary.BigEndian.AppendUint64(encodedRows, row.ID)
		encodedRows = binary.BigEndian.AppendUint32(encodedRows, row.BufferLine)
		encodedRows = binary.BigEndian.AppendUint32(encodedRows, row.ContentHash)
		encodedRows = binary.BigEndian.AppendUint32(encodedRows, uint32(len(row.Text)))
		encodedRows = append(encodedRows, row.Text...)
		encodedRows = binary.BigEndian.AppendUint16(encodedRows, uint16(len(row.Spans)))
		for _, span := range row.Spans {
			encodedRows = binary.BigEndian.AppendUint16(encodedRows, span.StartCol)
			encodedRows = binary.BigEndian.AppendUint16(encodedRows, span.EndCol)
			encodedRows = append(encodedRows, byte(span.FG>>16), byte(span.FG>>8), byte(span.FG), byte(span.BG>>16), byte(span.BG>>8), byte(span.BG), span.Attrs, span.FontWeight, span.FontID)
		}
	}
	scroll := binary.BigEndian.AppendUint16(nil, protocol.AgentPromptWindowID)
	scroll = append(scroll, 0)
	scroll = binary.BigEndian.AppendUint32(scroll, anchorLine)
	scroll = binary.BigEndian.AppendUint16(scroll, 0)
	scroll = binary.BigEndian.AppendUint16(scroll, continuation)
	scroll = binary.BigEndian.AppendUint32(scroll, anchorLine)
	scroll = binary.BigEndian.AppendUint32(scroll, anchorLine+1)
	firstLine, lastLine := uint32(0), uint32(0)
	if len(rows) != 0 {
		firstLine, lastLine = rows[0].BufferLine, rows[len(rows)-1].BufferLine
	}
	scroll = binary.BigEndian.AppendUint32(scroll, firstLine)
	scroll = binary.BigEndian.AppendUint32(scroll, lastLine+1)
	scroll = binary.BigEndian.AppendUint32(scroll, 17)
	scroll = binary.BigEndian.AppendUint32(scroll, 3)
	scroll = binary.BigEndian.AppendUint32(scroll, 4)
	selected := []byte{selection.Type}
	selected = binary.BigEndian.AppendUint16(selected, selection.StartRow)
	selected = binary.BigEndian.AppendUint16(selected, selection.StartCol)
	selected = binary.BigEndian.AppendUint16(selected, selection.EndRow)
	selected = binary.BigEndian.AppendUint16(selected, selection.EndCol)
	geometry := binary.BigEndian.AppendUint16(nil, protocol.AgentPromptWindowID)
	// Canonical source geometry is intentionally not the TUI's chat placement.
	// The composer must transform all rows/cursor/input through its own aperture.
	for range 5 {
		geometry = binary.BigEndian.AppendUint16(geometry, 97)
		geometry = binary.BigEndian.AppendUint16(geometry, 83)
		geometry = binary.BigEndian.AppendUint16(geometry, 100)
		geometry = binary.BigEndian.AppendUint16(geometry, uint16(min(len(rows), 8)))
	}
	geometry = binary.BigEndian.AppendUint32(geometry, anchorLine)
	geometry = binary.BigEndian.AppendUint16(geometry, 0)
	geometry = binary.BigEndian.AppendUint16(geometry, uint16(min(len(rows), 8)))
	geometry = binary.BigEndian.AppendUint16(geometry, 100)
	geometry = binary.BigEndian.AppendUint32(geometry, lastLine+1)
	geometry = binary.BigEndian.AppendUint16(geometry, continuation)
	geometry = binary.BigEndian.AppendUint32(geometry, uint32(len(rows)))
	geometry = append(geometry, 0, 0, 0, 0, 0)
	body := []byte{5}
	for _, section := range []struct {
		id      byte
		payload []byte
	}{{1, header}, {2, encodedRows}, {3, selected}, {8, geometry}, {10, scroll}} {
		body = append(body, section.id)
		body = binary.BigEndian.AppendUint32(body, uint32(len(section.payload)))
		body = append(body, section.payload...)
	}
	packet := []byte{generated.OPGuiWindowContent}
	packet = binary.BigEndian.AppendUint32(packet, uint32(len(body)))
	packet = append(packet, body...)
	command, err := protocol.DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	return command
}

func commitPrompt(t *testing.T, model Model, chat protocol.AgentChat, command protocol.Command, presentation uint64) Model {
	t.Helper()
	seq := model.lastCommittedSeq + 1
	decode := func(packet []byte) protocol.Command {
		command, err := protocol.DecodeCommand(packet)
		if err != nil {
			t.Fatal(err)
		}
		return command
	}
	begin := binary.BigEndian.AppendUint32([]byte{generated.OPBeginFrame}, seq)
	begin = binary.BigEndian.AppendUint32(begin, model.lastCommittedSeq)
	begin = binary.BigEndian.AppendUint32(begin, 1)
	identity := binary.BigEndian.AppendUint16([]byte{generated.OPGuiTextPresentation}, protocol.AgentPromptWindowID)
	identity = binary.BigEndian.AppendUint64(identity, presentation)
	commit := binary.BigEndian.AppendUint32([]byte{generated.OPCommitFrame}, seq)
	commit = binary.BigEndian.AppendUint32(commit, 0)
	commands := []protocol.Command{decode(begin)}
	if model.lastCommittedSeq == 0 {
		commands = append(commands, testThemeCommand())
	}
	commands = append(commands, command,
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiAgentChat, AgentChat: chat}},
		decode(identity), decode(commit),
	)
	updated, _ := model.Update(port.PacketMsg{Commands: commands})
	model = updated.(Model)
	if model.lastCommittedSeq != seq {
		t.Fatalf("prompt frame %d rejected: %s", seq, renderedBody(model))
	}
	if model.windows[protocol.AgentPromptWindowID].SequentialRows {
		t.Fatal("wrapped prompt falsely marked sequential")
	}
	return model
}

func promptRows(texts ...string) []protocol.WindowRow {
	rows := make([]protocol.WindowRow, len(texts))
	for i, text := range texts {
		rows[i] = protocol.WindowRow{ID: uint64(100 + i), ContentHash: uint32(i + 1), BufferLine: 0, Text: text}
	}
	return rows
}

func TestCommittedPromptRowsReachProductionComposerWithoutReflow(t *testing.T) {
	for _, test := range []struct {
		name string
		rows []string
	}{
		{"ordinary wraps", []string{"one two ", "three four"}},
		{"long word", []string{"abcdefghij", "klmnopqrst", "uvwxyz"}},
		{"explicit blank and trailing newline", []string{"first", "", "last", ""}},
		{"unicode display and bytes", []string{"a界e\u0301", "😀z"}},
		{"exact width insertion row", []string{strings.Repeat("x", 64), ""}},
		{"expanded paste pill", []string{"[Pasted 14 lines]", "expanded first", "expanded last"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			model := New(90, 24, nil, nil)
			chat := protocol.AgentChat{Visible: true, Prompt: "RAW_METADATA_MUST_NOT_RENDER", PromptVisibleRows: byte(len(test.rows)), InputFocused: true}
			rows := promptRows(test.rows...)
			if test.name == "explicit blank and trailing newline" {
				for i := range rows {
					rows[i].BufferLine = uint32(i)
				}
			}
			model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, uint16(len(rows)-1), 0, 0, 0, protocol.Selection{}), 800)
			p, _ := model.agentPromptPlacement()
			body := strings.Split(ansi.Strip(model.content()), "\n")
			for i, text := range test.rows {
				line := body[p.row+i]
				if got := ansi.TruncateLeft(line, p.col, ""); !strings.HasPrefix(got, text) {
					t.Fatalf("row %d = %q, want prefix %q at %d", i, line, text, p.col)
				}
				if text == "" && strings.TrimSpace(ansi.Truncate(ansi.TruncateLeft(line, p.col, ""), p.width, "")) != "" {
					t.Fatalf("explicit/trailing empty row %d gained text: %q", i, line)
				}
			}
			if strings.Contains(strings.Join(body, "\n"), "RAW_METADATA") {
				t.Fatal("composer rendered raw metadata")
			}
			cursor := model.View().Cursor
			if cursor == nil || cursor.X != model.layout.body.X+p.col || cursor.Y != model.layout.body.Y+p.row+len(rows)-1 {
				t.Fatalf("canonical windowed cursor not transformed into composer: %+v", cursor)
			}
		})
	}
}

func TestComposerGrowthReservesControlsAndReportsMaximumCapacity(t *testing.T) {
	for _, width := range []int{1, 3, 12, 40, 80, 120, 160} {
		for _, height := range []int{3, 4, 6, 8, 12, 24} {
			for visible := 1; visible <= 10; visible++ {
				t.Run(fmt.Sprintf("%dx%d/%d", width, height, visible), func(t *testing.T) {
					model := New(uint16(width), uint16(height), nil, nil)
					texts := make([]string, visible)
					for i := range texts {
						texts[i] = fmt.Sprintf("r%d", i)
					}
					chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: byte(visible)}
					model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows(texts...), 0, 0, 0, 0, protocol.Selection{}), 900)
					p, _ := model.agentPromptPlacement()
					body := strings.Split(ansi.Strip(model.content()), "\n")
					if len(body) != model.bodyHeight() || p.rows > p.maxRows || p.height > model.bodyHeight() {
						t.Fatalf("invalid bounded composition p=%+v lines=%d body=%d", p, len(body), model.bodyHeight())
					}
					if p.rows != min(visible, p.maxRows) {
						t.Fatalf("growth did not use authoritative visible rows: %+v", p)
					}
					physicalRows := max(model.bodyHeight()-agentPanelHeaderRows(model.bodyHeight())-2*p.border-1, 0)
					if p.maxRows != physicalRows {
						t.Fatalf("fit = %d, want physical capacity %d", p.maxRows, physicalRows)
					}
					if p.controlsRow >= len(body) {
						t.Fatalf("controls clipped: %+v", p)
					}
					label := "Send"
					if p.innerWidth < 4 {
						label = "↑"
					}
					if !strings.Contains(body[p.controlsRow], label) {
						t.Fatalf("missing controls in %q", body[p.controlsRow])
					}
					collapsed := chat
					collapsed.PromptVisibleRows = 1
					allocated := agentComposerAllocation(collapsed, p.innerWidth+2*p.border, model.bodyHeight()-agentPanelHeaderRows(model.bodyHeight()))
					if allocated.maxRows != p.maxRows {
						t.Fatalf("maximum fit depends on collapsed height: %d vs %d", allocated.maxRows, p.maxRows)
					}
				})
			}
		}
	}
}

func TestPromptUnicodeSelectionAndPointerUseCommittedSourceRows(t *testing.T) {
	model := New(80, 20, nil, nil)
	rows := promptRows("hidden first wrap", "a界e\u0301😀z", "selected tail", "")
	selection := protocol.Selection{Type: 1, StartRow: 0, StartCol: 1, EndRow: 1, EndCol: 4}
	chat := protocol.AgentChat{Visible: true, Prompt: "raw", PromptVisibleRows: 3, InputFocused: true}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 1, 4, 0, 1, selection), 0x123456789)
	p, _ := model.agentPromptPlacement()
	for _, cell := range []struct {
		col   int
		units uint32
	}{{0, 0}, {1, 1}, {2, 1}, {3, 2}, {4, 4}, {5, 4}, {6, 6}} {
		assertTextTarget(t, model, model.layout.body.X+p.col+cell.col, model.layout.body.Y+p.row, protocol.AgentPromptWindowID, 0x123456789, 1, rows[1].ID, cell.units)
	}
	window := model.windows[protocol.AgentPromptWindowID]
	selectedBody := model.content()
	window.Selection = protocol.Selection{}
	model.windows[protocol.AgentPromptWindowID] = window
	if selectedBody == model.content() {
		t.Fatal("cross-wrap selection did not affect production composer")
	}
	cursor := model.View().Cursor
	if cursor == nil || cursor.X != model.layout.body.X+p.col+4 || cursor.Y != model.layout.body.Y+p.row+1 {
		t.Fatalf("unicode caret placement = %+v", cursor)
	}
}

func TestPromptWheelUsesSourceGenerationWithoutLocalCaretOrTranscriptScroll(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(80, 18, out, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "raw", PromptVisibleRows: 2, InputFocused: true}
	rows := promptRows("first", "second", "third")
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 1, 3, 0, 0, protocol.Selection{}), 0x123456789)
	p, _ := model.agentPromptPlacement()
	drainOutboundPackets(out)
	beforeCursor, beforeBody := model.View().Cursor, model.content()
	for _, button := range []tea.MouseButton{tea.MouseWheelDown, tea.MouseWheelUp} {
		updated, _ := model.Update(tea.MouseWheelMsg(tea.Mouse{X: model.layout.body.X + p.col, Y: model.layout.body.Y + p.row, Button: button}))
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		assertPacketCount(t, packets, protocol.EncodeGUIAgentPromptScroll(protocol.AgentPromptScroll{WindowID: protocol.AgentPromptWindowID, Generation: 0x123456789, DeltaRows: int32(wheelDeltaSign(button))}), 1)
		if len(packets) != 1 {
			t.Fatalf("wheel leaked raw coordinate or editor scroll: %x", packets)
		}
		if !model.transcript.pinned || len(model.localPresentation.scrolls) != 0 || model.content() != beforeBody || *model.View().Cursor != *beforeCursor {
			t.Fatal("wheel mutated local prompt/caret/transcript")
		}
	}
}

func TestPromptFitTracksResizeAndCommittedPresentationNotContentEpoch(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(120, 24, out, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "raw", PromptVisibleRows: 1}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("one"), 0, 1, 0, 0, protocol.Selection{}), 0x123456789)
	p, _ := model.agentPromptPlacement()
	packets := drainOutboundPackets(out)
	assertPacketCount(t, packets, protocol.EncodeGUIAgentPromptFit(protocol.AgentPromptFit{WindowID: protocol.AgentPromptWindowID, Generation: 0x123456789, Columns: uint16(p.width), MaxRows: uint16(p.maxRows)}), 1)
	physicalRows := model.bodyHeight() - agentPanelHeaderRows(model.bodyHeight()) - 2*p.border - 1
	if p.maxRows != physicalRows || p.maxRows <= 8 || p.rows != 1 {
		t.Fatalf("fit must report uncapped physical capacity, not policy or collapsed rows: %+v", p)
	}
	updated, _ := model.Update(tea.WindowSizeMsg{Width: 44, Height: 8})
	model = updated.(Model)
	resized, _ := model.agentPromptPlacement()
	packets = drainOutboundPackets(out)
	assertPacketCount(t, packets, protocol.EncodeGUIAgentPromptFit(protocol.AgentPromptFit{WindowID: protocol.AgentPromptWindowID, Generation: 0x123456789, Columns: uint16(resized.width), MaxRows: uint16(resized.maxRows)}), 1)
	if resized.width == p.width || resized.maxRows >= p.maxRows {
		t.Fatalf("resize ignored physical allocation: before=%+v after=%+v", p, resized)
	}
	model.reportAgentPromptFit()
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("unchanged observation duplicated: %x", packets)
	}
}

func TestPromptControlsUseCommandsAndNewlineRemainsKeyInput(t *testing.T) {
	for _, status := range []byte{0, 1, 2} {
		out := make(chan []byte, 64)
		model := New(12, 6, out, nil)
		chat := protocol.AgentChat{Visible: true, Status: status, Prompt: "raw", PromptVisibleRows: 8, InputFocused: true}
		model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("one", "two", "three"), 0, 0, 0, 0, protocol.Selection{}), 700)
		p, _ := model.agentPromptPlacement()
		drainOutboundPackets(out)
		packet, handled := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + p.col - p.prefix, Y: model.layout.body.Y + p.controlsRow}))
		command := "agent_submit_or_newline"
		if status != 0 {
			command = "agent_abort"
		}
		want := protocol.EncodeGUIExecuteCommand(command)
		if !handled || !bytes.Equal(packet, want) {
			t.Fatalf("status %d control = %x, want %x", status, packet, want)
		}
		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter, Mod: tea.ModShift}))
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		if len(packets) != 1 || packets[0][0] != generated.OPKeyPress || packets[0][5] != protocol.ModShift {
			t.Fatalf("newline key intercepted: %x", packets)
		}
	}
}

func TestPromptOverflowAndReverseCursorMovementFollowCommittedViewport(t *testing.T) {
	model := New(80, 24, nil, nil)
	texts := make([]string, 16)
	for i := range texts {
		texts[i] = fmt.Sprintf("visual-row-%02d", i)
	}
	rows := promptRows(texts...)
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 8, InputFocused: true}
	for i, test := range []struct{ anchor, cursor int }{{0, 7}, {8, 7}, {3, 0}, {0, 0}} {
		model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, uint16(test.cursor), 2, 0, uint16(test.anchor), protocol.Selection{}), uint64(1000+i))
		p, _ := model.agentPromptPlacement()
		body := strings.Split(ansi.Strip(model.content()), "\n")
		for offset := range 8 {
			if !strings.Contains(body[p.row+offset], texts[test.anchor+offset]) {
				t.Fatalf("viewport anchor %d row %d = %q", test.anchor, offset, body[p.row+offset])
			}
		}
		cursor := model.View().Cursor
		if cursor == nil || cursor.Y != model.layout.body.Y+p.row+test.cursor {
			t.Fatalf("reverse cursor not mapped to committed viewport: %+v", cursor)
		}
		if !strings.Contains(body[p.controlsRow], "Send") {
			t.Fatal("overflow clipped controls")
		}
	}
}

func TestPromptExactWidthCaretUsesCanonicalEmptyContinuation(t *testing.T) {
	model := New(80, 20, nil, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 2}
	model.chrome[generated.OPGuiAgentChat] = protocol.ChromePayload{AgentChat: chat}
	p, _ := model.agentPromptPlacement()
	rows := promptRows(strings.Repeat("x", p.width), "")
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 1, 0, 0, 0, protocol.Selection{}), 811)
	p, _ = model.agentPromptPlacement()
	body := strings.Split(ansi.Strip(model.content()), "\n")
	if strings.Count(body[p.row], "x") != p.width || strings.Contains(body[p.row+1], "x") {
		t.Fatalf("exact-width row or its empty insertion continuation changed: %q / %q", body[p.row], body[p.row+1])
	}
	cursor := model.View().Cursor
	if cursor == nil || cursor.X != model.layout.body.X+p.col || cursor.Y != model.layout.body.Y+p.row+1 {
		t.Fatalf("exact-width insertion cursor = %+v", cursor)
	}
}

func TestPromptPastePillRetainsCanonicalSpanStyling(t *testing.T) {
	model := New(80, 20, nil, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 1}
	rows := promptRows("[Pasted 14 lines]")
	rows[0].Spans = []protocol.Span{{StartCol: 0, EndCol: 17, FG: 0x12ab34, BG: 0x345678, Attrs: 1}}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 0, 0, 0, 0, protocol.Selection{}), 812)
	styled := model.content()
	plainRows := promptRows("[Pasted 14 lines]")
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, plainRows, 0, 0, 0, 0, protocol.Selection{}), 813)
	if styled == model.content() || !strings.Contains(ansi.Strip(styled), "[Pasted 14 lines]") || strings.ContainsRune(styled, 0) {
		t.Fatal("canonical paste pill text or styling lost")
	}
}

func TestPromptDragCaptureKeepsSourceAtEdgesAndReleasesStaleTargets(t *testing.T) {
	model := New(80, 20, nil, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 2}
	rows := promptRows("one", "two")
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, rows, 0, 0, 0, 0, protocol.Selection{}), 814)
	p, _ := model.agentPromptPlacement()
	updated, _, handled := model.handleEditorTextMouse(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: model.layout.body.X + p.col, Y: model.layout.body.Y + p.row}))
	if !handled || updated.textDrag == nil {
		t.Fatal("prompt press failed to capture")
	}
	updated, packet, handled := updated.handleEditorTextMouse(tea.MouseMotionMsg(tea.Mouse{Button: tea.MouseLeft, X: 0, Y: 0}))
	if !handled || binary.BigEndian.Uint16(packet[1:3]) != protocol.AgentPromptWindowID || binary.BigEndian.Uint64(packet[3:11]) != 814 || binary.BigEndian.Uint64(packet[15:23]) != rows[0].ID || packet[31] != 0 || int8(packet[32]) != -1 {
		t.Fatalf("drag lost prompt origin or enabled horizontal scroll: %x", packet)
	}
	delete(updated.textPresentations, protocol.AgentPromptWindowID)
	updated, packet, handled = updated.handleEditorTextMouse(tea.MouseReleaseMsg(tea.Mouse{Button: tea.MouseLeft, X: 0, Y: 0}))
	if !handled || updated.textDrag != nil || binary.BigEndian.Uint16(packet[1:3]) != protocol.AgentPromptWindowID || binary.BigEndian.Uint64(packet[3:11]) != 0 {
		t.Fatalf("stale prompt release not cleaned up: %x", packet)
	}
}

func TestPromptFitUsesActualSidebarAndDetailsAllocation(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(160, 24, out, nil)
	model.chrome[generated.OPGuiFileTree] = protocol.ChromePayload{Tree: protocol.FileTree{Visible: true, Width: 24}}
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 1}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("one"), 0, 0, 0, 0, protocol.Selection{}), 815)
	p, _ := model.agentPromptPlacement()
	panelWidth := model.layout.body.Width - 2
	mainWidth := panelWidth - agentDetailsWidth(panelWidth) - agentColumnGap()
	if model.layout.body.X == 0 || p.width != mainWidth-2-p.prefix-1 {
		t.Fatalf("fit ignored sidebar, details rail, border, prefix or padding: p=%+v body=%+v", p, model.layout.body)
	}
	cursor := model.View().Cursor
	if cursor == nil || cursor.X != model.layout.body.X+p.col {
		t.Fatalf("sidebar cursor transform = %+v", cursor)
	}
	packets := drainOutboundPackets(out)
	assertPacketCount(t, packets, protocol.EncodeGUIAgentPromptFit(protocol.AgentPromptFit{WindowID: protocol.AgentPromptWindowID, Generation: 815, Columns: uint16(p.width), MaxRows: uint16(p.maxRows)}), 1)
}

func TestInvalidPromptFrameCannotPublishRowsOrSourceIdentity(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(80, 20, out, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 1}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("committed"), 0, 0, 0, 0, protocol.Selection{}), 816)
	previous := model.content()
	drainOutboundPackets(out)
	invalidRows := promptRows("replacement", "duplicate identity")
	invalidRows[1].ID = invalidRows[0].ID
	updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
		beginFrame(2, 1),
		decodedPromptCommand(t, invalidRows, 0, 0, 0, 0, protocol.Selection{}),
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 999}},
		commitFrame(2),
	}})
	model = updated.(Model)
	if model.lastCommittedSeq != 1 || model.textPresentations[protocol.AgentPromptWindowID] != 816 || model.content() != previous {
		t.Fatal("invalid prompt transaction partially published")
	}
	for _, packet := range drainOutboundPackets(out) {
		if bytes.Equal(packet, protocol.EncodeTextPresentationState(protocol.AgentPromptWindowID, 999, protocol.TextPresentationActive)) {
			t.Fatal("rejected prompt presentation became active")
		}
		if len(packet) >= 12 && packet[0] == generated.OPGuiAction && packet[1] == generated.GUIActionAgentPromptFit && binary.BigEndian.Uint64(packet[4:12]) == 999 {
			t.Fatal("fit echoed rejected presentation")
		}
	}
}

func TestChatDoesNotRouteTranscriptWheelThroughHiddenSemanticCanvas(t *testing.T) {
	model := New(80, 20, nil, nil)
	chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: 1}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("one"), 0, 0, 0, 0, protocol.Selection{}), 817)
	model.putWindow(textMouseWindow(7, 0, "hidden editor", 700))
	if id, ok := model.presentationScrollWindowAt(model.layout.body.X, model.layout.body.Y); ok {
		t.Fatalf("chat transcript was claimed by hidden semantic window %d", id)
	}
}

func TestComposerControlConsumerOnlyActivatesVisibleLabel(t *testing.T) {
	for _, width := range []uint16{1, 3, 4, 6, 12, 40, 80, 120} {
		for _, status := range []byte{0, 1, 2, 3} {
			t.Run(fmt.Sprintf("width%d/status%d", width, status), func(t *testing.T) {
				out := make(chan []byte, 64)
				model := New(width, 16, out, nil)
				chat := protocol.AgentChat{Visible: true, Status: status, Prompt: "draft", PromptVisibleRows: 1, InputFocused: true}
				model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("draft"), 0, 0, 0, 0, protocol.Selection{}), 818)
				p, _ := model.agentPromptPlacement()
				label := "Send"
				command := "agent_submit_or_newline"
				if status == 1 || status == 2 {
					label = "Stop"
					command = "agent_abort"
				}
				if p.innerWidth < 4 {
					if label == "Send" {
						label = "↑"
					} else {
						label = "■"
					}
				}
				labelWidth := displayWidth(label)
				controlStart := model.layout.body.X + p.col - p.prefix
				controlY := model.layout.body.Y + p.controlsRow
				body := strings.Split(ansi.Strip(model.content()), "\n")
				if !strings.Contains(body[p.controlsRow], label) {
					t.Fatalf("control label not visible: %q", body[p.controlsRow])
				}
				if p.innerWidth >= 48 && !strings.Contains(body[p.controlsRow], "Shift+Enter newline") {
					t.Fatalf("missing newline help: %q", body[p.controlsRow])
				}
				want := protocol.EncodeGUIExecuteCommand(command)
				drainOutboundPackets(out)
				for cell := range p.innerWidth {
					click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: controlStart + cell, Y: controlY})
					packet, handled := model.semanticMousePacket(click)
					if cell < labelWidth {
						if !handled || !bytes.Equal(packet, want) {
							t.Fatalf("visible label cell %d did not activate: %x handled=%v", cell, packet, handled)
						}
					} else if handled || packet != nil {
						t.Fatalf("help/padding cell %d activated composer: %x handled=%v", cell, packet, handled)
					}
					updated, _ := model.Update(click)
					model = updated.(Model)
					actionPackets := 0
					for _, outbound := range drainOutboundPackets(out) {
						if len(outbound) != 0 && outbound[0] == generated.OPKeyPress {
							t.Fatalf("control/help cell %d entered mode-dependent key dispatch: %x", cell, outbound)
						}
						if len(outbound) > 1 && outbound[0] == generated.OPGuiAction && outbound[1] == generated.GUIActionExecuteCommand {
							actionPackets++
							if cell >= labelWidth || !bytes.Equal(outbound, want) {
								t.Fatalf("help/padding cell %d submitted/stopped draft: %x", cell, outbound)
							}
						}
					}
					if cell < labelWidth && actionPackets != 1 {
						t.Fatalf("visible label cell %d emitted %d command packets", cell, actionPackets)
					}
				}
			})
		}
	}
}

func TestComposerClickDispatchesCommandAcrossCommittedModesAndFocus(t *testing.T) {
	for _, mode := range []byte{0, 1, 2} {
		for _, focused := range []bool{false, true} {
			for _, status := range []byte{0, 1, 2} {
				t.Run(fmt.Sprintf("mode%d/focused%t/status%d", mode, focused, status), func(t *testing.T) {
					out := make(chan []byte, 64)
					model := New(80, 20, out, nil)
					chat := protocol.AgentChat{
						Visible: true, Status: status, Prompt: "draft", PromptVisibleRows: 1,
						PromptVimMode: mode, InputFocused: focused,
					}
					model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows("draft"), 0, 0, 0, 0, protocol.Selection{}), 819)
					// Publish the real agent owner while retaining the committed source.
					// InputFocused distinguishes transcript focus from prompt focus.
					updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
						beginFrame(2, 1), focusOwnerCommand(0, 2),
						{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 819}},
						commitFrame(2),
					}})
					model = updated.(Model)
					component, _ := model.focusedComponent()
					if model.lastCommittedSeq != 2 || component != "agent" {
						t.Fatalf("agent focus frame not admitted: seq=%d component=%q", model.lastCommittedSeq, component)
					}
					p, _ := model.agentPromptPlacement()
					x := model.layout.body.X + p.col - p.prefix
					y := model.layout.body.Y + p.controlsRow
					before := model.View().Content
					buffer := cellbuf.NewBuffer(model.width, model.height)
					cellbuf.SetContent(buffer, before)
					cell := buffer.Cell(x, y)
					if cell == nil || cell.Rune != 'S' || !strings.Contains(ansi.Strip(before), "draft") {
						t.Fatal("test click does not target the drawn composer control")
					}
					drainOutboundPackets(out)
					updated, _ = model.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: x, Y: y}))
					model = updated.(Model)
					command := "agent_submit_or_newline"
					if status == 1 || status == 2 {
						command = "agent_abort"
					}
					packets := drainOutboundPackets(out)
					if len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeGUIExecuteCommand(command)) {
						t.Fatalf("drawn control did not dispatch %s directly: %x", command, packets)
					}
					after, _ := model.agentChat()
					if after.InputFocused != focused || after.PromptVimMode != mode || model.View().Content != before {
						t.Fatal("control locally changed focus, mode or draft instead of sending the authoritative command")
					}
				})
			}
		}
	}
}

func TestCommittedPromptSelectionUsesExclusiveDisplayEndpoints(t *testing.T) {
	type expectedCell struct {
		row, col int
		text     string
		width    int
		selected bool
	}
	for _, test := range []struct {
		name      string
		rows      []string
		selection protocol.Selection
		cells     []expectedCell
	}{
		{
			name:      "one ASCII grapheme",
			rows:      []string{"ab"},
			selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1},
			cells:     []expectedCell{{0, 0, "a", 1, true}, {0, 1, "b", 1, false}},
		},
		{
			name:      "one wide grapheme",
			rows:      []string{"a界z"},
			selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 1, EndRow: 0, EndCol: 3},
			cells:     []expectedCell{{0, 0, "a", 1, false}, {0, 1, "界", 2, true}, {0, 3, "z", 1, false}},
		},
		{
			name:      "one combining grapheme",
			rows:      []string{"ae\u0301z"},
			selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 1, EndRow: 0, EndCol: 2},
			cells:     []expectedCell{{0, 0, "a", 1, false}, {0, 1, "e\u0301", 1, true}, {0, 2, "z", 1, false}},
		},
		{
			name:      "inclusive source end advanced across wrap",
			rows:      []string{"ab界", "e\u0301z"},
			selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 2, EndRow: 1, EndCol: 1},
			cells:     []expectedCell{{0, 1, "b", 1, false}, {0, 2, "界", 2, true}, {1, 0, "e\u0301", 1, true}, {1, 1, "z", 1, false}},
		},
		{
			name:      "exclusive end at next wrap start",
			rows:      []string{"ab界", "e\u0301z"},
			selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 2, EndRow: 1, EndCol: 0},
			cells:     []expectedCell{{0, 1, "b", 1, false}, {0, 2, "界", 2, true}, {1, 0, "e\u0301", 1, false}, {1, 1, "z", 1, false}},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			model := New(80, 20, nil, nil)
			chat := protocol.AgentChat{Visible: true, Prompt: "metadata", PromptVisibleRows: byte(len(test.rows)), PromptVimMode: 2, InputFocused: true}
			// Core advances inclusive source endpoints before publishing these exclusive display-cell ranges; the frontend must not advance again.
			model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows(test.rows...), 0, 0, 0, 0, test.selection), 820)
			p, _ := model.agentPromptPlacement()
			view := model.View().Content
			canvas := lipgloss.NewCanvas(model.width, model.height)
			canvas.Compose(lipgloss.NewLayer(view))
			for _, expected := range test.cells {
				x := model.layout.body.X + p.col + expected.col
				y := model.layout.body.Y + p.row + expected.row
				cell := canvas.CellAt(x, y)
				if cell == nil || cell.Content != expected.text || cell.Width != expected.width {
					t.Fatalf("wrong composed grapheme at %d,%d: %+v, want %q width %d", expected.row, expected.col, cell, expected.text, expected.width)
				}
				background := model.palette().AgentInputSurface()
				if expected.selected {
					background = model.palette().Selection()
				}
				if cell.Style.Bg == nil {
					t.Fatalf("composed grapheme %q has no background", expected.text)
				}
				r, g, b, a := cell.Style.Bg.RGBA()
				wantR, wantG, wantB, wantA := background.RGBA()
				if r != wantR || g != wantG || b != wantB || a != wantA {
					t.Fatalf("grapheme %q at %d,%d selection=%t: got rgba(%d,%d,%d,%d), want rgba(%d,%d,%d,%d)", expected.text, expected.row, expected.col, expected.selected, r, g, b, a, wantR, wantG, wantB, wantA)
				}
			}
			for _, row := range test.rows {
				if !strings.Contains(ansi.Strip(view), row) {
					t.Fatalf("committed grapheme text changed during selection drawing: want %q in %q", row, ansi.Strip(view))
				}
			}
		})
	}
}
