package ui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func visibleAgentChat() protocol.AgentChat {
	return protocol.AgentChat{
		Visible:   true,
		ModelName: "anthropic:claude-sonnet-4",
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

func TestProductionKeyAndWheelScrollUpdateAnchorSameFrame(t *testing.T) {
	model := residentModel(t, 100)
	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'k'}))
	model = updated.(Model)
	if model.transcript.pinned || model.transcript.anchor.slot == 0 {
		t.Fatalf("key scroll did not establish local anchor: %+v", model.transcript)
	}
	keyAnchor := model.transcript.anchor
	keyView := model.View().Content

	wheel := tea.MouseWheelMsg(tea.Mouse{X: 10, Y: model.layout.body.Y, Button: tea.MouseWheelUp})
	updated, _ = model.Update(wheel)
	model = updated.(Model)
	if model.transcript.anchor == keyAnchor {
		t.Fatalf("wheel scroll did not advance anchor: %+v", model.transcript.anchor)
	}
	if model.View().Content == keyView {
		t.Fatal("wheel scroll did not repaint the production View in the same update")
	}
	if work := model.transcriptRenderer.work; work.MessagesVisited > model.layout.body.Height*2 {
		t.Fatalf("local wheel scroll exceeded viewport work bound: %s", work)
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

func TestAgentMessageRowCountAndRangeMatchCurrentRenderer(t *testing.T) {
	model := residentModel(t, 0)
	fixtures := []protocol.AgentChatMessage{
		{Kind: agentKindUser, Text: "one\n\ntwo\nthree"},
		{Kind: agentKindAssistant, Text: "one\ntwo\nthree\nfour"},
		{Kind: agentKindThinking, Text: "one\ntwo", Collapsed: false},
		{Kind: agentKindThinking, Text: "one\ntwo", Collapsed: true},
		{Kind: agentKindTool, Name: "shell", Summary: "run", Result: "one\ntwo", Status: 1},
		{Kind: agentKindTool, Name: "shell", Summary: "run", Result: "one\ntwo", Status: 1, Collapsed: true},
		{Kind: agentKindApprovalTool, Name: "shell", PreviewLines: []string{"one", "two", "three"}},
		{Kind: agentKindUsage},
		{Kind: agentKindAssistantMarkdown, MarkdownBlocks: []protocol.AgentMarkdownBlock{
			{Kind: 0x01, Lines: []protocol.AgentStyledLine{{{Text: "text"}}}},
			{Kind: 0x05},
			{Kind: 0x06},
			{Kind: 0x07, Label: "Code", Flags: 1, Lines: []protocol.AgentStyledLine{{{Text: "one"}}, {{Text: "two"}}}},
		}},
	}

	for index, message := range fixtures {
		want := model.renderAgentMessage(message, 50)
		if got := agentMessageRowCount(message); got != len(want) {
			t.Fatalf("fixture %d: row count = %d, want %d", index, got, len(want))
		}
		got := model.renderAgentMessageRows(message, 50, 0, len(want))
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Fatalf("fixture %d: ranged output differs from renderer", index)
		}
	}
}

func TestBoundedTranscriptMatchesAllLinesOracle(t *testing.T) {
	model := residentModel(t, 30)
	width := max(model.width-2, 1)
	budget := 17
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}

	got := model.transcriptRenderer.render(model, model.transcript, budget, width)
	want := windowTopAnchored(model.agentTranscriptAllLines(model.transcript.messages, width), budget, 0)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("bounded top window differs from oracle\ngot=%q\nwant=%q", got, want)
	}

	model.transcript.pinToBottom()
	got = model.transcriptRenderer.render(model, model.transcript, budget, width)
	want = windowBottom(model.agentTranscriptAllLines(model.transcript.messages, width), budget)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("bounded bottom window differs from oracle\ngot=%q\nwant=%q", got, want)
	}
}

func TestWarmTranscriptWorkIsIndependentOfResidentCount(t *testing.T) {
	var baseline transcriptRenderWork
	for _, count := range []int{100, 1_000, 10_000} {
		model := residentModel(t, count)
		width := max(model.width-2, 1)
		budget := 20
		model.transcript.pinned = false
		model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[40].slot}
		model.transcriptRenderer.render(model, model.transcript, budget, width)
		model.transcriptRenderer.render(model, model.transcript, budget, width)
		work := model.transcriptRenderer.work

		if count == 100 {
			baseline = work
		} else if work.MessagesVisited != baseline.MessagesVisited || work.MessagesMeasured != baseline.MessagesMeasured || work.RowsStyled != baseline.RowsStyled {
			t.Fatalf("count %d work = %s, want same bounds as 100 = %s", count, work, baseline)
		}
		if work.RetainedRows > budget*4 || work.RetainedBytes > transcriptCacheByteCap {
			t.Fatalf("count %d cache exceeded caps: %s", count, work)
		}
	}
}

func TestProductionUpdateViewWorkIsIndependentOfResidentCount(t *testing.T) {
	var baseline transcriptRenderWork
	for _, count := range []int{100, 1_000, 10_000} {
		model := transcriptBenchmarkModel(t, count)
		updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{beginFrame(3, 2), commitFrame(3)}})
		model = updated.(Model)
		_ = model.View().Content
		work := model.transcriptRenderer.work
		if count == 100 {
			baseline = work
		} else if work.MessagesVisited != baseline.MessagesVisited || work.MessagesMeasured != baseline.MessagesMeasured || work.RowsStyled != baseline.RowsStyled {
			t.Fatalf("production count %d work = %s, want same bounds as 100 = %s", count, work, baseline)
		}
	}
}

