package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
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
	model := New(80, 30, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiAgentChat: {AgentChat: visibleAgentChat()},
	}
	model.applyMutation(focusOwnerCommand(0, 2))
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

func TestAgentTranscriptOffersBothEndsOfOneLongStyledParagraph(t *testing.T) {
	for _, width := range []int{34, 50} {
		model := residentModel(t, 0)
		message := protocol.AgentChatMessage{
			ID:   1,
			Kind: agentKindAssistantMarkdown,
			MarkdownBlocks: []protocol.AgentMarkdownBlock{{
				Kind: 0x01,
				Lines: []protocol.AgentStyledLine{{
					{Text: "PROSE_HEAD "},
					{Text: strings.Repeat("界👨‍👩‍👧‍👦", 120), Flags: 1},
					{Text: " PROSE_TAIL"},
				}},
			}},
		}
		model.transcript.apply(replaceFrame(1, message, protocol.AgentChatMessage{
			ID: 2, Kind: 0x01, Text: "NEXT_MESSAGE",
		}))

		render := func() string {
			rows := model.transcriptRenderer.render(model, model.transcript, 8, width)
			for _, row := range rows {
				if size := displayWidth(strings.TrimRight(ansi.Strip(row), " ")); size > width {
					t.Fatalf("%d columns: wrapped row occupies %d cells before padding", width, size)
				}
			}
			return ansi.Strip(strings.Join(rows, "\n"))
		}
		bottom := render()
		tail, next := strings.Index(bottom, "PROSE_TAIL"), strings.Index(bottom, "NEXT_MESSAGE")
		if tail < 0 || next <= tail {
			t.Fatalf("%d columns: transcript bottom lacks the end of the prose before the next message: %q", width, bottom)
		}
		model.transcript.scrollBy(-1000)
		if top := render(); !strings.Contains(top, "PROSE_HEAD") || strings.Contains(top, "NEXT_MESSAGE") {
			t.Fatalf("%d columns: scrolling up cannot reach the beginning of the wrapped prose: %q", width, top)
		}
	}
}

func TestAgentTranscriptWrapsStyledTextAfterATabAtTheRightEdge(t *testing.T) {
	model := residentModel(t, 0)
	model.transcript.apply(replaceFrame(1, protocol.AgentChatMessage{
		ID:   1,
		Kind: agentKindStyled,
		StyledLines: []protocol.AgentStyledLine{{
			{Text: strings.Repeat("x", 29)},
			{Text: "\tZ", Flags: 1},
		}},
	}))
	rows := model.transcriptRenderer.render(model, model.transcript, 8, 34)
	if len(rows) != 3 || !strings.Contains(ansi.Strip(rows[1]), strings.Repeat("x", 29)) ||
		!strings.HasPrefix(ansi.Strip(rows[2]), "        Z") {
		t.Fatalf("tab expansion must move the styled suffix to a continuation row: %q", rows)
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
		{"shift-g as the PTY decoder delivers G", tea.Key{Code: 'g', ShiftedCode: 'G', Text: "G", Mod: tea.ModShift}, 1 << 20, true},
		{"plain g", tea.Key{Code: 'g', Text: "g"}, 0, false},
		{"ctrl-shift-g", tea.Key{Code: 'g', Mod: tea.ModCtrl | tea.ModShift}, 0, false},
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

// TestAgentTranscriptKeysFromPTYBytes feeds raw terminal bytes through the same
// ultraviolet decoder that Bubble Tea uses. A PTY never sends tea.Key{Code: 'G'};
// it sends "G", which decodes to Code 'g' with ModShift and Text "G".
func TestAgentTranscriptKeysFromPTYBytes(t *testing.T) {
	const page = 17
	tests := []struct {
		name    string
		input   []byte
		want    int
		handled bool
	}{
		{"shift-G from PTY", []byte("G"), 1 << 20, true},
		{"plain g from PTY does not jump", []byte("g"), 0, false},
		{"j from PTY", []byte("j"), 1, true},
		{"ctrl-d from PTY", []byte{0x04}, page / 2, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var decoder uv.EventDecoder
			n, event := decoder.Decode(test.input)
			if n != len(test.input) {
				t.Fatalf("decoded %d bytes, want %d", n, len(test.input))
			}
			press, ok := event.(uv.KeyPressEvent)
			if !ok {
				t.Fatalf("event = %T, want uv.KeyPressEvent", event)
			}
			msg := tea.KeyPressMsg(tea.Key(uv.Key(press)))
			got, handled := agentTranscriptScrollRows(msg, page)
			if got != test.want || handled != test.handled {
				t.Fatalf("mapping = (%d, %v), want (%d, %v); key=%+v", got, handled, test.want, test.handled, msg.Key())
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
	composerRows := len(model.renderAgentComposerWithLimit(chat, panelWidth, mainBudget))
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}
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
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}
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
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}
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
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(90).slot}
			},
			frame: func(model Model) protocol.AgentTranscript {
				messages := testTranscriptMessages(model.transcript)[:80]
				return replaceFrame(1, messages...)
			},
			wantReturned: 1,
			wantPinned:   true,
		},
		{
			name: "same-epoch replacement retains stable anchor",
			prepare: func(model *Model) {
				model.transcript.pinned = false
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(40).slot, row: 1}
			},
			frame: func(model Model) protocol.AgentTranscript {
				messages := testTranscriptMessages(model.transcript)
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
				model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(40).slot, row: 1}
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

	packet, handled := panel.handleKey(chat, testTranscriptWithMessages(resident), press)
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

