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

func TestAgentTranscriptPinEdgesEmitExactlyOnceFromUpdate(t *testing.T) {
	for _, test := range []struct {
		name string
		away tea.Msg
		back tea.Msg
	}{
		{
			name: "keys",
			away: tea.KeyPressMsg(tea.Key{Code: 'k', Text: "k"}),
			back: tea.KeyPressMsg(tea.Key{Code: 'G', Text: "G"}),
		},
		{
			name: "wheel",
			away: tea.MouseWheelMsg(tea.Mouse{X: 10, Y: 1, Button: tea.MouseWheelUp}),
			back: tea.MouseWheelMsg(tea.Mouse{X: 10, Y: 1, Button: tea.MouseWheelDown}),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			out := make(chan []byte, 32)
			model := residentModel(t, 100)
			model.out = out
			if mouse, ok := test.away.(tea.MouseMsg); ok {
				value := mouse.Mouse()
				value.Y = model.layout.body.Y
				test.away = tea.MouseWheelMsg(value)
				value = test.back.(tea.MouseMsg).Mouse()
				value.Y = model.layout.body.Y
				test.back = tea.MouseWheelMsg(value)
			}

			updated, _ := model.Update(test.away)
			model = updated.(Model)
			updated, _ = model.Update(test.away)
			model = updated.(Model)
			updated, _ = model.Update(test.back)
			model = updated.(Model)
			updated, _ = model.Update(test.back)
			_ = updated.(Model)

			packets := drainOutboundPackets(out)
			assertPacketCount(t, packets, protocol.EncodeGUIChatScrolledAwayFromBottom(), 1)
			assertPacketCount(t, packets, protocol.EncodeGUIChatReturnedToBottom(), 1)
		})
	}
}

func assertPacketCount(t *testing.T, packets [][]byte, want []byte, count int) {
	t.Helper()
	got := 0
	for _, packet := range packets {
		if bytes.Equal(packet, want) {
			got++
		}
	}
	if got != count {
		t.Fatalf("packet %v count = %d, want %d; outbound=%v", want, got, count, packets)
	}
}

func TestAgentTranscriptNavigationMapping(t *testing.T) {
	page := 17
	tests := []struct {
		name    string
		key     tea.Key
		want    int
		handled bool
	}{
		{"j", tea.Key{Code: 'j'}, 1, true},
		{"k", tea.Key{Code: 'k'}, -1, true},
		{"ctrl-d", tea.Key{Code: 'd', Mod: tea.ModCtrl}, 8, true},
		{"ctrl-u", tea.Key{Code: 'u', Mod: tea.ModCtrl}, -8, true},
		{"G", tea.Key{Code: 'G'}, 1 << 20, true},
		{"shift-G", tea.Key{Code: 'G', Mod: tea.ModShift}, 1 << 20, true},
		{"page down", tea.Key{Code: tea.KeyPgDown}, page, true},
		{"page up", tea.Key{Code: tea.KeyPgUp}, -page, true},
		{"ctrl-j", tea.Key{Code: 'j', Mod: tea.ModCtrl}, 0, false},
		{"alt-k", tea.Key{Code: 'k', Mod: tea.ModAlt}, 0, false},
		{"shift-j", tea.Key{Code: 'j', Mod: tea.ModShift}, 0, false},
		{"ctrl-shift-d", tea.Key{Code: 'd', Mod: tea.ModCtrl | tea.ModShift}, 0, false},
		{"ctrl-alt-u", tea.Key{Code: 'u', Mod: tea.ModCtrl | tea.ModAlt}, 0, false},
		{"ctrl-G", tea.Key{Code: 'G', Mod: tea.ModCtrl}, 0, false},
		{"ctrl-page-up", tea.Key{Code: tea.KeyPgUp, Mod: tea.ModCtrl}, 0, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, handled := agentTranscriptScrollRows(tea.KeyPressMsg(test.key), page)
			if got != test.want || handled != test.handled {
				t.Fatalf("mapping = (%d, %v), want (%d, %v)", got, handled, test.want, test.handled)
			}
		})
	}
}

