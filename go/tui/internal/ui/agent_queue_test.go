package ui

import (
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

func queueTestString16(out []byte, text string) []byte {
	return append(binary.BigEndian.AppendUint16(out, uint16(len(text))), text...)
}

func queueTestString8(out []byte, text string) []byte {
	return append(append(out, byte(len(text))), text...)
}

func queueTestCommand(t *testing.T, q generated.GuiAgentQueueFields) protocol.Command {
	t.Helper()
	body := []byte{q.Visible}
	if q.Visible != 0 {
		body = binary.BigEndian.AppendUint32(append(body, q.Focused), q.WorkspaceID)
		for _, text := range []string{q.RecordID, q.Title, q.Summary, q.RemovedNote} {
			body = queueTestString16(body, text)
		}
		body = append(binary.BigEndian.AppendUint64(body, q.SelectedID), byte(len(q.Hints)))
		for _, hint := range q.Hints {
			body = queueTestString8(append(body, byte(hint.Action)), hint.Key)
			body = queueTestString16(body, hint.Label)
		}
		for _, rows := range [2][]generated.AgentQueueRow{q.Pending, q.Removed} {
			body = append(body, byte(len(rows)))
			for _, row := range rows {
				body = binary.BigEndian.AppendUint64(body, row.ID)
				body = binary.BigEndian.AppendUint64(body, row.Revision)
				body = queueTestString8(append(body, row.Kind), row.Label)
				body = queueTestString16(body, row.Preview)
				body = binary.BigEndian.AppendUint16(body, row.AttachmentCount)
			}
		}
		body = queueTestString8(body, q.Empty.Glyph)
		body = queueTestString16(body, q.Empty.Title)
		body = queueTestString16(body, q.Empty.Why)
		body = append(body, q.Empty.Selected, byte(len(q.Empty.Actions)))
		for _, action := range q.Empty.Actions {
			body = queueTestString8(body, action.ID)
			body = queueTestString16(body, action.Key)
			body = queueTestString16(body, action.Label)
		}
	}
	packet := append(binary.BigEndian.AppendUint32([]byte{0xAE}, uint32(len(body))), body...)
	commands := port.DecodePacket(packet, func(_ byte, warning string) { t.Fatal(warning) })
	if len(commands) != 1 {
		t.Fatalf("queue packet decoded into %d commands", len(commands))
	}
	return commands[0]
}

func updateQueueTestModel(model Model, msg tea.Msg) Model {
	updated, _ := model.Update(msg)
	return updated.(Model)
}

func commitQueueTestModel(t *testing.T, model Model, queue generated.GuiAgentQueueFields, commands ...protocol.Command) Model {
	t.Helper()
	seq := model.lastCommittedSeq + 1
	frame := []protocol.Command{beginFrame(seq, model.lastCommittedSeq)}
	if model.lastCommittedSeq == 0 {
		frame = append(frame, testThemeCommand())
	}
	frame = append(frame, queueTestCommand(t, queue))
	frame = append(frame, commands...)
	model = updateQueueTestModel(model, port.PacketMsg{Commands: append(frame, commitFrame(seq))})
	if model.lastCommittedSeq != seq {
		t.Fatalf("queue frame %d was not committed", seq)
	}
	return model
}

func queueTestFixture() generated.GuiAgentQueueFields {
	return generated.GuiAgentQueueFields{
		Visible: 1, WorkspaceID: 0x11223344, RecordID: "rec-é", Title: "*minga-queue*", Summary: "2 queued",
		Pending: []generated.AgentQueueRow{
			{ID: 0x100000001, Revision: 0x200000002, Label: "1", Preview: "First to send", AttachmentCount: 2},
			{ID: 0x100000003, Revision: 0x200000004, Label: "2", Preview: "Second to send", Kind: 1},
		},
		RemovedNote: "Removed, not sent. Up to eight, until you close Minga.",
		Removed:     []generated.AgentQueueRow{{ID: 0x300000003, Revision: 0x400000004, Label: "1", Preview: "Removed draft"}},
	}
}

func queueActionTestHex(action byte, row, revision, removed, removedRevision uint64) string {
	return fmt.Sprintf("0776%02x1122334400067265632dc3a9%016x%016x%016x%016x", action, row, revision, removed, removedRevision)
}

func assertQueueClick(t *testing.T, out chan []byte, model Model, shown tea.View, x, y int, wantPacket string) Model {
	t.Helper()
	drainOutboundPackets(out)
	updated, _ := updateFromPublishedView(model, shown, tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft})
	packets := drainOutboundPackets(out)
	if wantPacket == "" {
		if len(packets) != 0 {
			t.Fatalf("inert queue click at %d,%d emitted %x", x, y, packets)
		}
	} else if len(packets) != 1 || fmt.Sprintf("%x", packets[0]) != wantPacket {
		t.Fatalf("queue click at %d,%d emitted %x, want %s", x, y, packets, wantPacket)
	}
	return updated.(Model)
}

