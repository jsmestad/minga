package ui

import (
	"fmt"
	"maps"
	"reflect"
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

	if got, want := ids(testTranscriptMessages(tr)), []uint32{1, 2}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if !tr.hasEpoch || tr.epoch != 1 {
		t.Fatalf("epoch not stored: %+v", tr)
	}
	if !tr.pinned {
		t.Fatalf("full_replace should leave the view pinned")
	}
}

func TestResidentTranscriptPreparationDoesNotMutateOwner(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b")))
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: tr.entry(0).slot, row: 1}
	tr.pendingScroll = -2
	tr.pinTransition = pinScrolledAway
	before := testTranscriptSnapshot(tr)
	plan := tr.prepare()
	if reason := plan.apply(appendFrame(1, 0, 1, msg(9, "changed"))); reason != transcriptApplied {
		t.Fatal(reason)
	}
	if !reflect.DeepEqual(tr, before) {
		t.Fatal("preparing a valid command changed the resident owner")
	}
	plan.commit()
	if tr.entry(0).message.Text != "a" || tr.entry(1).message.Text != "changed" || tr.anchor.row != 1 || tr.pendingScroll != -2 {
		t.Fatalf("commit lost prepared data or reading state: %+v", tr)
	}
}

func TestResidentTranscriptAppendUpsertsSuffix(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b")))
	tr.apply(appendFrame(1, 0, 2, msg(3, "c")))

	if got, want := ids(testTranscriptMessages(tr)), []uint32{1, 2, 3}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.entry(2).message.Text != "c" {
		t.Fatalf("appended text = %q", tr.entry(2).message.Text)
	}
}

func TestResidentTranscriptAppendPatchesStreamingTail(t *testing.T) {
	// The streaming last message re-sends from base = len-1 with new content.
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "partial")))
	tr.apply(appendFrame(1, 0, 1, msg(2, "partial complete")))

	if got, want := ids(testTranscriptMessages(tr)), []uint32{1, 2}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.entry(1).message.Text != "partial complete" {
		t.Fatalf("streaming tail not patched: %q", tr.entry(1).message.Text)
	}
}

func TestResidentTranscriptAppendEvictsFrontViaTrimFront(t *testing.T) {
	// Over-cap steady streaming: trim_front evicts older messages from the front
	// while the delta appends new ones at the back.
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b"), msg(3, "c"), msg(4, "d"), msg(5, "e")))
	// Evict m1,m2 from the front; keep m3,m4 unchanged; re-send m5 (patched).
	tr.apply(appendFrame(1, 2, 2, msg(5, "e patched")))

	if got, want := ids(testTranscriptMessages(tr)), []uint32{3, 4, 5}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.entry(2).message.Text != "e patched" {
		t.Fatalf("re-sent tail not patched: %q", tr.entry(2).message.Text)
	}
}