func TestAgentTranscriptComposerFocusGatesLocalNavigation(t *testing.T) {
	for _, test := range []struct {
		name         string
		inputFocused bool
		wantPinned   bool
		wantEdge     int
	}{
		{"composer focused", true, true, 0},
		{"transcript focused", false, false, 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			out := make(chan []byte, 8)
			model := residentModel(t, 100)
			chat := visibleAgentChat()
			chat.InputFocused = test.inputFocused
			model.chrome[generated.OPGuiAgentChat] = protocol.ChromePayload{AgentChat: chat}
			model.out = out

			updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'k', Text: "k"}))
			model = updated.(Model)
			if model.transcript.pinned != test.wantPinned {
				t.Fatalf("pinned = %v, want %v", model.transcript.pinned, test.wantPinned)
			}
			packets := drainOutboundPackets(out)
			keyPackets := 0
			for _, packet := range packets {
				if len(packet) > 0 && packet[0] == generated.OPKeyPress {
					keyPackets++
				}
			}
			if keyPackets != 1 {
				t.Fatalf("key packet count = %d, want 1; outbound=%v", keyPackets, packets)
			}
			assertPacketCount(t, packets, protocol.EncodeGUIChatScrolledAwayFromBottom(), test.wantEdge)
		})
	}
}

func TestFocusedComposerReceivesEveryTranscriptNavigationKey(t *testing.T) {
	keys := []tea.Key{
		{Code: 'j', Text: "j"},
		{Code: 'k', Text: "k"},
		{Code: 'd', Mod: tea.ModCtrl},
		{Code: 'u', Mod: tea.ModCtrl},
		{Code: 'G', Text: "G"},
		{Code: tea.KeyPgUp},
		{Code: tea.KeyPgDown},
	}
	for _, key := range keys {
		t.Run(key.String(), func(t *testing.T) {
			out := make(chan []byte, 8)
			model := residentModel(t, 100)
			chat := visibleAgentChat()
			chat.InputFocused = true
			model.chrome[generated.OPGuiAgentChat] = protocol.ChromePayload{AgentChat: chat}
			model.out = out

			updated, _ := model.Update(tea.KeyPressMsg(key))
			model = updated.(Model)
			if !model.transcript.pinned || model.transcript.anchor != (transcriptAnchor{}) {
				t.Fatalf("focused composer navigation changed transcript: %+v", model.transcript)
			}
			packets := drainOutboundPackets(out)
			keyPackets := 0
			for _, packet := range packets {
				if len(packet) > 0 && packet[0] == generated.OPKeyPress {
					keyPackets++
				}
			}
			if keyPackets != 1 {
				t.Fatalf("key packet count = %d, want 1; outbound=%v", keyPackets, packets)
			}
			assertPacketCount(t, packets, protocol.EncodeGUIChatScrolledAwayFromBottom(), 0)
			assertPacketCount(t, packets, protocol.EncodeGUIChatReturnedToBottom(), 0)
		})
	}
}

func TestAgentTranscriptPageKeysUseContentBudget(t *testing.T) {
	model := residentModel(t, 100)
	chat, _ := model.agentChat()
	panelWidth := max(model.width-2, 1)
	mainBudget := model.bodyHeight() - 1
	composerRows := len(model.renderAgentComposer(chat, panelWidth))
	expected := mainBudget - composerRows - 1 - 1
	page := model.agentTranscriptPageSize()
	if page != expected {
		t.Fatalf("page size = %d, want transcript content budget %d", page, expected)
	}
	if page >= model.layout.body.Height {
		t.Fatalf("page size %d should exclude body chrome from height %d", page, model.layout.body.Height)
	}
	if got, handled := agentTranscriptScrollRows(tea.KeyPressMsg(tea.Key{Code: tea.KeyPgDown}), page); !handled || got != expected {
		t.Fatalf("page-down mapping = (%d, %v), want (%d, true)", got, handled, expected)
	}
}

