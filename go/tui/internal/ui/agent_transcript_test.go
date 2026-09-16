package ui

import (
	"fmt"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func msg(id uint32, text string) protocol.AgentChatMessage {
	return protocol.AgentChatMessage{ID: id, Kind: 0x01, Text: text}
}

func replaceFrame(epoch uint32, msgs ...protocol.AgentChatMessage) protocol.AgentTranscript {
	return protocol.AgentTranscript{Present: true, Mode: 0, Epoch: epoch, Messages: msgs}
}

func appendFrame(epoch, trim, base uint32, msgs ...protocol.AgentChatMessage) protocol.AgentTranscript {
	return protocol.AgentTranscript{
		Present:   true,
		Mode:      1,
		Epoch:     epoch,
		TrimFront: trim,
		BaseCount: base,
		Messages:  msgs,
	}
}

func ids(msgs []protocol.AgentChatMessage) []uint32 {
	out := make([]uint32, len(msgs))
	for i, m := range msgs {
		out[i] = m.ID
	}
	return out
}

func TestResidentTranscriptFullReplace(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b")))

	if got, want := ids(tr.messages), []uint32{1, 2}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if !tr.hasEpoch || tr.epoch != 1 {
		t.Fatalf("epoch not stored: %+v", tr)
	}
	if !tr.pinned {
		t.Fatalf("full_replace should leave the view pinned")
	}
}

func TestResidentTranscriptDetachedCandidateDoesNotShareMutableSlice(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b")))
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: tr.entries[0].slot, row: 1}
	tr.pendingScroll = -2
	tr.pinTransition = pinScrolledAway

	candidate := tr.detachedCandidate()
	candidate.messages[0] = msg(9, "changed")
	candidate.anchor.row = 0

	if tr.messages[0].ID != 1 || tr.messages[0].Text != "a" {
		t.Fatalf("candidate mutated live messages: %+v", tr.messages)
	}
	if tr.anchor.row != 1 {
		t.Fatalf("candidate mutated live anchor: %+v", tr.anchor)
	}
	if candidate.epoch != tr.epoch || candidate.pinned != tr.pinned || candidate.pendingScroll != tr.pendingScroll || candidate.pinTransition != tr.pinTransition {
		t.Fatalf("candidate did not preserve transcript-owned state: live=%+v candidate=%+v", tr, candidate)
	}
}

func TestResidentTranscriptAppendUpsertsSuffix(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b")))
	tr.apply(appendFrame(1, 0, 2, msg(3, "c")))

	if got, want := ids(tr.messages), []uint32{1, 2, 3}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.messages[2].Text != "c" {
		t.Fatalf("appended text = %q", tr.messages[2].Text)
	}
}

func TestResidentTranscriptAppendPatchesStreamingTail(t *testing.T) {
	// The streaming last message re-sends from base = len-1 with new content.
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "partial")))
	tr.apply(appendFrame(1, 0, 1, msg(2, "partial complete")))

	if got, want := ids(tr.messages), []uint32{1, 2}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.messages[1].Text != "partial complete" {
		t.Fatalf("streaming tail not patched: %q", tr.messages[1].Text)
	}
}

func TestResidentTranscriptAppendEvictsFrontViaTrimFront(t *testing.T) {
	// Over-cap steady streaming: trim_front evicts older messages from the front
	// while the delta appends new ones at the back.
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b"), msg(3, "c"), msg(4, "d"), msg(5, "e")))
	// Evict m1,m2 from the front; keep m3,m4 unchanged; re-send m5 (patched).
	tr.apply(appendFrame(1, 2, 2, msg(5, "e patched")))

	if got, want := ids(tr.messages), []uint32{3, 4, 5}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.messages[2].Text != "e patched" {
		t.Fatalf("re-sent tail not patched: %q", tr.messages[2].Text)
	}
}

func TestResidentTranscriptAppendUpsertPatchesWithinKeptPrefix(t *testing.T) {
	// A matching id inside the kept prefix patches in place (literal id-keyed
	// upsert) rather than duplicating.
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b"), msg(3, "c"), msg(4, "d")))
	// trim 1 (evict m1); keep m2,m3,m4; upsert m4 (id in kept prefix → patch).
	tr.apply(appendFrame(1, 1, 3, msg(4, "d patched")))

	if got, want := ids(tr.messages), []uint32{2, 3, 4}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.messages[2].Text != "d patched" {
		t.Fatalf("upsert should patch in place: %q", tr.messages[2].Text)
	}
}