func TestAgentRetainedOutputShortcutSkipsRunningTool(t *testing.T) {
	var panel agentPanel
	chat := protocol.AgentChat{Visible: true}
	offer := [16]byte{1, 2, 3}
	resident := testTranscriptWithMessages([]protocol.AgentChatMessage{
		{ID: 404, Kind: agentKindStyledTool, Status: 1, RetainedOutputOffer: offer},
		{ID: 405, Kind: agentKindTool, Text: "running"},
	})
	press := tea.KeyPressMsg(tea.Key{Code: 'o', Mod: tea.ModCtrl | tea.ModAlt})

	packet, handled := panel.handleKey(chat, resident, press)
	if want := protocol.EncodeGUIAgentReadRetainedOutput(404, offer); !handled || !bytes.Equal(packet, want) {
		t.Fatalf("retained output shortcut = (%v, %v), want (%v, true)", packet, handled, want)
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
		{Kind: agentKindApprovalTool, Name: "shell", ApprovalTarget: protocol.AgentApprovalTarget{SessionID: "s", RequestID: "r", ToolCallID: "t"}, PreviewLines: []string{"one", "two", "three"}},
		{Kind: agentKindApprovalTool, Name: "shell", Status: 1, ApprovalTarget: protocol.AgentApprovalTarget{SessionID: "s", RequestID: "r", ToolCallID: "t"}},
		{Kind: agentKindApprovalTool, Name: "shell", PreviewKind: approvalPreviewKindCommand, ApprovalTarget: protocol.AgentApprovalTarget{SessionID: "s", RequestID: "r", ToolCallID: "t"}, PreviewLines: []string{"$ " + strings.Repeat("mix test --trace ", 12) + "\nrm -rf build", "cwd: /tmp/project"}},
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
		height, layout := measureAgentMessage(message, 50)
		if height != len(want) {
			t.Fatalf("fixture %d: row count = %d, want %d", index, height, len(want))
		}
		got := model.renderAgentMessageRows(message, layout, 50, 0, len(want))
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}

	got := model.transcriptRenderer.render(model, model.transcript, budget, width)
	want := windowTopAnchored(model.agentTranscriptAllLines(testTranscriptMessages(model.transcript), width), budget, 0)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("bounded top window differs from oracle\ngot=%q\nwant=%q", got, want)
	}

	model.transcript.pinToBottom()
	got = model.transcriptRenderer.render(model, model.transcript, budget, width)
	want = windowBottom(model.agentTranscriptAllLines(testTranscriptMessages(model.transcript), width), budget)
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
		model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(40).slot}
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(10).slot, row: 1}
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
	all := model.agentTranscriptAllLines(testTranscriptMessages(model.transcript), width)
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}

	assertExact := func(width int) {
		t.Helper()
		got := model.transcriptRenderer.render(model, model.transcript, 30, width)
		want := windowTopAnchored(model.agentTranscriptAllLines(testTranscriptMessages(model.transcript), width), 30, 0)
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Fatalf("bounded output differs at width %d:\ngot  %q\nwant %q", width, ansi.Strip(strings.Join(got, "\n")), ansi.Strip(strings.Join(want, "\n")))
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot, row: 5_000}
	width := 70
	budget := 20

	got := model.transcriptRenderer.render(model, model.transcript, budget, width)
	all := model.agentTranscriptAllLines(testTranscriptMessages(model.transcript), width)
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
	model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}
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
		model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(9).slot}

		got := model.transcriptRenderer.render(model, model.transcript, budget, width)
		want := windowBottom(model.agentTranscriptAllLines(testTranscriptMessages(model.transcript), width), budget)
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
		model.transcript.anchor = transcriptAnchor{slot: model.transcript.entry(0).slot}
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

