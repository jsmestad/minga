package ui

import (
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestCommitEmitsAppliedOnlyAfterCompletePublication(t *testing.T) {
	out := make(chan []byte, 16)
	m := New(40, 8, out, nil)
	m = applyTo(t, m, beginFrame(1, 0), testThemeCommand(), windowRowsCommand(1, "committed"), commitFrame(1))
	packets := drainOutboundPackets(out)
	if len(packets) == 0 {
		t.Fatal("missing frame_applied")
	}
	last := packets[len(packets)-1]
	if len(last) != 9 || last[0] != generated.OPFrameApplied || binary.BigEndian.Uint32(last[1:5]) != 1 || binary.BigEndian.Uint32(last[5:9]) != 1 {
		t.Fatalf("last packet should acknowledge committed generation/frame: %v", last)
	}
	if got := renderedBody(m); got == "" {
		t.Fatal("frame must be published before applied is emitted")
	}
}

func TestRejectedTransactionEmitsOnlyTypedRejectionAndDoesNotPublish(t *testing.T) {
	out := make(chan []byte, 16)
	m := New(40, 8, out, nil)
	beforeWindows := len(m.windows)
	beforeCommitted := m.lastCommittedSeq
	m = applyTo(t, m, beginFrame(9, 4), commitFrame(9))
	packets := drainOutboundPackets(out)
	if len(packets) != 2 || packets[0][0] != generated.OPFrameRejected || packets[1][0] != generated.OPLogMessage {
		t.Fatalf("automatic recovery must emit one rejection plus diagnostics only: %v", packets)
	}
	for _, packet := range packets {
		if packet[0] == generated.OPRequestKeyframe {
			t.Fatalf("automatic rejection must not also request a keyframe: %v", packets)
		}
	}
	if len(m.windows) != beforeWindows || m.lastCommittedSeq != beforeCommitted {
		t.Fatal("rejected frame partially published semantic state")
	}
}

func TestWrongWindowEpochRejectsTransactionWithoutPartialApply(t *testing.T) {
	out := make(chan []byte, 16)
	m := New(40, 8, out, nil)
	m = applyTo(t, m, beginFrame(1, 0), testThemeCommand(), windowRowsCommand(1, "baseline"), commitFrame(1))
	drainOutboundPackets(out)

	wrongEpoch := protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{
		ID: 1, ContentEpoch: 99,
		Rows: []protocol.WindowRow{{ID: 2, ContentHash: 2, Text: "must not publish"}},
	}}
	m = applyTo(t, m, beginFrame(2, 1), wrongEpoch, commitFrame(2))
	packets := drainOutboundPackets(out)
	if len(packets) != 2 || packets[0][0] != generated.OPFrameRejected || packets[0][13] != protocol.RejectWindowEpoch {
		t.Fatalf("expected window-epoch frame rejection plus diagnostic, got %v", packets)
	}
	if got := m.windows[1].Rows[0].Text; got != "baseline" {
		t.Fatalf("wrong-epoch transaction partially published: %q", got)
	}
	if m.lastCommittedSeq != 1 {
		t.Fatalf("wrong-epoch frame advanced commit sequence to %d", m.lastCommittedSeq)
	}
}

func TestWindowReferenceMissReportsTargetWithoutPublishingSiblingState(t *testing.T) {
	out := make(chan []byte, 16)
	m := New(40, 8, out, nil)
	m = applyTo(t, m, beginFrame(1, 0), testThemeCommand(), windowRowsCommand(1, "baseline"), commitFrame(1))
	drainOutboundPackets(out)

	missing := protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{
		ID: 2, ContentEpoch: 1,
		Rows: []protocol.WindowRow{{Ref: true, ID: 999, ContentHash: 999}},
	}}
	m = applyTo(t, m, beginFrame(2, 1), missing, commitFrame(2))
	packets := drainOutboundPackets(out)
	if len(packets) != 1 || len(packets[0]) != 15 || packets[0][0] != generated.OPWindowRefMiss {
		t.Fatalf("expected one targeted window_ref_miss, got %v", packets)
	}
	if got := binary.BigEndian.Uint16(packets[0][13:15]); got != 2 {
		t.Fatalf("window id = %d, want 2", got)
	}
	if _, ok := m.windows[2]; ok {
		t.Fatal("missing-window delta must not publish")
	}
	if m.resyncPending {
		t.Fatal("targeted ref recovery must not enter global base-zero resync")
	}
	if got := m.windows[1].Rows[0].Text; got != "baseline" {
		t.Fatalf("sibling window changed: %q", got)
	}
}