func TestResidentTranscriptTracksTruncatedFlag(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 1, Truncated: true, Messages: []protocol.AgentChatMessage{msg(1, "a")}})
	if !tr.truncated {
		t.Fatalf("truncated flag should be tracked from the frame")
	}
}

func TestResidentTranscriptEpochFlipReplaces(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b")))
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: tr.entries[0].slot, row: 1}
	tr.apply(replaceFrame(2, msg(9, "fresh")))

	if got, want := ids(tr.messages), []uint32{9}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.epoch != 2 {
		t.Fatalf("epoch = %d, want 2", tr.epoch)
	}
	if !tr.pinned || tr.anchor != (transcriptAnchor{}) {
		t.Fatalf("epoch flip (session switch) should re-pin to bottom: %+v", tr)
	}
}

func TestResidentTranscriptAppendDesyncDropped(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a")))
	// resident_count (1) < trim_front + base_count (1 + 1): the delta cannot apply
	// against what the store holds, so drop it and await full_replace.
	if reason := tr.apply(appendFrame(1, 1, 1, msg(6, "orphan"))); reason != transcriptDroppedDesync {
		t.Fatalf("expected desync drop reason, got %q", reason)
	}

	if got, want := ids(tr.messages), []uint32{1}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("desync append should be dropped, got %v", got)
	}
}

func TestResidentTranscriptAppendEpochMismatchDropped(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a")))
	if reason := tr.apply(appendFrame(2, 0, 1, msg(2, "b"))); reason != transcriptDroppedEpoch {
		t.Fatalf("expected epoch drop reason, got %q", reason)
	}

	if got, want := ids(tr.messages), []uint32{1}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("epoch-mismatch append should be dropped, got %v", got)
	}
}

func TestResidentTranscriptAppendBeforeSeedDropped(t *testing.T) {
	// An append arriving before any full_replace means the epoch's seed frame was
	// missed. Folding it against the empty store (even with trim=base=0) would
	// fabricate a partial transcript; the Swift consumer drops this case too, and
	// the two frontends must agree.
	tr := newResidentTranscript()
	if reason := tr.apply(appendFrame(1, 0, 0, msg(1, "early"))); reason != transcriptDroppedBeforeSeed {
		t.Fatalf("expected before-seed drop reason, got %q", reason)
	}

	if len(tr.messages) != 0 {
		t.Fatalf("pre-seed append should not populate the store, got %d messages", len(tr.messages))
	}
	if tr.hasEpoch {
		t.Fatalf("pre-seed append should not adopt an epoch")
	}
}

func TestResidentTranscriptAssignsDistinctSlotsForDuplicateAndZeroIDs(t *testing.T) {
	tr := newResidentTranscript()
	frame := replaceFrame(1, msg(0, "zero"), msg(0, "zero"), msg(7, "first"), msg(7, "duplicate"))
	tr.apply(frame)
	before := make([]uint64, len(tr.entries))
	seen := map[uint64]bool{}
	for index, entry := range tr.entries {
		before[index] = entry.slot
		if seen[entry.slot] {
			t.Fatalf("slot %d reused for distinct messages", entry.slot)
		}
		seen[entry.slot] = true
	}

	tr.apply(frame)
	for index, entry := range tr.entries {
		if entry.slot != before[index] {
			t.Fatalf("unchanged duplicate/zero message %d changed slot from %d to %d", index, before[index], entry.slot)
		}
	}

	tr.apply(appendFrame(1, 0, 4, msg(7, "patched first")))
	if tr.entries[2].slot != before[2] || tr.entries[3].slot != before[3] {
		t.Fatalf("duplicate ID patch collapsed local identities: %+v", tr.entries)
	}
	if tr.messages[2].Text != "patched first" || tr.messages[3].Text != "duplicate" {
		t.Fatalf("duplicate ID patch changed wrong messages: %+v", tr.messages)
	}
}

func TestResidentTranscriptReplacementReservesExactDuplicateIDOccurrences(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(7, "A"), msg(7, "B"), msg(7, "C")))
	anchorSlot := tr.entries[1].slot
	cSlot := tr.entries[2].slot
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: anchorSlot, row: 1}

	tr.apply(replaceFrame(1, msg(7, "B"), msg(7, "C")))

	if tr.anchor != (transcriptAnchor{slot: anchorSlot, row: 1}) {
		t.Fatalf("duplicate compaction moved anchor from B: %+v", tr.anchor)
	}
	if tr.entries[0].slot != anchorSlot || tr.entries[1].slot != cSlot {
		t.Fatalf("duplicate compaction reassigned exact occurrences: %+v", tr.entries)
	}
}

