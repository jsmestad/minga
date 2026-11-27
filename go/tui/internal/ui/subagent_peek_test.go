package ui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func peekChromeForTest(index uint16, flags byte) protocol.Command {
	siblings := []generated.SubagentPeekSibling{{Token: "child-a", Title: "Audit"}, {Token: "child-b", Title: "Review"}}
	for i := range siblings {
		siblings[i].State = 1
	}
	metadata := generated.GuiSubagentPeekFields{
		ParentWindowID: 16,
		Steps:          []generated.SubagentPeekStep{{EntryID: 3, Token: "child-a", Label: "Started Audit", Report: "1 of 2 reports in"}, {EntryID: 4, Token: "child-b", Label: "Started Review"}},
	}
	if index != 0 {
		selected := siblings[index-1]
		metadata.Panes = []generated.SubagentPeekPane{{
			WindowID: 17, Token: selected.Token, Title: selected.Title, State: selected.State, Index: index, Siblings: siblings, Flags: flags,
			Parent: "Fact check", Brief: "Look for the missing citations", Result: "The first citations checked out", Prompt: "One\n界é!",
			ParentRect: generated.Rect{Width: 39, Height: 25}, PeekRect: generated.Rect{Col: 40, Width: 40, Height: 25},
		}}
	}
	return protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiSubagentPeek, SubagentPeek: metadata}}
}

func peekTranscriptForTest(frame protocol.AgentTranscript) protocol.Command {
	command := transcriptCommand(frame)
	command.Chrome.Opcode = generated.OPGuiSubagentPeekTranscript
	return command
}

func TestSubagentPeekSwitchDoesNotReuseAnotherChildEpoch(t *testing.T) {
	m := residentModel(t, 0)
	m.applyCommands([]protocol.Command{beginFrame(1, 0), testThemeCommand(),
		transcriptCommand(replaceFrame(7, msg(3, "parent original"))),
		peekChromeForTest(1, peekFocused), peekTranscriptForTest(replaceFrame(7, msg(3, "child A original"))), commitFrame(1)})
	m.applyCommands([]protocol.Command{beginFrame(2, 1),
		transcriptCommand(appendFrame(7, 0, 1, msg(4, "parent must not commit"))),
		peekChromeForTest(2, peekFocused), peekTranscriptForTest(appendFrame(7, 0, 1, msg(4, "child B cannot append to A"))), commitFrame(2)})
	if m.lastCommittedSeq != 1 || m.peekToken != "child-a" || m.peekTranscript.len() != 1 || m.transcript.len() != 1 {
		t.Fatal("invalid child update mutated a committed pane or the parent")
	}
	m.applyCommands([]protocol.Command{beginFrame(3, 1), peekChromeForTest(2, peekFocused), commitFrame(3)})
	if m.lastCommittedSeq != 3 || m.peekTranscript.len() != 0 || m.subagentPeek().Panes[0].Token != "child-b" {
		t.Fatal("waiting for sibling B shows sibling A or rejects the new pane")
	}
	m.applyCommands([]protocol.Command{beginFrame(4, 3), peekTranscriptForTest(replaceFrame(7, msg(3, "child B reply"))), commitFrame(4)})
	if m.peekTranscript.entry(0).message.Text != "child B reply" || m.transcript.entry(0).message.Text != "parent original" {
		t.Fatal("child B reply changed the parent or did not reach its own transcript")
	}
	m.applyCommands([]protocol.Command{beginFrame(5, 4), peekChromeForTest(0, 0), commitFrame(5)})
	if m.peekTranscript != nil || m.transcript.entry(0).message.Text != "parent original" {
		t.Fatal("closing the peek did not retire only the child")
	}
}