func TestAgentTranscriptTruncationAffordanceOnlyAtResidentTop(t *testing.T) {
	model := residentModel(t, 20)
	model.transcript.truncated = true
	model.transcript.pinned = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}
	width := 50
	budget := 8

	rows := model.transcriptRenderer.render(model, model.transcript, budget, width)
	if got := ansi.Strip(strings.Join(rows, "\n")); !strings.Contains(got, "earlier messages hidden") {
		t.Fatalf("top of truncated transcript lacks affordance: %q", got)
	}
	if len(rows) != budget {
		t.Fatalf("affordance should stay inside content budget: got %d rows, want %d", len(rows), budget)
	}

	model.transcript.scrollBy(1)
	rows = model.transcriptRenderer.render(model, model.transcript, budget, width)
	if got := ansi.Strip(strings.Join(rows, "\n")); strings.Contains(got, "earlier messages hidden") {
		t.Fatalf("affordance should disappear below resident top: %q", got)
	}

	model.transcript.truncated = false
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}
	rows = model.transcriptRenderer.render(model, model.transcript, budget, width)
	if got := ansi.Strip(strings.Join(rows, "\n")); strings.Contains(got, "earlier messages hidden") {
		t.Fatalf("complete transcript should not show truncation affordance: %q", got)
	}
}

func TestTruncationAffordanceIsReachableWhenResidentRowsExactlyFillBudget(t *testing.T) {
	model := residentModel(t, 0)
	model.transcript.apply(protocol.AgentTranscript{
		Present:   true,
		Mode:      0,
		Epoch:     1,
		Truncated: true,
		Messages:  []protocol.AgentChatMessage{{ID: 1, Kind: agentKindSystem, Text: "retained"}},
	})
	width := 50
	budget := 1

	rows := model.transcriptRenderer.render(model, model.transcript, budget, width)
	if got := ansi.Strip(strings.Join(rows, "\n")); !strings.Contains(got, "retained") {
		t.Fatalf("pinned view should keep the retained bottom row: %q", got)
	}

	model.transcript.scrollBy(-1)
	rows = model.transcriptRenderer.render(model, model.transcript, budget, width)
	if got := ansi.Strip(strings.Join(rows, "\n")); !strings.Contains(got, "earlier messages hidden") {
		t.Fatalf("scrolling to resident top should reveal truncation affordance: %q", got)
	}
	if model.transcript.pinned {
		t.Fatal("truncation affordance should act as a scrollable row above an exact-fit transcript")
	}
}

