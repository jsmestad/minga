package ui

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"reflect"
	"strconv"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

type conformanceCommitted struct {
	Generation uint32 `json:"generation"`
	FrameSeq   uint32 `json:"frame_seq"`
}

type conformanceTransaction struct {
	Kind                string `json:"kind"`
	Generation          uint32 `json:"generation"`
	FrameSeq            uint32 `json:"frame_seq"`
	LastAppliedFrameSeq uint32 `json:"last_applied_frame_seq"`
	Reason              byte   `json:"reason"`
	Disposition         byte   `json:"disposition"`
	WindowID            uint16 `json:"window_id"`
}

type conformanceSideChannels struct {
	Title            *string `json:"title"`
	WindowBackground *uint32 `json:"window_background"`
}

type conformanceRect struct {
	Row    uint16 `json:"row"`
	Col    uint16 `json:"col"`
	Width  uint16 `json:"width"`
	Height uint16 `json:"height"`
}

type conformancePane struct {
	WindowID uint16          `json:"window_id"`
	Total    conformanceRect `json:"total_rect"`
	Content  conformanceRect `json:"content_rect"`
	Text     conformanceRect `json:"text_rect"`
	Gutter   conformanceRect `json:"gutter_rect"`
}

func decodeRecoveryCommands(t *testing.T, encoded string) []protocol.Command {
	t.Helper()
	payload, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	var commands []protocol.Command
	for len(payload) > 0 {
		command, err := protocol.DecodeCommand(payload)
		if err != nil {
			t.Fatal(err)
		}
		if command.Size <= 0 || command.Size > len(payload) {
			t.Fatal("invalid command boundary")
		}
		commands = append(commands, command)
		payload = payload[command.Size:]
	}
	return commands
}

func applyRecoveryFrame(t *testing.T, model *Model, out chan []byte, i int, step conformanceStep, wheel *conformanceStep) []byte {
	t.Helper()
	drainOutboundPackets(out)
	commands := decodeRecoveryCommands(t, step.PayloadBase64)
	if len(commands) < 2 || commands[0].Kind != protocol.CommandBeginFrame || commands[len(commands)-1].Kind != protocol.CommandCommitFrame {
		t.Fatalf("step %d: framed step lacks transaction envelope", i)
	}
	begin, commit := commands[0], commands[len(commands)-1]
	if commit.FrameSeq != begin.FrameSeq {
		t.Fatalf("step %d: mismatched commit", i)
	}
	_, offsetBefore := model.localPresentation.scrolls[1]
	if wheel == nil {
		applyProductionFrame(model, begin.FrameSeq, begin.BaseFrameSeq, begin.Generation, commands[1:len(commands)-1]...)
	} else {
		model.applyCommands(commands[:len(commands)-1])
		applyRecoveryWheel(t, model, i, *wheel)
		_, offsetBefore = model.localPresentation.scrolls[1]
		model.applyCommands(commands[len(commands)-1:])
	}
	for _, encoded := range step.AfterCommands {
		model.applyCommands(decodeRecoveryCommands(t, encoded))
	}
	var status []byte
	for _, packet := range drainOutboundPackets(out) {
		if len(packet) > 0 && (packet[0] == generated.OPFrameApplied || packet[0] == generated.OPFrameRejected || packet[0] == generated.OPWindowRefMiss) {
			if status != nil {
				t.Fatalf("step %d: more than one transaction result", i)
			}
			status = packet
		}
	}
	if step.Expect == nil {
		t.Fatalf("step %d: missing framed expectations", i)
	}
	if want := step.Expect.BaseFrameSeq; want != nil && begin.BaseFrameSeq != *want {
		t.Fatalf("step %d: base_frame_seq = %d, want %d", i, begin.BaseFrameSeq, *want)
	}
	if effects := step.Expect.OutOfBand; effects != nil {
		if effects.Title != nil && model.title != *effects.Title {
			t.Fatalf("step %d: title = %q, want %q", i, model.title, *effects.Title)
		}
		if effects.WindowBackground != nil && model.bg != *effects.WindowBackground {
			t.Fatalf("step %d: window background = %x, want %x", i, model.bg, *effects.WindowBackground)
		}
	}
	got := transactionFromPacket(t, status)
	want := conformanceTransaction{Kind: "applied", Generation: begin.Generation, FrameSeq: begin.FrameSeq}
	if step.Expect.TransactionResult != nil {
		want = *step.Expect.TransactionResult
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("step %d: transaction_result = %+v, want %+v", i, got, want)
	}
	if last := step.Expect.LastCommitted; last != nil {
		if model.lastCommittedGeneration != last.Generation || model.lastCommittedSeq != last.FrameSeq {
			t.Fatalf("step %d: committed = {%d,%d}, want %+v", i, model.lastCommittedGeneration, model.lastCommittedSeq, last)
		}
	}
	if want := step.Expect.ResidentRows; want != nil {
		count := len(model.windows[1].Rows)
		if store, ok := model.residentRows[1]; ok {
			count = store.count()
		}
		if count != *want {
			t.Fatalf("step %d: resident_rows = %d, want %d", i, count, *want)
		}
	}
	for _, want := range step.Expect.PaneRects {
		geometry := model.windows[want.WindowID].Geometry
		got := conformancePane{WindowID: geometry.WindowID, Total: corpusRect(geometry.TotalRect), Content: corpusRect(geometry.ContentRect), Text: corpusRect(geometry.TextRect), Gutter: corpusRect(geometry.GutterRect)}
		if got != want {
			t.Fatalf("step %d: pane_rects = %+v, want %+v", i, got, want)
		}
	}
	for key, want := range step.Expect.WindowRows {
		id, err := strconv.ParseUint(key, 10, 16)
		if err != nil {
			t.Fatal(err)
		}
		window, ok := model.windows[uint16(id)]
		if !ok {
			t.Fatalf("step %d: missing window %d", i, id)
		}
		assertConformanceRows(t, i, step, window.Rows, want)
	}
	for key, epoch := range step.Expect.ContentEpochs {
		id, err := strconv.ParseUint(key, 10, 16)
		if err != nil {
			t.Fatal(err)
		}
		if got := model.windows[uint16(id)].ContentEpoch; got != epoch {
			t.Fatalf("step %d: pane %d content epoch = %d, want %d", i, id, got, epoch)
		}
	}
	assertConformanceFrame(t, model, i, step, 1, offsetBefore)
	return status
}