func TestOffscreenStreamingPreservesAnchorAndReusesVisibleChunks(t *testing.T) {
	model := residentModel(t, 100)
	width := max(model.width-2, 1)
	budget := 20
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[10].slot, row: 1}
	model.transcriptRenderer.render(model, model.transcript, budget, width)
	anchor := model.transcript.anchor

	offscreen := protocol.AgentChatMessage{ID: 101, Kind: agentKindThinking, Text: "offscreen stream"}
	model.transcript.apply(appendFrame(1, 0, 100, offscreen))
	got := model.transcriptRenderer.render(model, model.transcript, budget, width)
	work := model.transcriptRenderer.work
	if model.transcript.anchor != anchor || model.transcript.pinned {
		t.Fatalf("offscreen append moved anchor: before=%+v after=%+v pinned=%v", anchor, model.transcript.anchor, model.transcript.pinned)
	}
	if work.RowsStyled != 0 || work.CacheHits == 0 || work.MessagesMeasured != 0 {
		t.Fatalf("offscreen append repeated visible work: %s", work)
	}
	if !model.transcript.hasAnimatedMessages() {
		t.Fatal("offscreen animated message was not tracked incrementally")
	}
	all := model.agentTranscriptAllLines(model.transcript.messages, width)
	offset := 10*3 + 1
	want := windowTopAnchored(all, budget, offset)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatal("offscreen streaming output differs from oracle")
	}
}

func TestVisibleStreamingCollapseWidthThemeAndAnimationStayExact(t *testing.T) {
	model := residentModel(t, 0)
	messages := []protocol.AgentChatMessage{
		{ID: 1, Kind: agentKindUser, Text: "prompt"},
		{ID: 2, Kind: agentKindThinking, Text: "working", Collapsed: false},
		{ID: 3, Kind: agentKindTool, Name: "shell", Summary: "cmd", Result: "one\ntwo", Status: 1},
	}
	model.transcript.apply(replaceFrame(1, messages...))
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}

	assertExact := func(width int) {
		t.Helper()
		got := model.transcriptRenderer.render(model, model.transcript, 30, width)
		want := windowTopAnchored(model.agentTranscriptAllLines(model.transcript.messages, width), 30, 0)
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Fatalf("bounded output differs at width %d", width)
		}
	}

	assertExact(50)
	model.agent.tick()
	assertExact(50)
	if model.transcriptRenderer.work.RowsStyled == 0 {
		t.Fatal("visible animation was incorrectly served from the static cache")
	}

	messages[2].Collapsed = true
	model.transcript.apply(appendFrame(1, 0, 2, messages[2]))
	assertExact(50)
	model.activePalette.colors[themeAgentTextFG] ^= 0x00FFFF
	assertExact(50)
	if model.transcriptRenderer.work.CacheMisses == 0 {
		t.Fatal("theme change did not invalidate the active cache generation")
	}
	assertExact(38)
	if model.transcriptRenderer.width != 38 {
		t.Fatal("width change did not install a new active cache generation")
	}
}

func TestLargeMessageStylesOnlyBoundedRowChunks(t *testing.T) {
	model := residentModel(t, 0)
	lines := make([]protocol.AgentStyledLine, 10_000)
	for index := range lines {
		lines[index] = protocol.AgentStyledLine{{Text: fmt.Sprintf("CODE_%05d", index)}}
	}
	message := protocol.AgentChatMessage{ID: 1, Kind: agentKindAssistantMarkdown, MarkdownBlocks: []protocol.AgentMarkdownBlock{{Kind: 0x07, Label: "Huge", Flags: 1, Lines: lines}}}
	model.transcript.apply(replaceFrame(1, message))
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot, row: 5_000}
	width := 70
	budget := 20

	got := model.transcriptRenderer.render(model, model.transcript, budget, width)
	all := model.agentTranscriptAllLines(model.transcript.messages, width)
	want := windowTopAnchored(all, budget, 5_000)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatal("large-message row-range output differs from oracle")
	}
	work := model.transcriptRenderer.work
	if work.MessagesVisited != 1 || work.RowsStyled > transcriptChunkRows*2 || work.RetainedRows > budget*4 || work.RetainedBytes > transcriptCacheByteCap {
		t.Fatalf("large message exceeded bounded work: %s", work)
	}
}

func TestTranscriptCacheEvictsAsViewportMoves(t *testing.T) {
	model := residentModel(t, 300)
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}
	width := 60
	budget := 8
	seenEviction := false
	for step := 0; step < 30; step++ {
		model.transcript.scrollBy(12)
		model.transcriptRenderer.render(model, model.transcript, budget, width)
		work := model.transcriptRenderer.work
		seenEviction = seenEviction || work.CacheEvictions > 0
		if work.RetainedRows > budget*4 || work.RetainedBytes > transcriptCacheByteCap {
			t.Fatalf("step %d exceeded cache caps: %s", step, work)
		}
	}
	if !seenEviction {
		t.Fatal("moving viewport never evicted old row chunks")
	}
}

func TestContentShrinkClampsAnchorAndPinsOnlyWhenEverythingFits(t *testing.T) {
	model := residentModel(t, 10)
	width := 50
	budget := 5
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[9].slot}

	got := model.transcriptRenderer.render(model, model.transcript, budget, width)
	want := windowBottom(model.agentTranscriptAllLines(model.transcript.messages, width), budget)
	if model.transcript.pinned || strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("underfilled anchor did not clamp to unpinned tail: pinned=%v", model.transcript.pinned)
	}

	model.transcript.apply(replaceFrame(1, msg(10, "only")))
	model.transcriptRenderer.render(model, model.transcript, budget, width)
	if !model.transcript.pinned || model.transcript.anchor != (transcriptAnchor{}) {
		t.Fatalf("all-fitting replacement did not pin: %+v", model.transcript)
	}
}