func TestReplacementPinIntentReportingThroughUpdate(t *testing.T) {
	tests := []struct {
		name             string
		prepare          func(*Model)
		frame            func(Model) protocol.AgentTranscript
		wantReturned     int
		wantPinned       bool
		wantAnchorStable bool
	}{
		{
			name: "all resident rows fit after shrink",
			prepare: func(model *Model) {
				model.transcript.pinned = false
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}
			},
			frame: func(Model) protocol.AgentTranscript {
				return replaceFrame(1, msg(100, "only"))
			},
			wantReturned: 1,
			wantPinned:   true,
		},
		{
			name: "resident rows exactly fill viewport after shrink",
			prepare: func(model *Model) {
				model.transcript.pinned = false
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}
			},
			frame: func(model Model) protocol.AgentTranscript {
				budget := model.agentTranscriptPageSize()
				if budget < 3 {
					t.Fatalf("transcript budget = %d, need at least 3 rows for exact-fit fixture", budget)
				}
				lines := make([]protocol.AgentStyledLine, budget-3)
				for index := range lines {
					lines[index] = protocol.AgentStyledLine{{Text: fmt.Sprintf("row %d", index)}}
				}
				return replaceFrame(1, protocol.AgentChatMessage{
					ID:   100,
					Kind: agentKindAssistantMarkdown,
					MarkdownBlocks: []protocol.AgentMarkdownBlock{{
						Kind:  0x07,
						Label: "Exact fit",
						Flags: 1,
						Lines: lines,
					}},
				})
			},
			wantReturned: 1,
			wantPinned:   true,
		},
		{
			name: "removed near-tail anchor clamps to bottom",
			prepare: func(model *Model) {
				model.transcript.pinned = false
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[90].slot}
			},
			frame: func(model Model) protocol.AgentTranscript {
				messages := append([]protocol.AgentChatMessage(nil), model.transcript.messages[:80]...)
				return replaceFrame(1, messages...)
			},
			wantReturned: 1,
			wantPinned:   true,
		},
		{
			name: "same-epoch replacement retains stable anchor",
			prepare: func(model *Model) {
				model.transcript.pinned = false
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[40].slot, row: 1}
			},
			frame: func(model Model) protocol.AgentTranscript {
				messages := append([]protocol.AgentChatMessage(nil), model.transcript.messages...)
				messages[len(messages)-1].Text = "streamed tail revision"
				return replaceFrame(1, messages...)
			},
			wantPinned:       false,
			wantAnchorStable: true,
		},
		{
			name: "epoch flip re-pins without local intent",
			prepare: func(model *Model) {
				model.transcript.pinned = false
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[40].slot, row: 1}
				model.transcript.pinTransition = pinScrolledAway
			},
			frame: func(Model) protocol.AgentTranscript {
				return replaceFrame(2, msg(1, "fresh session"))
			},
			wantPinned: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			out := make(chan []byte, 16)
			model := residentModel(t, 100)
			model.out = out
			model.lastCommittedSeq = 1
			test.prepare(&model)
			anchor := model.transcript.anchor
			frame := test.frame(model)

			updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{
				beginFrame(2, 1),
				transcriptCommand(frame),
				commitFrame(2),
			}})
			model = updated.(Model)
			if model.transcript.pinned != test.wantPinned {
				t.Fatalf("pinned = %v, want %v", model.transcript.pinned, test.wantPinned)
			}
			if test.wantAnchorStable && model.transcript.anchor != anchor {
				t.Fatalf("stable replacement moved anchor: before=%+v after=%+v", anchor, model.transcript.anchor)
			}
			packets := drainOutboundPackets(out)
			assertPacketCount(t, packets, []byte{generated.OPGuiAction, 0x5D}, test.wantReturned)
			assertPacketCount(t, packets, protocol.EncodeGUIChatScrolledAwayFromBottom(), 0)
		})
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

func TestContentShrinkClampsAnchorAndReportsReturn(t *testing.T) {
	t.Run("clamp to bottom", func(t *testing.T) {
		model := residentModel(t, 10)
		width := 50
		budget := 5
		model.transcript.pinned = false
		model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[9].slot}

		got := model.transcriptRenderer.render(model, model.transcript, budget, width)
		want := windowBottom(model.agentTranscriptAllLines(model.transcript.messages, width), budget)
		if !model.transcript.pinned || strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Fatalf("underfilled anchor did not clamp and re-pin: pinned=%v", model.transcript.pinned)
		}
		if model.transcript.takePinTransition() != pinReturned {
			t.Fatal("clamp-to-bottom did not report pinReturned")
		}
	})

	t.Run("everything fits", func(t *testing.T) {
		model := residentModel(t, 10)
		width := 50
		budget := 5
		model.transcript.pinned = false
		model.transcript.anchor = transcriptAnchor{slot: model.transcript.entries[0].slot}
		model.transcript.apply(replaceFrame(1, msg(10, "only")))
		model.transcriptRenderer.render(model, model.transcript, budget, width)
		if !model.transcript.pinned || model.transcript.anchor != (transcriptAnchor{}) {
			t.Fatalf("all-fitting replacement did not pin: %+v", model.transcript)
		}
		if model.transcript.takePinTransition() != pinReturned {
			t.Fatal("all-fitting replacement did not report pinReturned")
		}
	})
}