func TestResidentTranscriptLargeZeroIDReplacementUsesLinearExactIndex(t *testing.T) {
	const count = 10_000
	tr := newResidentTranscript()
	original := make([]protocol.AgentChatMessage, count)
	for index := range original {
		original[index] = msg(0, fmt.Sprintf("original-%05d", index))
	}
	tr.apply(replaceFrame(1, original...))
	lastOriginalSlot := tr.nextSlot

	replacement := make([]protocol.AgentChatMessage, count)
	for index := range replacement {
		replacement[index] = msg(0, fmt.Sprintf("replacement-%05d", count-index))
	}
	tr.apply(replaceFrame(1, replacement...))

	if len(tr.entries) != count {
		t.Fatalf("replacement entry count = %d, want %d", len(tr.entries), count)
	}
	for index, entry := range tr.entries {
		if entry.slot <= lastOriginalSlot {
			t.Fatalf("unmatched zero-ID entry %d reused old slot %d", index, entry.slot)
		}
	}
}

func TestResidentTranscriptReconcilesMissingAnchorToSuccessorThenPredecessor(t *testing.T) {
	t.Run("successor", func(t *testing.T) {
		tr := newResidentTranscript()
		tr.apply(replaceFrame(1, msg(1, "one"), msg(2, "two"), msg(3, "three")))
		tr.pinned = false
		tr.anchor = transcriptAnchor{slot: tr.entries[1].slot, row: 1}
		successor := tr.entries[2].slot
		tr.apply(replaceFrame(1, msg(1, "one"), msg(3, "three")))
		if tr.pinned || tr.anchor != (transcriptAnchor{slot: successor}) {
			t.Fatalf("missing anchor did not select retained successor: %+v", tr)
		}
	})

	t.Run("predecessor", func(t *testing.T) {
		tr := newResidentTranscript()
		tr.apply(replaceFrame(1, msg(1, "one"), msg(2, "two"), msg(3, "three")))
		tr.pinned = false
		tr.anchor = transcriptAnchor{slot: tr.entries[2].slot, row: 7}
		predecessor := tr.entries[0].slot
		tr.apply(replaceFrame(1, msg(1, "one")))
		if tr.pinned || tr.anchor.slot != predecessor || tr.anchor.row != 7 {
			t.Fatalf("missing anchor did not select retained predecessor and preserve row for later clamp: %+v", tr)
		}
	})
}

func TestResidentTranscriptTrimAndSuffixReplacementPreserveAnchor(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "one"), msg(2, "two"), msg(3, "three"), msg(4, "four")))
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: tr.entries[2].slot, row: 1}
	anchor := tr.anchor

	tr.apply(appendFrame(1, 1, 2, msg(4, "four streaming"), msg(5, "five")))
	if tr.anchor != anchor || tr.pinned {
		t.Fatalf("trim/suffix replacement moved retained anchor: before=%+v after=%+v", anchor, tr.anchor)
	}
}

func TestResidentTranscriptEmptyReplacementPins(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "one")))
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: tr.entries[0].slot, row: 1}
	tr.apply(replaceFrame(1))
	if !tr.pinned || tr.anchor != (transcriptAnchor{}) {
		t.Fatalf("empty transcript did not pin: %+v", tr)
	}
}

func lineSeq(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("L%d", i)
	}
	return out
}

func TestWindowTopAnchored(t *testing.T) {
	lines := lineSeq(20)

	got := windowTopAnchored(lines, 5, 12)
	if fmt.Sprint(got) != fmt.Sprint([]string{"L12", "L13", "L14", "L15", "L16"}) {
		t.Fatalf("window = %v", got)
	}

	// Offset past the max clamps so the last budget lines show.
	clamped := windowTopAnchored(lines, 5, 999)
	if fmt.Sprint(clamped) != fmt.Sprint([]string{"L15", "L16", "L17", "L18", "L19"}) {
		t.Fatalf("clamped window = %v", clamped)
	}
}

func TestWindowBottom(t *testing.T) {
	lines := lineSeq(20)
	got := windowBottom(lines, 5)
	if fmt.Sprint(got) != fmt.Sprint([]string{"L15", "L16", "L17", "L18", "L19"}) {
		t.Fatalf("bottom window = %v", got)
	}
	if all := windowBottom(lineSeq(3), 5); len(all) != 3 {
		t.Fatalf("short transcript should return all lines, got %v", all)
	}
}