func TestAgentQueueMouseUsesFlushedRowAndHintOffers(t *testing.T) {
	model := residentModel(t, 14)
	out := make(chan []byte, 64)
	model.out = out
	queue := queueTestFixture()
	model = commitQueueTestModel(t, model, queue)
	v := model.queueViewport
	model = assertQueueClick(t, out, model, model.View(), v.box.X, v.box.Y+len(v.header), queueActionTestHex(0, queue.Pending[0].ID, queue.Pending[0].Revision, 0, 0))

	queue.Focused, queue.SelectedID = 1, queue.Pending[1].ID
	queue.Hints = []generated.AgentQueueHint{
		{Action: 1, Key: "dd", Label: "remove"},
		{Action: 2, Key: "p", Label: "after"},
		{Action: 3, Key: "P", Label: "before"},
		{Action: 4, Key: "↩", Label: "edit"},
		{Action: 5, Key: "q", Label: "close"},
	}
	model = commitQueueTestModel(t, model, queue, focusOwnerCommand(0, 15))
	shown := model.View()
	var hits []zoneInfo
	for i := range queue.Hints {
		zone := model.zones.Get(agentQueueHintZone(i))
		if zone == nil {
			t.Fatalf("missing shown hint %d in %q", i, ansi.Strip(shown.Content))
		}
		hits = append(hits, *zone)
	}
	selected, removed := queue.Pending[1], queue.Removed[0]
	queue.Pending[1].Revision++
	queue.Removed[0].Revision++
	model = commitQueueTestModel(t, model, queue)
	newer := model.View() // assembling a newer frame must not retarget the old handler
	if newer.Content == shown.Content || ansi.Strip(newer.Content) != ansi.Strip(shown.Content) {
		t.Fatal("a revision-only change must republish without changing any cells")
	}
	for i, want := range []string{
		queueActionTestHex(1, selected.ID, selected.Revision, 0, 0),
		queueActionTestHex(2, selected.ID, selected.Revision, removed.ID, removed.Revision),
		queueActionTestHex(3, selected.ID, selected.Revision, removed.ID, removed.Revision),
		queueActionTestHex(4, selected.ID, selected.Revision, 0, 0),
		queueActionTestHex(5, 0, 0, 0, 0),
	} {
		model = assertQueueClick(t, out, model, shown, hits[i].StartX, hits[i].StartY, want)
	}
	model = assertQueueClick(t, out, model, newer, hits[1].StartX, hits[1].StartY,
		queueActionTestHex(2, selected.ID, selected.Revision+1, removed.ID, removed.Revision+1))
	v = model.queueViewport
	model = assertQueueClick(t, out, model, shown, v.box.X, v.box.Y+len(v.header)+1, queueActionTestHex(0, selected.ID, selected.Revision, 0, 0))
	assertQueueClick(t, out, model, shown, v.box.X, v.box.Y+v.box.Height-1, "") // removed row
}