func TestResidentTranscriptAppendUpsertPatchesWithinKeptPrefix(t *testing.T) {
	// A matching id inside the kept prefix patches in place (literal id-keyed
	// upsert) rather than duplicating.
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a"), msg(2, "b"), msg(3, "c"), msg(4, "d")))
	// trim 1 (evict m1); keep m2,m3,m4; upsert m4 (id in kept prefix → patch).
	tr.apply(appendFrame(1, 1, 3, msg(4, "d patched")))

	if got, want := ids(testTranscriptMessages(tr)), []uint32{2, 3, 4}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.entry(2).message.Text != "d patched" {
		t.Fatalf("upsert should patch in place: %q", tr.entry(2).message.Text)
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
	tr.anchor = transcriptAnchor{slot: tr.entry(0).slot, row: 1}
	tr.pinTransition = pinScrolledAway
	tr.apply(replaceFrame(2, msg(9, "fresh")))

	if got, want := ids(testTranscriptMessages(tr)), []uint32{9}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.epoch != 2 {
		t.Fatalf("epoch = %d, want 2", tr.epoch)
	}
	if !tr.pinned || tr.anchor != (transcriptAnchor{}) {
		t.Fatalf("epoch flip (session switch) should re-pin to bottom: %+v", tr)
	}
	if tr.pinTransition != pinNone {
		t.Fatalf("epoch flip should clear the local pin latch without reporting intent: %d", tr.pinTransition)
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

	if got, want := ids(testTranscriptMessages(tr)), []uint32{1}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("desync append should be dropped, got %v", got)
	}
}

func TestResidentTranscriptAppendEpochMismatchDropped(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a")))
	if reason := tr.apply(appendFrame(2, 0, 1, msg(2, "b"))); reason != transcriptDroppedEpoch {
		t.Fatalf("expected epoch drop reason, got %q", reason)
	}

	if got, want := ids(testTranscriptMessages(tr)), []uint32{1}; fmt.Sprint(got) != fmt.Sprint(want) {
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

	if tr.len() != 0 {
		t.Fatalf("pre-seed append should not populate the store, got %d messages", tr.len())
	}
	if tr.hasEpoch {
		t.Fatalf("pre-seed append should not adopt an epoch")
	}
}

func TestResidentTranscriptAssignsDistinctSlotsForDuplicateAndZeroIDs(t *testing.T) {
	tr := newResidentTranscript()
	frame := replaceFrame(1, msg(0, "zero"), msg(0, "zero"), msg(7, "first"), msg(7, "duplicate"))
	tr.apply(frame)
	before := make([]uint64, tr.len())
	seen := map[uint64]bool{}
	for index, entry := range testTranscriptEntries(tr) {
		before[index] = entry.slot
		if seen[entry.slot] {
			t.Fatalf("slot %d reused for distinct messages", entry.slot)
		}
		seen[entry.slot] = true
	}

	tr.apply(frame)
	for index, entry := range testTranscriptEntries(tr) {
		if entry.slot != before[index] {
			t.Fatalf("unchanged duplicate/zero message %d changed slot from %d to %d", index, before[index], entry.slot)
		}
	}

	tr.apply(appendFrame(1, 0, 4, msg(7, "patched first")))
	if tr.entry(2).slot != before[2] || tr.entry(3).slot != before[3] {
		t.Fatalf("duplicate ID patch collapsed local identities: %+v", testTranscriptEntries(tr))
	}
	if tr.entry(2).message.Text != "patched first" || tr.entry(3).message.Text != "duplicate" {
		t.Fatalf("duplicate ID patch changed wrong messages: %+v", testTranscriptMessages(tr))
	}
}

func TestResidentTranscriptReplacementReservesExactDuplicateIDOccurrences(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(7, "A"), msg(7, "B"), msg(7, "C")))
	anchorSlot := tr.entry(1).slot
	cSlot := tr.entry(2).slot
	tr.pinned = false
	tr.anchor = transcriptAnchor{slot: anchorSlot, row: 1}

	tr.apply(replaceFrame(1, msg(7, "B"), msg(7, "C")))

	if tr.anchor != (transcriptAnchor{slot: anchorSlot, row: 1}) {
		t.Fatalf("duplicate compaction moved anchor from B: %+v", tr.anchor)
	}
	if tr.entry(0).slot != anchorSlot || tr.entry(1).slot != cSlot {
		t.Fatalf("duplicate compaction reassigned exact occurrences: %+v", testTranscriptEntries(tr))
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

	if tr.len() != count {
		t.Fatalf("replacement entry count = %d, want %d", tr.len(), count)
	}
	for index, entry := range testTranscriptEntries(tr) {
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
		tr.anchor = transcriptAnchor{slot: tr.entry(1).slot, row: 1}
		successor := tr.entry(2).slot
		tr.apply(replaceFrame(1, msg(1, "one"), msg(3, "three")))
		if tr.pinned || tr.anchor != (transcriptAnchor{slot: successor}) {
			t.Fatalf("missing anchor did not select retained successor: %+v", tr)
		}
	})

	t.Run("predecessor", func(t *testing.T) {
		tr := newResidentTranscript()
		tr.apply(replaceFrame(1, msg(1, "one"), msg(2, "two"), msg(3, "three")))
		tr.pinned = false
		tr.anchor = transcriptAnchor{slot: tr.entry(2).slot, row: 7}
		predecessor := tr.entry(0).slot
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
	tr.anchor = transcriptAnchor{slot: tr.entry(2).slot, row: 1}
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
	tr.anchor = transcriptAnchor{slot: tr.entry(0).slot, row: 1}
	tr.apply(replaceFrame(1))
	if !tr.pinned || tr.anchor != (transcriptAnchor{}) {
		t.Fatalf("empty transcript did not pin: %+v", tr)
	}
	if tr.takePinTransition() != pinReturned {
		t.Fatal("same-epoch empty replacement did not report its automatic return to bottom")
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

// Full snapshots are test oracles only. Production readers access owned pages
// directly and never materialize a second installed message/entry slice.
func testTranscriptMessages(tr *residentTranscript) []protocol.AgentChatMessage {
	messages := make([]protocol.AgentChatMessage, tr.len())
	for index := range messages {
		messages[index] = tr.entry(index).message
	}
	return messages
}

func testTranscriptEntries(tr *residentTranscript) []transcriptEntry {
	entries := make([]transcriptEntry, tr.len())
	for index := range entries {
		entries[index] = *tr.entry(index)
	}
	return entries
}

func testTranscriptSnapshot(tr *residentTranscript) *residentTranscript {
	copy := *tr
	copy.pages = make(map[uint64]*transcriptPage, len(tr.pages))
	for number, page := range tr.pages {
		value := *page
		copy.pages[number] = &value
	}
	copy.bySlot = maps.Clone(tr.bySlot)
	copy.byID = maps.Clone(tr.byID)
	for kind, summary := range tr.summaries {
		copy.summaries[kind].ordinals = append([]uint64(nil), summary.ordinals...)
		if summary.ordinals != nil && len(summary.ordinals) == 0 {
			copy.summaries[kind].ordinals = []uint64{}
		}
		copy.summaries[kind].positions = maps.Clone(summary.positions)
	}
	return &copy
}

func testTranscriptWithMessages(messages []protocol.AgentChatMessage) *residentTranscript {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, messages...))
	return tr
}