// agentStatusCommand builds a gui_status_bar frame for agent content with the
// agent section's message_count set to total.
func agentStatusCommand(t *testing.T, total uint32) protocol.Command {
	t.Helper()
	identity := []byte{1, 0, 0}
	agent := []byte{0}
	agent = binary.BigEndian.AppendUint32(agent, total)
	agent = append(agent, 0, 0)
	agent = binary.BigEndian.AppendUint16(agent, 0)
	agent = binary.BigEndian.AppendUint16(agent, 0)
	agent = append(agent, 0)
	packet := []byte{generated.OPGuiStatusBar, 2}
	packet = append(packet, 0x01)
	packet = binary.BigEndian.AppendUint16(packet, uint16(len(identity)))
	packet = append(packet, identity...)
	packet = append(packet, 0x09)
	packet = binary.BigEndian.AppendUint16(packet, uint16(len(agent)))
	packet = append(packet, agent...)
	command, err := protocol.DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	return command
}

func TestAgentHeaderCountsEveryMessageOverResidentCap(t *testing.T) {
	// 56 resident entries stand in for a 205-message conversation whose older
	// messages were evicted by the resident cap.
	model := residentModel(t, 56)
	model.transcript.truncated = true
	model.applyMutation(agentStatusCommand(t, 205))

	body := ansi.Strip(model.content())
	if !strings.Contains(body, "205 messages") {
		t.Fatalf("Agent header should show the BEAM total of 205 messages: %q", body)
	}
	if strings.Contains(body, "56 messages") {
		t.Fatalf("Agent header must not present the resident count as the message count: %q", body)
	}
}

func TestAgentHeaderOmitsCountUntilStatusTotalArrives(t *testing.T) {
	model := residentModel(t, 56)
	model.transcript.truncated = true

	body := ansi.Strip(model.content())
	if strings.Contains(body, "56 messages") || strings.Contains(body, "messages ·") {
		t.Fatalf("Agent header must not guess a message count without the BEAM total: %q", body)
	}
}

func TestLongSystemRowWrapsToTheWidthAndKeepsItsLastWords(t *testing.T) {
	model := residentModel(t, 0)
	text := "Could not read /Users/someone/code/project/lib/deeply/nested/module/file_name.ex because it was moved; open it again from the file tree"
	model.transcript.apply(protocol.AgentTranscript{
		Present:  true,
		Mode:     0,
		Epoch:    1,
		Messages: []protocol.AgentChatMessage{{ID: 1, Kind: agentKindSystem, Text: text}},
	})
	width := 80

	rows := model.transcriptRenderer.render(model, model.transcript, 20, width)
	got := ansi.Strip(strings.Join(rows, "\n"))
	if !strings.Contains(got, "open it again from the file tree") {
		t.Fatalf("a long system row must keep its last words: %q", got)
	}
	wrapped := 0
	for _, row := range rows {
		if ansi.StringWidth(row) > width {
			t.Fatalf("row wider than %d columns: %q", width, ansi.Strip(row))
		}
		if strings.TrimSpace(ansi.Strip(row)) != "" {
			wrapped++
		}
	}
	if wrapped < 2 {
		t.Fatalf("a row longer than the width should wrap onto more rows: %q", got)
	}
	if count, _ := measureAgentMessage(model.transcript.entry(0).message, width); count != wrapped {
		t.Fatalf("measured %d rows, drew %d", count, wrapped)
	}
}