func TestSubagentPeekParentEnterAndPointerAddressDisplayedInvocation(t *testing.T) {
	m := residentModel(t, 0)
	parent := []protocol.AgentChatMessage{{ID: 3, Kind: agentKindTool, Name: "subagent", Collapsed: true}, {ID: 4, Kind: agentKindTool, Name: "subagent", Collapsed: true}}
	updated, _ := m.Update(port.PacketMsg{Commands: []protocol.Command{beginFrame(1, 0), testThemeCommand(),
		transcriptCommand(replaceFrame(7, parent...)), peekChromeForTest(0, 0), commitFrame(1)}})
	m = updated.(Model)
	screen := ansi.Strip(m.View().Content)
	for _, label := range []string{"Started Audit", "Started Review", "1 of 2 reports in"} {
		if !strings.Contains(screen, label) {
			t.Fatalf("parent does not show %q: %q", label, screen)
		}
	}
	chat, _ := m.agentChat()
	for range 2 {
		if _, handled := m.peekParentKey(chat, tea.KeyPressMsg{Code: tea.KeyTab}); !handled {
			t.Fatal("Tab did not select a displayed Started row")
		}
	}
	chat.DraftAttachmentOffer = 7
	want := protocol.EncodeGUISubagentPeekAction(protocol.SubagentPeekStartedKey, 16, "7", "child-b", 0, 0)
	if packet, handled := m.peekParentKey(chat, tea.KeyPressMsg{Code: tea.KeyEnter}); !handled || !bytes.Equal(packet, want) {
		t.Fatalf("Return did not open the selected child: %x", packet)
	}

	updated, _ = m.Update(port.PacketMsg{Commands: []protocol.Command{beginFrame(2, 1), peekChromeForTest(2, peekFocused|peekEditing|peekHasResult),
		peekTranscriptForTest(replaceFrame(7, protocol.AgentChatMessage{ID: 3, Kind: agentKindAssistant, Text: "Independent child activity"})), commitFrame(2)}})
	m = updated.(Model)
	shown := m.View()
	screen = ansi.Strip(shown.Content)
	for _, label := range []string{"Started Audit", "Fact check › Review", "Independent child activity", "The first citations checked out"} {
		if !strings.Contains(screen, label) {
			t.Fatalf("split does not show %q: %q", label, screen)
		}
	}
	id := peekZone(protocol.SubagentPeekCompose, 17, "child-b", "1/0")
	zone := m.zones.Get(id)
	if zone == nil {
		t.Fatal("multiline child draft did not expose its second row")
	}
	click := tea.MouseClickMsg{X: zone.StartX + 2, Y: zone.StartY, Button: tea.MouseLeft}
	want = protocol.EncodeGUISubagentPeekAction(protocol.SubagentPeekCompose, 17, "child-b", "", 1, 3)
	shown.OnMouse(click)
	if hit := m.presentedClick.take(); !hit.claimed || !bytes.Equal(hit.packet, want) {
		t.Fatalf("click did not address the child, draft row and UTF-8 column of é: %x want %x", hit.packet, want)
	}
}

func TestSubagentPeekParentFitCannotClaimChildCells(t *testing.T) {
	out := make(chan []byte, 64)
	m := New(80, 24, out)
	chat := protocol.AgentChat{Visible: true, Prompt: "parent draft", PromptVisibleRows: 1}
	m = commitPrompt(t, m, chat, decodedPromptCommand(t, promptRows("parent draft"), 0, 0, 0, 0, protocol.Selection{}), 823)
	before, _ := m.agentPromptPlacement()
	updated, _ := m.Update(port.PacketMsg{Commands: []protocol.Command{
		beginFrame(2, 1), peekChromeForTest(1, peekFocused),
		{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: protocol.AgentPromptWindowID, PresentationID: 823}},
		commitFrame(2),
	}})
	m = updated.(Model)
	after, ok := m.agentPromptPlacement()
	if !ok || after.width >= before.width {
		t.Fatalf("the parent draft still fits as if it owned the full window: %d vs %d", after.width, before.width)
	}
	y := m.layout.body.Y + after.row
	left := m.layout.body.X + after.col
	if _, hit := m.agentPromptTextTargetAt(left, y, false); !hit {
		t.Fatal("the rendered parent composer lost its own pointer target")
	}
	if _, hit := m.agentPromptTextTargetAt(m.layout.body.X+45, y, false); hit {
		t.Fatal("a child cell still targets the parent's draft")
	}
}

func TestSubagentPeekNarrowHeaderAndSiblingStripKeepChildIdentity(t *testing.T) {
	m := residentModel(t, 0)
	m.width = 60
	peek := peekChromeForTest(1, peekFocused)
	pane := &peek.Chrome.SubagentPeek.Panes[0]
	pane.Title = "Terminal Audit"
	pane.Parent = "An unnecessarily long description of the parent conversation"
	pane.Siblings = make([]generated.SubagentPeekSibling, 16)
	for i := range pane.Siblings {
		pane.Siblings[i] = generated.SubagentPeekSibling{Token: fmt.Sprintf("child-%d", i+1), State: 1}
	}
	pane.Token = pane.Siblings[0].Token
	updated, _ := m.Update(port.PacketMsg{Commands: []protocol.Command{
		beginFrame(1, 0), testThemeCommand(), peek, commitFrame(1),
	}})
	m = updated.(Model)
	shown := m.View()
	if !strings.Contains(ansi.Strip(shown.Content), "Terminal Audit ×") {
		t.Fatal("the narrow header lost the selected child name or its close control")
	}
	last := m.zones.Get(peekZone(protocol.SubagentPeekSibling, 17, "child-1", "child-16"))
	if last == nil || !strings.Contains(ansi.Strip(shown.Content), "1 of 16") {
		t.Fatal("the narrow sibling strip lost its last child or progress count")
	}
	shown.OnMouse(tea.MouseClickMsg{X: last.StartX, Y: last.StartY, Button: tea.MouseLeft})
	want := protocol.EncodeGUISubagentPeekAction(protocol.SubagentPeekSibling, 17, "child-1", "child-16", 0, 0)
	if hit := m.presentedClick.take(); !hit.claimed || !bytes.Equal(hit.packet, want) {
		t.Fatalf("the last visible glyph did not select its child: %x", hit.packet)
	}
}