func corpusRect(rect protocol.Rect) conformanceRect {
	return conformanceRect{Row: rect.Row, Col: rect.Col, Width: rect.Width, Height: rect.Height}
}

func transactionFromPacket(t *testing.T, packet []byte) conformanceTransaction {
	t.Helper()
	if len(packet) < 9 {
		t.Fatal("missing transaction status packet")
	}
	result := conformanceTransaction{Generation: binary.BigEndian.Uint32(packet[1:5]), FrameSeq: binary.BigEndian.Uint32(packet[5:9])}
	switch packet[0] {
	case generated.OPFrameApplied:
		result.Kind = "applied"
	case generated.OPFrameRejected:
		if len(packet) != 15 {
			t.Fatal("malformed rejection")
		}
		result.Kind = "rejected"
		result.LastAppliedFrameSeq = binary.BigEndian.Uint32(packet[9:13])
		result.Reason, result.Disposition = packet[13], packet[14]
	case generated.OPWindowRefMiss:
		if len(packet) != 15 {
			t.Fatal("malformed window miss")
		}
		result.Kind = "window_ref_miss"
		result.LastAppliedFrameSeq = binary.BigEndian.Uint32(packet[9:13])
		result.WindowID = binary.BigEndian.Uint16(packet[13:15])
	default:
		t.Fatalf("unexpected status packet %v", packet)
	}
	return result
}

func assertRecoveryStatus(t *testing.T, i int, step conformanceStep, actual []byte) {
	t.Helper()
	var expected []byte
	switch step.Event {
	case "frame_applied", "ack_timeout":
		expected = protocol.EncodeFrameApplied(step.Generation, step.FrameSeq)
	case "frame_rejected":
		expected = protocol.EncodeFrameRejected(step.Generation, step.FrameSeq, step.LastAppliedFrameSeq, step.Reason, protocol.RejectionDisposition(step.Disposition))
	case "window_reference_miss":
		expected = protocol.EncodeWindowRefMiss(step.Generation, step.FrameSeq, step.LastAppliedFrameSeq, step.WindowID)
	default:
		t.Fatalf("step %d: unknown frame_status event %q", i, step.Event)
	}
	if !bytes.Equal(actual, expected) {
		t.Fatalf("step %d: outbound status %v, want %v", i, actual, expected)
	}
}

func applyRecoveryWheel(t *testing.T, model *Model, i int, step conformanceStep) {
	t.Helper()
	window, ok := model.windows[step.WindowID]
	if !ok {
		t.Fatalf("step %d: wheel target absent", i)
	}
	button := tea.MouseWheelDown
	if step.Delta < 0 {
		button = tea.MouseWheelUp
	}
	// Use the same production wheel packet and presentation transform seam as
	// the input corpus, with a cell-unit local offset (there are no TUI pixels).
	_, ok = model.mousePacket(tea.MouseWheelMsg(tea.Mouse{X: int(window.Geometry.TextRect.Col), Y: model.layout.header.Height + int(window.Geometry.ContentRect.Row), Button: button}))
	if !ok {
		t.Fatalf("step %d: wheel was not encoded", i)
	}
	old := model.localPresentation.scrolls[step.WindowID]
	step.RowOffset, step.ColOffset = old.rowOffset+step.Delta, old.colOffset
	injectConformanceOffset(model, step)
}