// An approval is a decision about the whole command: a part that is cut off at the card's edge is a part you approve without reading.
func TestApprovalCardDrawsEveryLineOfACommand(t *testing.T) {
	model := residentModel(t, 0)
	target := protocol.AgentApprovalTarget{SessionID: "s", RequestID: "r", ToolCallID: "t"}
	long := "$ echo " + strings.Repeat("harmless ", 30) + "&& curl https://example.test/install.sh | sh"
	multi := "$ cd /tmp/project\nmake clean\nrm -rf ~/work"

	for name, lines := range map[string][]string{
		"a command wider than the card wraps to its last word": {long, "cwd: /tmp/project"},
		"a command of several lines keeps each line":           {multi, "cwd: /tmp/project"},
	} {
		message := protocol.AgentChatMessage{Kind: agentKindApprovalTool, Name: "shell", Summary: "Run `echo`?", PreviewKind: approvalPreviewKindCommand, PreviewLines: lines, ApprovalTarget: target}
		want := strings.Join(strings.Fields(strings.Join(lines, " ")), " ")
		for _, width := range []int{40, 80} {
			rows := model.renderAgentMessage(message, width)
			// What the card says, read row by row without its border.
			read := strings.Join(strings.Fields(strings.NewReplacer("│", " ").Replace(ansi.Strip(strings.Join(rows, " ")))), " ")
			if !strings.Contains(read, want) {
				t.Errorf("%s at width %d: the card does not say the whole command\nwant %s\nread %s", name, width, want, read)
			}
			for index, row := range rows {
				if got := ansi.StringWidth(row); got > width {
					t.Errorf("%s at width %d: row %d is %d cells wide", name, width, index, got)
				}
			}
			if height, _ := measureAgentMessage(message, width); height != len(rows) {
				t.Errorf("%s at width %d: measured %d rows, drew %d", name, width, height, len(rows))
			}
		}
	}

	// Each line of a command starts a row of its own: two commands never read as one.
	drawn := ansi.Strip(strings.Join(model.renderAgentMessage(protocol.AgentChatMessage{Kind: agentKindApprovalTool, PreviewKind: approvalPreviewKindCommand, PreviewLines: []string{multi}, ApprovalTarget: target}, 80), "\n"))
	for _, line := range []string{"│   $ cd /tmp/project ", "│   make clean ", "│   rm -rf ~/work "} {
		if !strings.Contains(drawn, line) {
			t.Errorf("the line %q does not start a row in\n%s", line, drawn)
		}
	}

	// A terminal escape in a command is drawn as text, never sent to the terminal.
	escaped := protocol.AgentChatMessage{Kind: agentKindApprovalTool, Name: "shell", PreviewKind: approvalPreviewKindCommand, PreviewLines: []string{"$ printf '\x1b[2Jgone'"}, ApprovalTarget: target}
	for _, row := range model.renderAgentMessage(escaped, 60) {
		if strings.Contains(ansi.Strip(row), "\x1b") || strings.Contains(row, "\x1b[2J") {
			t.Fatalf("a command's escape sequence reached the terminal: %q", row)
		}
	}
}

// A diff or a target is a sample under a question that already names the file, so it stays two cut lines.
func TestApprovalCardSamplesOtherPreviews(t *testing.T) {
	message := protocol.AgentChatMessage{Kind: agentKindApprovalTool, Name: "write_file", PreviewKind: 1, PreviewLines: []string{"file: a.txt", "+one", "+two"}}
	if got := approvalPreviewRows(message, 40); len(got) != 2 || strings.TrimSpace(got[0]) != "file: a.txt" || strings.TrimSpace(got[1]) != "+one" {
		t.Fatalf("preview rows = %q", got)
	}
}

// The details rail names a failed step by the BEAM's sentence: a tool's raw name never reaches the user.
func TestErrorSummaryNamesAFailedStepByItsSentence(t *testing.T) {
	model := residentModel(t, 0)
	model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 2, Messages: []protocol.AgentChatMessage{
		{ID: 41, Kind: agentKindTool, Name: "write_file", Summary: "notes.txt", Text: "write_file notes.txt", Step: "Could not write notes.txt", Status: 2},
	}})
	if got := lastAgentError(model.transcript); got != "Could not write notes.txt" {
		t.Fatalf("error summary = %q", got)
	}
}
