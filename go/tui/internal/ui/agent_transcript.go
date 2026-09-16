package ui

import (
	"encoding/binary"
	"reflect"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// residentTranscript owns the semantic transcript, stable local message slots,
// and the reading anchor. Styled rows are disposable renderer state and live in
// agentTranscriptRenderer instead.
type residentTranscript struct {
	epoch uint32
	// hasEpoch is the received-a-frame flag. It stays true for a legitimate
	// empty 0x86 transcript, so callers never confuse empty resident data with
	// the pre-seed state that existed before this epoch's full replacement.
	hasEpoch  bool
	messages  []protocol.AgentChatMessage
	entries   []transcriptEntry
	bySlot    map[uint64]int
	nextSlot  uint64
	truncated bool

	pinned        bool
	anchor        transcriptAnchor
	pendingScroll int
	pinTransition pinEdge
	animatedCount int
}

type transcriptEntry struct {
	slot     uint64
	revision uint64
	message  protocol.AgentChatMessage

	// Height is presentation metadata, not styled output. It is populated only
	// when traversal encounters the message at the active width.
	height         int
	heightWidth    int
	heightRevision uint64
}

type transcriptAnchor struct {
	slot uint64
	row  int
}

type pinEdge uint8

const (
	pinNone pinEdge = iota
	pinScrolledAway
	pinReturned
)

func newResidentTranscript() *residentTranscript {
	return &residentTranscript{pinned: true, bySlot: map[uint64]int{}}
}

// detachedCandidate returns independently mutable transcript state for atomic
// frame preparation. Message bodies are immutable after decoding, so copying
// the outer semantic and entry slices is sufficient.
func (t *residentTranscript) detachedCandidate() *residentTranscript {
	if t == nil {
		return newResidentTranscript()
	}

	candidate := *t
	candidate.messages = append([]protocol.AgentChatMessage(nil), t.messages...)
	candidate.entries = append([]transcriptEntry(nil), t.entries...)
	candidate.rebuildSlotIndex()
	return &candidate
}

type transcriptDropReason string

const (
	transcriptApplied            transcriptDropReason = ""
	transcriptDroppedBeforeSeed  transcriptDropReason = "append before seed"
	transcriptDroppedEpoch       transcriptDropReason = "epoch mismatch"
	transcriptDroppedDesync      transcriptDropReason = "desynced (short store)"
	transcriptDroppedUndecodable transcriptDropReason = "undecodable frame"
)

// apply folds one decoded gui_agent_transcript frame into the semantic store.
// It preserves local slots for retained messages and reconciles the anchor
// before the candidate is published by the frame transaction.
func (t *residentTranscript) apply(frame protocol.AgentTranscript) transcriptDropReason {
	if !frame.Present {
		return transcriptDroppedUndecodable
	}

	if frame.FullReplace() {
		epochChanged := !t.hasEpoch || frame.Epoch != t.epoch
		oldEntries := t.entries
		if epochChanged {
			t.entries = make([]transcriptEntry, 0, len(frame.Messages))
			for _, message := range frame.Messages {
				t.entries = append(t.entries, t.newTranscriptEntry(message))
			}
		} else {
			t.entries = t.reconcileReplacement(frame.Messages)
		}
		t.installEntries()
		t.truncated = frame.Truncated
		t.epoch = frame.Epoch
		t.hasEpoch = true
		if epochChanged {
			// An epoch flip is an authoritative session/reset transition. Both
			// BEAM epoch sources independently reset follow-bottom, so discard a
			// stale local edge and re-pin without reporting a new intent.
			t.pinTransition = pinNone
			t.pinToBottom()
		} else {
			t.reconcileAnchor(oldEntries)
		}
		return transcriptApplied
	}

	if !t.hasEpoch {
		return transcriptDroppedBeforeSeed
	}
	if frame.Epoch != t.epoch {
		return transcriptDroppedEpoch
	}
	trim := int(frame.TrimFront)
	base := int(frame.BaseCount)
	if len(t.entries) < trim+base {
		return transcriptDroppedDesync
	}

	oldEntries := t.entries
	kept := t.entries[trim : trim+base]
	next := make([]transcriptEntry, len(kept), base+len(frame.Messages))
	copy(next, kept)
	for _, message := range frame.Messages {
		if index := indexEntryByID(next, message.ID); index >= 0 {
			next[index] = reviseTranscriptEntry(next[index], message)
		} else {
			next = append(next, t.newTranscriptEntry(message))
		}
	}
	t.entries = next
	t.installEntries()
	t.truncated = frame.Truncated
	t.reconcileAnchor(oldEntries)
	return transcriptApplied
}

func (t *residentTranscript) reconcileReplacement(messages []protocol.AgentChatMessage) []transcriptEntry {
	old := t.entries
	used := make([]bool, len(old))
	matches := make([]int, len(messages))
	for position, message := range messages {
		matches[position] = -1
		if position < len(old) && reflect.DeepEqual(old[position].message, message) {
			matches[position] = position
			used[position] = true
		}
	}

	// Reserve every unchanged occurrence before assigning same-ID revisions.
	// Without this pass, a removed duplicate can consume the slot of a later
	// exact match and silently move the reading anchor to another message.
	exact := make(map[string][]int, len(old))
	for index := range old {
		if !used[index] {
			key := transcriptMessageKey(old[index].message)
			exact[key] = append(exact[key], index)
		}
	}
	exactCursor := make(map[string]int, len(exact))
	for position, message := range messages {
		if matches[position] >= 0 {
			continue
		}
		key := transcriptMessageKey(message)
		indexes := exact[key]
		cursor := exactCursor[key]
		if cursor < len(indexes) {
			matches[position] = indexes[cursor]
			used[indexes[cursor]] = true
			exactCursor[key] = cursor + 1
		}
	}

	byID := make(map[uint32][]int, len(old))
	for index := range old {
		if id := old[index].message.ID; !used[index] && id != 0 {
			byID[id] = append(byID[id], index)
		}
	}
	idCursor := make(map[uint32]int, len(byID))
	for position, message := range messages {
		if matches[position] >= 0 || message.ID == 0 {
			continue
		}
		indexes := byID[message.ID]
		cursor := idCursor[message.ID]
		if cursor < len(indexes) {
			matches[position] = indexes[cursor]
			used[indexes[cursor]] = true
			idCursor[message.ID] = cursor + 1
		}
	}

	next := make([]transcriptEntry, 0, len(messages))
	for position, message := range messages {
		match := matches[position]
		if match < 0 {
			next = append(next, t.newTranscriptEntry(message))
			continue
		}
		next = append(next, reviseTranscriptEntry(old[match], message))
	}
	return next
}

// transcriptMessageKey is an exact, length-prefixed encoding used only while
// reconciling a same-epoch full replacement. It makes occurrence matching
// linear in the number and encoded size of messages, including ID-zero input.
func transcriptMessageKey(message protocol.AgentChatMessage) string {
	key := make([]byte, 0, len(message.Text)+len(message.Result)+len(message.Summary)+64)
	key = binary.LittleEndian.AppendUint32(key, message.ID)
	key = append(key, message.Kind)
	key = appendTranscriptString(key, message.Text)
	key = appendTranscriptString(key, message.Name)
	key = appendTranscriptString(key, message.Summary)
	key = appendTranscriptString(key, message.Result)
	key = append(key, message.Status, boolByte(message.IsError), boolByte(message.Collapsed))
	key = binary.LittleEndian.AppendUint32(key, message.DurationMS)
	key = append(key, message.AutoApprovedScope)
	key = appendTranscriptStyledLines(key, message.StyledLines)
	key = appendTranscriptMarkdownBlocks(key, message.MarkdownBlocks)
	key = binary.LittleEndian.AppendUint32(key, message.Usage.Input)
	key = binary.LittleEndian.AppendUint32(key, message.Usage.Output)
	key = binary.LittleEndian.AppendUint32(key, message.Usage.CacheRead)
	key = binary.LittleEndian.AppendUint32(key, message.Usage.CacheWrite)
	key = binary.LittleEndian.AppendUint32(key, message.Usage.CostMicros)
	key = append(key, message.PreviewKind)
	key = appendTranscriptStrings(key, message.PreviewLines)
	return string(key)
}

func appendTranscriptStyledLines(key []byte, lines []protocol.AgentStyledLine) []byte {
	key = appendTranscriptSliceHeader(key, lines == nil, len(lines))
	for _, line := range lines {
		key = appendTranscriptSliceHeader(key, line == nil, len(line))
		for _, run := range line {
			key = appendTranscriptString(key, run.Text)
			key = binary.LittleEndian.AppendUint32(key, run.FG)
			key = binary.LittleEndian.AppendUint32(key, run.BG)
			key = append(key, run.Flags)
			key = appendTranscriptString(key, run.URL)
		}
	}
	return key
}

func appendTranscriptMarkdownBlocks(key []byte, blocks []protocol.AgentMarkdownBlock) []byte {
	key = appendTranscriptSliceHeader(key, blocks == nil, len(blocks))
	for _, block := range blocks {
		key = binary.LittleEndian.AppendUint32(key, block.ID)
		key = append(key, block.Kind, block.Flags)
		key = appendTranscriptStyledLines(key, block.Lines)
		key = append(key, block.Level, block.Indent, boolByte(block.Ordered))
		key = binary.LittleEndian.AppendUint32(key, block.Ordinal)
		key = append(key, block.Height)
		key = appendTranscriptString(key, block.Language)
		key = appendTranscriptString(key, block.Label)
		key = appendTranscriptString(key, block.TargetPath)
		key = append(key, block.CapabilityFlags)
	}
	return key
}

func appendTranscriptStrings(key []byte, values []string) []byte {
	key = appendTranscriptSliceHeader(key, values == nil, len(values))
	for _, value := range values {
		key = appendTranscriptString(key, value)
	}
	return key
}

func appendTranscriptSliceHeader(key []byte, nilSlice bool, length int) []byte {
	key = append(key, boolByte(nilSlice))
	return binary.LittleEndian.AppendUint64(key, uint64(length))
}

func appendTranscriptString(key []byte, value string) []byte {
	key = binary.LittleEndian.AppendUint64(key, uint64(len(value)))
	return append(key, value...)
}

func boolByte(value bool) byte {
	if value {
		return 1
	}
	return 0
}

func (t *residentTranscript) newTranscriptEntry(message protocol.AgentChatMessage) transcriptEntry {
	t.nextSlot++
	return transcriptEntry{slot: t.nextSlot, revision: 1, message: message}
}

func reviseTranscriptEntry(entry transcriptEntry, message protocol.AgentChatMessage) transcriptEntry {
	if reflect.DeepEqual(entry.message, message) {
		return entry
	}
	entry.message = message
	entry.revision++
	entry.height = 0
	entry.heightWidth = 0
	entry.heightRevision = 0
	return entry
}

func (t *residentTranscript) installEntries() {
	t.messages = make([]protocol.AgentChatMessage, len(t.entries))
	t.animatedCount = 0
	for index := range t.entries {
		t.messages[index] = t.entries[index].message
		if agentMessageAnimated(t.entries[index].message) {
			t.animatedCount++
		}
	}
	t.rebuildSlotIndex()
}

func (t *residentTranscript) rebuildSlotIndex() {
	t.bySlot = make(map[uint64]int, len(t.entries))
	for index := range t.entries {
		t.bySlot[t.entries[index].slot] = index
	}
}

func (t *residentTranscript) reconcileAnchor(oldEntries []transcriptEntry) {
	if len(t.entries) == 0 {
		t.returnToBottom()
		return
	}
	if t.pinned || t.anchor.slot == 0 {
		return
	}
	if _, found := t.bySlot[t.anchor.slot]; found {
		return
	}

	oldIndex := -1
	for index := range oldEntries {
		if oldEntries[index].slot == t.anchor.slot {
			oldIndex = index
			break
		}
	}
	if oldIndex < 0 {
		t.pinToBottom()
		return
	}
	for index := oldIndex + 1; index < len(oldEntries); index++ {
		if _, found := t.bySlot[oldEntries[index].slot]; found {
			t.anchor = transcriptAnchor{slot: oldEntries[index].slot}
			return
		}
	}
	for index := oldIndex - 1; index >= 0; index-- {
		if _, found := t.bySlot[oldEntries[index].slot]; found {
			t.anchor.slot = oldEntries[index].slot
			return
		}
	}
	// A same-epoch replacement can revise every message at once. With no old
	// slot left to select, preserve the reader's approximate message position in
	// the replacement rather than jumping to the bottom.
	t.anchor.slot = t.entries[min(oldIndex, len(t.entries)-1)].slot
}

func (t *residentTranscript) pinToBottom() {
	t.pinned = true
	t.anchor = transcriptAnchor{}
	t.pendingScroll = 0
}

func (t *residentTranscript) returnToBottom() {
	wasPinned := t.pinned
	t.pinToBottom()
	if !wasPinned {
		t.recordPinTransition(pinReturned)
	}
}

func indexEntryByID(entries []transcriptEntry, id uint32) int {
	if id == 0 {
		return -1
	}
	for index := range entries {
		if entries[index].message.ID == id {
			return index
		}
	}
	return -1
}

func (t *residentTranscript) scrollBy(rows int) {
	t.pendingScroll += rows
}

func (t *residentTranscript) discardPendingScroll() int {
	rows := t.pendingScroll
	t.pendingScroll = 0
	return rows
}

func (t *residentTranscript) takePinTransition() pinEdge {
	transition := t.pinTransition
	t.pinTransition = pinNone
	return transition
}

func (t *residentTranscript) hasAnimatedMessages() bool {
	return t != nil && t.animatedCount > 0
}

func (t *residentTranscript) recordPinTransition(transition pinEdge) {
	if transition != pinNone {
		t.pinTransition = transition
	}
}

func windowTopAnchored(lines []string, budget, topOffset int) []string {
	if budget <= 0 || len(lines) == 0 {
		return nil
	}
	maxTop := max(len(lines)-budget, 0)
	top := clampInt(topOffset, 0, maxTop)
	end := min(top+budget, len(lines))
	return lines[top:end]
}

func windowBottom(lines []string, budget int) []string {
	if budget <= 0 || len(lines) == 0 {
		return nil
	}
	if len(lines) <= budget {
		return lines
	}
	return lines[len(lines)-budget:]
}
