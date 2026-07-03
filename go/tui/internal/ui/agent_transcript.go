package ui

import "github.com/jsmestad/minga/go/tui/internal/protocol"

// residentTranscript is the Go TUI's resident agent-chat transcript store
// (#2654). It folds gui_agent_transcript (0x86) frames so the whole session can
// be scrolled from local data without a BEAM round-trip: a full_replace swaps
// the entire slice at a new epoch; an append keeps the strict-equal prefix and
// replaces the suffix (new messages plus the in-place patch of the streaming
// last message).
//
// It is a pointer on Model so it survives the value-copied Update loop, and it
// owns the local scroll offset + pin flag so j/k/wheel repaint same-frame
// without waiting for the BEAM. While pinned the view follows the bottom; while
// unpinned it holds a top-anchored line offset so a streaming append at the
// bottom never disturbs the reading position.
type residentTranscript struct {
	epoch    uint32
	hasEpoch bool
	messages []protocol.AgentChatMessage
	// truncated mirrors the frame flag: older messages sit outside the resident
	// window (cap eviction), so the top of the local scroll is not the true start
	// of the conversation.
	truncated bool

	// pinned true = follow the bottom (default). Unpinned holds topOffset.
	pinned bool
	// topOffset is the rendered line at the top of the viewport, counted from the
	// top of the full transcript. Only meaningful while unpinned. Top-anchored so
	// bottom appends leave it (and the reading position) untouched.
	topOffset int
	// pendingScroll accumulates unresolved scroll rows for this frame (+down /
	// -up). It is resolved during render, where the full transcript height (and
	// thus the clamp bounds) is known.
	pendingScroll int
	// pinTransition records a pin edge produced by the last resolve so Update can
	// report it to the BEAM (pinNone once reported).
	pinTransition int
}

const (
	pinNone = iota
	pinScrolledAway
	pinReturned
)

func newResidentTranscript() *residentTranscript {
	return &residentTranscript{pinned: true}
}

// apply folds one decoded gui_agent_transcript frame into the store, following
// the docs/GUI_PROTOCOL.md 0x86 apply rules.
func (t *residentTranscript) apply(frame protocol.AgentTranscript) {
	if !frame.Present {
		return
	}
	t.truncated = frame.Truncated

	if frame.FullReplace() {
		epochChanged := !t.hasEpoch || frame.Epoch != t.epoch
		next := make([]protocol.AgentChatMessage, len(frame.Messages))
		copy(next, frame.Messages)
		t.messages = next
		t.epoch = frame.Epoch
		t.hasEpoch = true
		// A new epoch is a session switch / structural reset: re-pin to the bottom
		// so the fresh transcript shows its newest content. A same-epoch
		// full_replace (compaction, resident-cap drop from the front) keeps the pin
		// state; the render clamps any now-out-of-range offset.
		if epochChanged {
			t.pinned = true
			t.topOffset = 0
		}
		return
	}

	// append: an epoch mismatch means we missed the epoch's full_replace; drop the
	// delta and await the next full_replace.
	if t.hasEpoch && frame.Epoch != t.epoch {
		return
	}
	trim := int(frame.TrimFront)
	base := int(frame.BaseCount)
	// Desync when the store cannot cover the delta's front assumptions: it holds
	// fewer than trim_front + base_count messages. Drop and await full_replace.
	if len(t.messages) < trim+base {
		return
	}

	// Apply order (GUI_PROTOCOL.md 0x86): drop trim_front from the front; keep the
	// first base_count of the remainder unchanged; upsert each frame message by id
	// (new id appends, matching id patches the streaming last message in place).
	kept := t.messages[trim : trim+base]
	next := make([]protocol.AgentChatMessage, len(kept), base+len(frame.Messages))
	copy(next, kept)
	for _, msg := range frame.Messages {
		if idx := indexByID(next, msg.ID); idx >= 0 {
			next[idx] = msg
		} else {
			next = append(next, msg)
		}
	}
	t.messages = next
	if frame.Epoch != 0 {
		t.epoch = frame.Epoch
		t.hasEpoch = true
	}
}

// indexByID returns the position of the message with id, or -1. A message id of 0
// is the "no stable identity" sentinel (bare bodies encode with id 0), so those
// never match and always append.
func indexByID(messages []protocol.AgentChatMessage, id uint32) int {
	if id == 0 {
		return -1
	}
	for i := range messages {
		if messages[i].ID == id {
			return i
		}
	}
	return -1
}

// scrollBy queues a scroll intent of `rows` lines (+down / -up). It is applied
// and clamped at render time via resolveScroll.
func (t *residentTranscript) scrollBy(rows int) {
	t.pendingScroll += rows
}

// resolveScroll applies the queued scroll against a transcript whose full
// rendered height allows a maximum top-anchored offset of maxTop, then clamps
// and updates the pin flag. It records any pin edge in pinTransition and returns
// it. maxTop is max(totalLines-budget, 0).
func (t *residentTranscript) resolveScroll(maxTop int) int {
	transition := pinNone
	rows := t.pendingScroll
	t.pendingScroll = 0

	if rows != 0 {
		if t.pinned {
			// A downward scroll while pinned is already at the bottom: ignore it.
			// An upward scroll leaves the bottom: baseline at maxTop, then move up.
			if rows < 0 {
				t.pinned = false
				t.topOffset = clampInt(maxTop+rows, 0, maxTop)
				transition = pinScrolledAway
			}
		} else {
			t.topOffset = clampInt(t.topOffset+rows, 0, maxTop)
			if t.topOffset >= maxTop {
				t.pinned = true
				transition = pinReturned
			}
		}
	}

	// Content may have changed height since the last frame; keep an unpinned
	// offset in range. If the whole transcript now fits (maxTop == 0), there is
	// nothing to scroll, so fall back to pinned without reporting a user return.
	if !t.pinned {
		if maxTop == 0 {
			t.pinned = true
			t.topOffset = 0
		} else {
			t.topOffset = clampInt(t.topOffset, 0, maxTop)
		}
	}

	if transition != pinNone {
		t.pinTransition = transition
	}
	return transition
}

// takePinTransition returns and clears the pending pin transition so Update
// reports it to the BEAM exactly once.
func (t *residentTranscript) takePinTransition() int {
	transition := t.pinTransition
	t.pinTransition = pinNone
	return transition
}

// windowTopAnchored returns the visible slice of `lines` for a top-anchored
// viewport of height `budget` whose first visible line is `topOffset`.
func windowTopAnchored(lines []string, budget, topOffset int) []string {
	if budget <= 0 || len(lines) == 0 {
		return nil
	}
	maxTop := max(len(lines)-budget, 0)
	top := clampInt(topOffset, 0, maxTop)
	end := min(top+budget, len(lines))
	return lines[top:end]
}

// windowBottom returns the last `budget` lines (the follow-bottom view).
func windowBottom(lines []string, budget int) []string {
	if budget <= 0 || len(lines) == 0 {
		return nil
	}
	if len(lines) <= budget {
		return lines
	}
	return lines[len(lines)-budget:]
}
