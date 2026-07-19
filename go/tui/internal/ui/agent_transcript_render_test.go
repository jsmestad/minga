package ui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func visibleAgentChat() protocol.AgentChat {
	return protocol.AgentChat{
		Visible:   true,
		ModelName: "anthropic:claude-sonnet-4",
		// A stale 0x78 messages payload the resident store must override.
		Messages: []protocol.AgentChatMessage{{ID: 999, Kind: 0x01, Text: "STALE_0x78_MESSAGE"}},
	}
}

func residentModel(t *testing.T, count int) Model {
	t.Helper()
	model := New(80, 30, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiAgentChat: {AgentChat: visibleAgentChat()},
	}
	msgs := make([]protocol.AgentChatMessage, 0, count)
	for i := 1; i <= count; i++ {
		msgs = append(msgs, protocol.AgentChatMessage{ID: uint32(i), Kind: 0x01, Text: fmt.Sprintf("USERMSG_%d", i)})
	}
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Messages: msgs})
	return model
}

func TestAgentTranscriptRendersFromResidentStore(t *testing.T) {
	model := residentModel(t, 12)
	body := ansi.Strip(model.content())

	if strings.Contains(body, "STALE_0x78_MESSAGE") {
		t.Fatalf("transcript must render from the resident store, not 0x78 messages: %q", body)
	}
	if !strings.Contains(body, "USERMSG_12") {
		t.Fatalf("newest resident message should be visible at the bottom: %q", body)
	}
}

func TestAgentTranscriptLocalScrollRevealsOlderSameFrame(t *testing.T) {
	model := residentModel(t, 40)

	// Pinned: the oldest message is off-screen.
	if body := ansi.Strip(model.content()); strings.Contains(body, "USERMSG_1 ") {
		t.Fatalf("oldest message should be scrolled off while pinned: %q", body)
	}

	// Scroll up hard; the same frame repaints from local data.
	model.transcript.scrollBy(-10000)
	body := ansi.Strip(model.content())

	if model.transcript.pinned {
		t.Fatalf("scrolling up should unpin the transcript")
	}
	if model.transcript.pinTransition != pinScrolledAway {
		t.Fatalf("scroll-up should record a scrolled-away pin transition, got %d", model.transcript.pinTransition)
	}
	if !strings.Contains(body, "USERMSG_1") {
		t.Fatalf("scrolled-up transcript should reveal the oldest message: %q", body)
	}
	if strings.Contains(body, "USERMSG_40") {
		t.Fatalf("scrolled to the top, the newest message should be off-screen: %q", body)
	}
}

func TestAgentToggleUsesStableMessageID(t *testing.T) {
	var panel agentPanel
	chat := protocol.AgentChat{Visible: true}
	resident := []protocol.AgentChatMessage{
		{ID: 101, Kind: agentKindUser, Text: "u"},
		{ID: 202, Kind: agentKindAssistant, Text: "a"},
		{ID: 303, Kind: agentKindUser, Text: "u2"},
		{ID: 404, Kind: agentKindTool, Text: "tool"},
	}
	press := tea.KeyPressMsg(tea.Key{Code: 'x', Mod: tea.ModCtrl | tea.ModAlt})

	packet, handled := panel.handleKey(chat, resident, press)
	if !handled {
		t.Fatalf("Ctrl+Alt+X should be handled when a tool message exists")
	}
	if packet[0] != generated.OPGuiAction || packet[1] != generated.GUIActionAgentToolToggle {
		t.Fatalf("unexpected toggle packet header: %v", packet)
	}
	if id := uint32(packet[2])<<24 | uint32(packet[3])<<16 | uint32(packet[4])<<8 | uint32(packet[5]); id != 404 {
		t.Fatalf("toggle message ID = %d, want 404", id)
	}
}

func TestAgentTranscriptTailMatchesAllLinesBottom(t *testing.T) {
	// The cheap pinned tail render must equal the bottom of the full layout so the
	// pinned and unpinned (scrolled-up) paths never diverge at the seam.
	model := residentModel(t, 25)
	messages := model.transcript.messages
	width := max(model.width-2, 1)

	for _, budget := range []int{1, 3, 6, 10, 40} {
		all := model.agentTranscriptAllLines(messages, width)
		wantBottom := windowBottom(all, budget)
		gotTail := model.agentTranscriptTail(messages, budget, width)
		if strings.Join(gotTail, "\n") != strings.Join(wantBottom, "\n") {
			t.Fatalf("budget %d: tail != allLines bottom\ntail=%v\nbottom=%v", budget, gotTail, wantBottom)
		}
	}
}
