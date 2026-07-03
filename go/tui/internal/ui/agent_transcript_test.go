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
	tr.topOffset = 3
	tr.apply(replaceFrame(2, msg(9, "fresh")))

	if got, want := ids(tr.messages), []uint32{9}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("ids = %v, want %v", got, want)
	}
	if tr.epoch != 2 {
		t.Fatalf("epoch = %d, want 2", tr.epoch)
	}
	if !tr.pinned || tr.topOffset != 0 {
		t.Fatalf("epoch flip (session switch) should re-pin to bottom: %+v", tr)
	}
}

func TestResidentTranscriptAppendDesyncDropped(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a")))
	// resident_count (1) < trim_front + base_count (1 + 1): the delta cannot apply
	// against what the store holds, so drop it and await full_replace.
	tr.apply(appendFrame(1, 1, 1, msg(6, "orphan")))

	if got, want := ids(tr.messages), []uint32{1}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("desync append should be dropped, got %v", got)
	}
}

func TestResidentTranscriptAppendEpochMismatchDropped(t *testing.T) {
	tr := newResidentTranscript()
	tr.apply(replaceFrame(1, msg(1, "a")))
	tr.apply(appendFrame(2, 0, 1, msg(2, "b")))

	if got, want := ids(tr.messages), []uint32{1}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("epoch-mismatch append should be dropped, got %v", got)
	}
}

func TestResolveScrollUnpinsFromBottom(t *testing.T) {
	tr := newResidentTranscript()
	tr.scrollBy(-3) // scroll up off the bottom
	transition := tr.resolveScroll(15)

	if tr.pinned {
		t.Fatalf("scrolling up should unpin")
	}
	if tr.topOffset != 12 {
		t.Fatalf("topOffset = %d, want 12 (maxTop 15 - 3)", tr.topOffset)
	}
	if transition != pinScrolledAway {
		t.Fatalf("transition = %d, want pinScrolledAway", transition)
	}
}

func TestResolveScrollDownWhilePinnedIsNoop(t *testing.T) {
	tr := newResidentTranscript()
	tr.scrollBy(4)
	transition := tr.resolveScroll(15)

	if !tr.pinned || transition != pinNone {
		t.Fatalf("scroll down while pinned should stay pinned with no transition: %+v t=%d", tr, transition)
	}
}

func TestResolveScrollReturnsToBottom(t *testing.T) {
	tr := newResidentTranscript()
	tr.pinned = false
	tr.topOffset = 12
	tr.scrollBy(5) // past the bottom
	transition := tr.resolveScroll(15)

	if !tr.pinned {
		t.Fatalf("scrolling down to the bottom should re-pin")
	}
	if transition != pinReturned {
		t.Fatalf("transition = %d, want pinReturned", transition)
	}
}

func TestResolveScrollClampsToTop(t *testing.T) {
	tr := newResidentTranscript()
	tr.pinned = false
	tr.topOffset = 2
	tr.scrollBy(-10) // way past the top
	tr.resolveScroll(15)

	if tr.topOffset != 0 {
		t.Fatalf("topOffset = %d, want 0 (clamped to top)", tr.topOffset)
	}
	if tr.pinned {
		t.Fatalf("scrolled to top should remain unpinned")
	}
}

func TestResolveScrollAppendWhileScrolledUpPreservesPosition(t *testing.T) {
	// Scroll up in a 20-line transcript (budget 5, maxTop 15), then a streaming
	// append grows it to 25 lines (maxTop 20). Because the offset is top-anchored,
	// the reading position (topOffset) must not move.
	tr := newResidentTranscript()
	tr.scrollBy(-3)
	tr.resolveScroll(15)
	if tr.topOffset != 12 {
		t.Fatalf("precondition topOffset = %d, want 12", tr.topOffset)
	}

	// Next frame after an append: no new scroll input, larger transcript.
	tr.resolveScroll(20)

	if tr.pinned {
		t.Fatalf("append while scrolled up must not re-pin")
	}
	if tr.topOffset != 12 {
		t.Fatalf("append moved the reading position: topOffset = %d, want 12", tr.topOffset)
	}
}

func TestResolveScrollContentShrinkRepinsWhenAllFits(t *testing.T) {
	tr := newResidentTranscript()
	tr.pinned = false
	tr.topOffset = 8
	// Content now fits entirely in the viewport (maxTop 0): nothing to scroll.
	tr.resolveScroll(0)

	if !tr.pinned || tr.topOffset != 0 {
		t.Fatalf("all-fits should re-pin to bottom: %+v", tr)
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
