package protocol

import (
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestFrameStatusWireLayouts(t *testing.T) {
	applied := EncodeFrameApplied(3, 9)
	if len(applied) != 9 || applied[0] != generated.OPFrameApplied || binary.BigEndian.Uint32(applied[1:5]) != 3 || binary.BigEndian.Uint32(applied[5:9]) != 9 {
		t.Fatalf("bad frame_applied layout: %v", applied)
	}
	rejected := EncodeFrameRejected(3, 9, 7, RejectBaseSequence, DispositionRetryable)
	if len(rejected) != 15 || rejected[0] != generated.OPFrameRejected || binary.BigEndian.Uint32(rejected[9:13]) != 7 || rejected[13] != RejectBaseSequence || rejected[14] != byte(DispositionRetryable) {
		t.Fatalf("bad frame_rejected layout: %v", rejected)
	}
	terminal := EncodeFrameRejected(4, 10, 9, RejectResourcePolicy, DispositionTerminal)
	if terminal[13] != byte(generated.FrameRejectionReasonResourcePolicy) || terminal[14] != byte(generated.FrameRejectionDispositionTerminalFrontendFailure) {
		t.Fatalf("bad terminal resource rejection layout: %v", terminal)
	}
	miss := EncodeWindowRefMiss(3, 9, 7, 12)
	if len(miss) != 15 || miss[0] != generated.OPWindowRefMiss || binary.BigEndian.Uint16(miss[13:15]) != 12 {
		t.Fatalf("bad window_ref_miss layout: %v", miss)
	}
}