func TestAgentQueueNoSelectedHintEmptyAndAtomicHide(t *testing.T) {
	model := residentModel(t, 12)
	out := make(chan []byte, 64)
	model.out = out
	queue := queueTestFixture()
	queue.Focused = 1
	queue.Hints = []generated.AgentQueueHint{{Action: 2, Key: "p", Label: "put back"}, {Action: 5, Key: "q", Label: "close"}}
	model = commitQueueTestModel(t, model, queue, focusOwnerCommand(0, 15))
	shown := model.View()
	hint := model.zones.Get(agentQueueHintZone(0))
	if hint == nil {
		t.Fatal("row-bound hint was not visible")
	}
	model = assertQueueClick(t, out, model, shown, hint.StartX, hint.StartY, "")

	queue.Pending, queue.Removed, queue.RemovedNote = nil, nil, ""
	queue.Summary = "Queue"
	queue.Hints = queue.Hints[1:]
	queue.Empty = generated.EmptyList{
		Title: "Nothing queued.", Why: "Messages you queue while Minga works wait here.",
		Actions: []generated.EmptyListAction{{ID: "queue_return_to_composer", Key: "↩", Label: "Back to the composer"}},
	}
	model = commitQueueTestModel(t, model, queue)
	shown = model.View()
	for _, text := range []string{"Nothing queued.", "Back to the composer"} {
		if !strings.Contains(ansi.Strip(shown.Content), text) {
			t.Fatalf("missing empty-list text %q", text)
		}
	}
	v := model.queueViewport
	model = assertQueueClick(t, out, model, shown, v.box.X, v.box.Y+len(v.header)+v.emptyActions, queueActionTestHex(6, 0, 0, 0, 0))
	hint = model.zones.Get(agentQueueHintZone(0))
	if hint == nil {
		t.Fatal("close hint was not visible")
	}
	model = assertQueueClick(t, out, model, shown, hint.StartX, hint.StartY, queueActionTestHex(5, 0, 0, 0, 0))

	seq := model.lastCommittedSeq + 1
	model = updateQueueTestModel(model, port.PacketMsg{Commands: []protocol.Command{
		beginFrame(seq, model.lastCommittedSeq), queueTestCommand(t, generated.GuiAgentQueueFields{}), focusOwnerCommand(0, 2),
	}})
	if model.View().Content != shown.Content {
		t.Fatal("uncommitted hide changed the painted view")
	}
	model = updateQueueTestModel(model, port.PacketMsg{Commands: []protocol.Command{commitFrame(seq)}})
	if model.queueViewport.box.Height != 0 || model.queueScroll.first != 0 || strings.Contains(renderedBody(model), "Nothing queued.") {
		t.Fatal("committed hide retained queue state or pixels")
	}
}

func TestAgentQueueNarrowViewportKeepsComposerAndScrollsLocally(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(29, 10, out)
	chat := protocol.AgentChat{Visible: true, Prompt: "Stay here", PromptVisibleRows: 1, DraftAttachmentOffer: 42}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows(chat.Prompt), 0, 0, 0, 0, protocol.Selection{}), 900)
	queue := queueTestFixture()
	queue.Pending = make([]generated.AgentQueueRow, 32)
	for i := range queue.Pending {
		queue.Pending[i] = generated.AgentQueueRow{ID: uint64(i + 1), Revision: 2, Label: fmt.Sprint(i + 1), Preview: fmt.Sprintf("Waiting %02d", i+1)}
	}
	queue.Focused, queue.SelectedID, queue.Summary = 1, 30, "32 queued"
	without := model.agentTranscriptPageSize()
	focus, err := protocol.DecodeCommand([]byte{0xAA, 0, 10, 0, 15, 0, 0, 0, 0, 0, 0, 0, 1})
	if err != nil {
		t.Fatal(err)
	}
	status := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiStatusBar, Status: protocol.StatusBar{
			ContentKind: 1, Agent: &protocol.StatusAgent{}, Filename: "*minga-queue*",
			Left: []protocol.StatusSegment{{Name: "mode", Text: "NORMAL"}},
		},
	}}
	model = commitQueueTestModel(t, model, queue, focus, status)
	v := model.queueViewport
	p, ok := model.agentPromptPlacement()
	if !ok || p.rows == 0 || v.bodyRows() <= 0 || v.bodyRows() >= len(queue.Pending) || model.agentTranscriptPageSize() >= without {
		t.Fatalf("bad split: composer=%+v queue=%+v without=%d page=%d", p, v, without, model.agentTranscriptPageSize())
	}
	painted := renderedBody(model)
	if !strings.Contains(painted, chat.Prompt) || !strings.Contains(painted, "Waiting 30") || strings.Contains(painted, "Waiting 01") {
		t.Fatalf("wrong small terminal contents: %q", painted)
	}
	if footer := strings.Split(painted, "\n")[model.layout.footer.Y]; !strings.Contains(footer, "*minga-queue*") {
		t.Fatalf("agent variant modeline lost the queue name: %q", footer)
	}
	start := model.queueScroll.first
	wheel := tea.MouseWheelMsg{Button: tea.MouseWheelDown, X: v.box.X, Y: v.box.Y}
	drainOutboundPackets(out)
	model = updateQueueTestModel(model, wheel)
	if model.queueScroll.first != start+1 || !model.transcript.pinned || len(drainOutboundPackets(out)) != 0 {
		t.Fatal("queue wheel wasn't independent and local")
	}
	model = commitQueueTestModel(t, model, queue)
	if model.queueScroll.first != start+1 {
		t.Fatal("the same selection snapped back after a new commit")
	}
	queue.SelectedID = 4
	model = commitQueueTestModel(t, model, queue)
	if !strings.Contains(renderedBody(model), "Waiting 04") {
		t.Fatal("newly selected row was not revealed")
	}
}

