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
	transcriptState
	pages     map[uint64]*transcriptPage
	bySlot    map[uint64]uint64
	byID      map[uint32]transcriptOccurrences
	summaries [transcriptSummaryKinds]transcriptSummaryIndex
}

type transcriptState struct {
	epoch uint32
	// An empty seed is distinct from the pre-seed state.
	hasEpoch             bool
	first, end, nextSlot uint64
	truncated            bool
	pinned               bool
	anchor               transcriptAnchor
	pendingScroll        int
	pinTransition        pinEdge
	animatedCount        int
	payloadBytes         uint64
	toolCounts           [3]int
}

type transcriptEntry struct {
	slot           uint64
	revision       uint64
	message        protocol.AgentChatMessage
	prevID, nextID uint64
	payloadBytes   uint64

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
	return &residentTranscript{
		transcriptState: transcriptState{pinned: true, first: 1, end: 1},
		pages:           make(map[uint64]*transcriptPage),
		bySlot:          make(map[uint64]uint64),
		byID:            make(map[uint32]transcriptOccurrences),
	}
}

type transcriptDropReason string

const (
	transcriptApplied            transcriptDropReason = ""
	transcriptDroppedBeforeSeed  transcriptDropReason = "append before seed"
	transcriptDroppedEpoch       transcriptDropReason = "epoch mismatch"
	transcriptDroppedDesync      transcriptDropReason = "desynced (short store)"
	transcriptDroppedUndecodable transcriptDropReason = "undecodable frame"
)

// apply is the owner-level single-command transaction. Frame publication uses
// one plan for all commands and commits only after every other frame check.
func (t *residentTranscript) apply(frame protocol.AgentTranscript) transcriptDropReason {
	plan := t.prepare()
	if reason := plan.apply(frame); reason != transcriptApplied {
		return reason
	}
	plan.commit()
	return transcriptApplied
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