func TestAgentQueueKeysGoToBEAMAndDoNotScrollTranscript(t *testing.T) {
	model := residentModel(t, 40)
	out := make(chan []byte, 64)
	model.out = out
	chat, _ := model.agentChat()
	chat.DraftAttachmentOffer = 31
	queue := queueTestFixture()
	queue.Focused, queue.SelectedID = 1, queue.Pending[1].ID
	model = commitQueueTestModel(t, model, queue, focusOwnerCommand(0, 15), protocol.Command{Kind: protocol.CommandChrome,
		Chrome: protocol.ChromePayload{Opcode: generated.OPGuiAgentChat, AgentChat: chat}})
	drainOutboundPackets(out)
	for _, key := range []tea.Key{{Code: 'j', Text: "j"}, {Code: 'k', Text: "k"}, {Code: tea.KeyUp}, {Code: tea.KeyDown},
		{Code: 'd', Text: "d"}, {Code: 'd', Text: "d"}, {Code: 'p', Text: "p"}, {Code: 'P', Text: "P"}, {Code: tea.KeyEnter}, {Code: 'q', Text: "q"}} {
		model = updateQueueTestModel(model, tea.KeyPressMsg(key))
		packets := drainOutboundPackets(out)
		if len(packets) != 1 || len(packets[0]) != 10 || packets[0][0] != generated.OPKeyPress {
			t.Fatalf("%v didn't send only an ordinary key_press: %x", key, packets)
		}
		if !model.transcript.pinned || model.transcript.anchor != (transcriptAnchor{}) {
			t.Fatalf("%v changed the resident transcript scroll", key)
		}
	}
}

func TestAgentQueueStoryboardPartsMatchPaintedRows(t *testing.T) {
	model := residentModel(t, 12)
	queue := queueTestFixture()
	queue.Hints = []generated.AgentQueueHint{{Action: 5, Key: "q", Label: "close"}}
	model = commitQueueTestModel(t, model, queue)
	view := model.View()
	buffer := uv.NewScreenBuffer(model.width, model.height)
	buffer.Method = ansi.GraphemeWidth
	uv.NewStyledString(view.Content).Draw(buffer, buffer.Bounds())
	parts := storyboardParts(model, newCellGrid(buffer, model.width, model.height))
	for _, name := range []string{"queue.title", "queue.summary", "queue.hintKey", "queue.hintLabel", "queue.rowLabel", "queue.rowPreview", "queue.removedNote"} {
		found := false
		for _, part := range parts {
			found = found || part.Part == name && !part.Missing && part.Frame[2] > 0
		}
		if !found {
			t.Errorf("did not find %s in %+v", name, parts)
		}
	}
}
