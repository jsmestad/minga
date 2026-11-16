package ui

import (
	"math"
	"reflect"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const transcriptPageSize = 64

type transcriptPage struct {
	cells [transcriptPageSize]transcriptEntry
	count int
}

// Occurrences are linked in ordinal order. Removing either boundary touches
// only the removed occurrences and their surviving neighbors, never the prefix.
type transcriptOccurrences struct{ first, last uint64 }

func (t *residentTranscript) len() int {
	if t == nil {
		return 0
	}
	return int(t.end - t.first)
}

func (t *residentTranscript) entry(index int) *transcriptEntry {
	return t.at(t.first + uint64(index))
}

func (t *residentTranscript) at(ordinal uint64) *transcriptEntry {
	return &t.pages[ordinal/transcriptPageSize].cells[ordinal%transcriptPageSize]
}

func (t *residentTranscript) rank(slot uint64) (int, bool) {
	ordinal, ok := t.bySlot[slot]
	return int(ordinal - t.first), ok
}

// A plan overlays only affected cells and index keys. The resident pages and
// payloads remain read-only until all frame validation has completed. Update
// and View are serial; the asynchronous terminal renderer receives tea.View,
// not this owner or its plan.
type transcriptPlan struct {
	owner *residentTranscript
	transcriptState
	cells     map[uint64]transcriptEntry
	slots     map[uint64]uint64
	ids       map[uint32]transcriptOccurrences
	exhausted bool
}

func (t *residentTranscript) prepare() *transcriptPlan {
	return &transcriptPlan{owner: t, transcriptState: t.transcriptState,
		cells: make(map[uint64]transcriptEntry), slots: make(map[uint64]uint64),
		ids: make(map[uint32]transcriptOccurrences)}
}

func (p *transcriptPlan) at(ordinal uint64) transcriptEntry {
	if entry, ok := p.cells[ordinal]; ok {
		return entry
	}
	return *p.owner.at(ordinal)
}

func (p *transcriptPlan) slot(slot uint64) uint64 {
	if ordinal, ok := p.slots[slot]; ok {
		return ordinal
	}
	return p.owner.bySlot[slot]
}

func (p *transcriptPlan) occurrences(id uint32) transcriptOccurrences {
	if occurrences, ok := p.ids[id]; ok {
		return occurrences
	}
	return p.owner.byID[id]
}

func (p *transcriptPlan) remove(ordinal uint64) {
	entry := p.at(ordinal)
	p.animatedCount -= boolInt(agentMessageAnimated(entry.message))
	p.payloadBytes -= entry.payloadBytes
	p.slots[entry.slot] = 0
	if id := entry.message.ID; id != 0 {
		occurrences := p.occurrences(id)
		if entry.prevID == 0 {
			occurrences.first = entry.nextID
		} else {
			previous := p.at(entry.prevID)
			previous.nextID = entry.nextID
			p.cells[entry.prevID] = previous
		}
		if entry.nextID == 0 {
			occurrences.last = entry.prevID
		} else {
			next := p.at(entry.nextID)
			next.prevID = entry.prevID
			p.cells[entry.nextID] = next
		}
		p.ids[id] = occurrences
	}
	p.cells[ordinal] = transcriptEntry{}
}

func (p *transcriptPlan) append(entry transcriptEntry) {
	if p.end == math.MaxUint64 || p.end-p.first == uint64(math.MaxInt) || entry.payloadBytes > math.MaxUint64-p.payloadBytes {
		p.exhausted = true
		return
	}
	ordinal := p.end
	entry.prevID, entry.nextID = 0, 0
	if id := entry.message.ID; id != 0 {
		occurrences := p.occurrences(id)
		entry.prevID = occurrences.last
		if occurrences.last == 0 {
			occurrences.first = ordinal
		} else {
			previous := p.at(occurrences.last)
			previous.nextID = ordinal
			p.cells[occurrences.last] = previous
		}
		occurrences.last = ordinal
		p.ids[id] = occurrences
	}
	p.cells[ordinal] = entry
	p.slots[entry.slot] = ordinal
	p.animatedCount += boolInt(agentMessageAnimated(entry.message))
	p.payloadBytes += entry.payloadBytes
	p.end++
}

func (p *transcriptPlan) fresh(message protocol.AgentChatMessage) transcriptEntry {
	if p.nextSlot == math.MaxUint64 {
		p.exhausted = true
		return transcriptEntry{}
	}
	p.nextSlot++
	return transcriptEntry{slot: p.nextSlot, revision: 1, message: message, payloadBytes: transcriptPayloadBytes(message)}
}

func (p *transcriptPlan) apply(frame protocol.AgentTranscript) transcriptDropReason {
	if !frame.Present {
		return transcriptDroppedUndecodable
	}
	if !frame.FullReplace() {
		if !p.hasEpoch {
			return transcriptDroppedBeforeSeed
		}
		if frame.Epoch != p.epoch {
			return transcriptDroppedEpoch
		}
		if uint64(frame.TrimFront)+uint64(frame.BaseCount) > p.end-p.first {
			return transcriptDroppedDesync
		}
	}
	oldFirst, oldEnd := p.first, p.end
	oldAnchor := p.slot(p.anchor.slot)
	oldRank := int(oldAnchor - oldFirst)
	if frame.FullReplace() {
		reset := !p.hasEpoch || frame.Epoch != p.epoch
		next, successor, predecessor := p.replacement(frame.Messages, reset, oldAnchor)
		if p.exhausted {
			return transcriptDroppedDesync
		}
		for ordinal := oldFirst; ordinal < oldEnd; ordinal++ {
			p.remove(ordinal)
		}
		// Full input already requires visiting every incoming entry. Keep ordinals
		// monotone across replacements as well as ordinary front trimming.
		p.first = p.end
		for _, entry := range next {
			p.append(entry)
			if p.exhausted {
				return transcriptDroppedDesync
			}
		}
		p.epoch, p.hasEpoch = frame.Epoch, true
		if reset {
			p.pinned, p.anchor, p.pendingScroll, p.pinTransition = true, transcriptAnchor{}, 0, pinNone
		} else {
			p.reconcileAnchor(oldAnchor, oldRank, successor, predecessor)
		}
	} else {
		first := oldFirst + uint64(frame.TrimFront)
		end := first + uint64(frame.BaseCount)
		var successor, predecessor uint64
		if first < end && oldAnchor != 0 {
			if oldAnchor < first {
				successor = p.at(first).slot
			}
			if oldAnchor >= end {
				predecessor = p.at(end - 1).slot
			}
		}
		for ordinal := oldFirst; ordinal < first; ordinal++ {
			p.remove(ordinal)
		}
		for ordinal := end; ordinal < oldEnd; ordinal++ {
			p.remove(ordinal)
		}
		p.first, p.end = first, end
		for _, message := range frame.Messages {
			ordinal := uint64(0)
			if message.ID != 0 {
				ordinal = p.occurrences(message.ID).first
			}
			if ordinal == 0 {
				entry := p.fresh(message)
				if p.exhausted {
					return transcriptDroppedDesync
				}
				p.append(entry)
				if p.exhausted {
					return transcriptDroppedDesync
				}
				continue
			}
			entry := p.at(ordinal)
			if entry.revision == math.MaxUint64 && !reflect.DeepEqual(entry.message, message) {
				return transcriptDroppedDesync
			}
			revised := reviseTranscriptEntry(entry, message)
			revised.payloadBytes = transcriptPayloadBytes(message)
			if revised.payloadBytes > math.MaxUint64-(p.payloadBytes-entry.payloadBytes) {
				return transcriptDroppedDesync
			}
			p.payloadBytes = p.payloadBytes - entry.payloadBytes + revised.payloadBytes
			p.animatedCount += boolInt(agentMessageAnimated(message)) - boolInt(agentMessageAnimated(entry.message))
			p.cells[ordinal] = revised
		}
		p.reconcileAnchor(oldAnchor, oldRank, successor, predecessor)
	}
	p.truncated = frame.Truncated
	return transcriptApplied
}

// Same-position matches reserve first, then all exact occurrences, then the
// first still-unreserved nonzero-ID revision. No old entry slice is copied.
func (p *transcriptPlan) replacement(messages []protocol.AgentChatMessage, reset bool, anchor uint64) ([]transcriptEntry, uint64, uint64) {
	matches := make([]uint64, len(messages))
	used := make(map[uint64]bool, len(messages))
	if !reset {
		for index, message := range messages {
			ordinal := p.first + uint64(index)
			if ordinal < p.end && reflect.DeepEqual(p.at(ordinal).message, message) {
				matches[index] = ordinal
				used[ordinal] = true
			}
		}
		exact := make(map[string][]uint64)
		byID := make(map[uint32][]uint64)
		for ordinal := p.first; ordinal < p.end; ordinal++ {
			if !used[ordinal] {
				entry := p.at(ordinal)
				key := transcriptMessageKey(entry.message)
				exact[key] = append(exact[key], ordinal)
			}
		}
		for index, message := range messages {
			if matches[index] != 0 {
				continue
			}
			key := transcriptMessageKey(message)
			if ordinals := exact[key]; len(ordinals) > 0 {
				matches[index] = ordinals[0]
				used[ordinals[0]] = true
				exact[key] = ordinals[1:]
			}
		}
		for ordinal := p.first; ordinal < p.end; ordinal++ {
			if id := p.at(ordinal).message.ID; !used[ordinal] && id != 0 {
				byID[id] = append(byID[id], ordinal)
			}
		}
		for index, message := range messages {
			if matches[index] != 0 || message.ID == 0 {
				continue
			}
			if ordinals := byID[message.ID]; len(ordinals) > 0 {
				matches[index] = ordinals[0]
				byID[message.ID] = ordinals[1:]
			}
		}
	}
	next := make([]transcriptEntry, len(messages))
	successorOrdinal, predecessorOrdinal := uint64(math.MaxUint64), uint64(0)
	var successor, predecessor uint64
	for index, message := range messages {
		ordinal := matches[index]
		if p.exhausted {
			return nil, 0, 0
		}
		if ordinal == 0 {
			next[index] = p.fresh(message)
			continue
		}
		old := p.at(ordinal)
		if old.revision == math.MaxUint64 && !reflect.DeepEqual(old.message, message) {
			p.exhausted = true
			return nil, 0, 0
		}
		next[index] = reviseTranscriptEntry(old, message)
		next[index].payloadBytes = transcriptPayloadBytes(message)
		if ordinal > anchor && ordinal < successorOrdinal {
			successorOrdinal, successor = ordinal, next[index].slot
		}
		if ordinal < anchor && ordinal > predecessorOrdinal {
			predecessorOrdinal, predecessor = ordinal, next[index].slot
		}
	}
	return next, successor, predecessor
}

func (p *transcriptPlan) reconcileAnchor(oldOrdinal uint64, oldRank int, successor, predecessor uint64) {
	if p.first == p.end {
		if !p.pinned {
			p.pinTransition = pinReturned
		}
		p.pinned, p.anchor, p.pendingScroll = true, transcriptAnchor{}, 0
		return
	}
	if p.pinned || p.anchor.slot == 0 || p.slot(p.anchor.slot) != 0 {
		return
	}
	if oldOrdinal == 0 {
		p.pinned, p.anchor, p.pendingScroll = true, transcriptAnchor{}, 0
		return
	}
	if successor != 0 {
		p.anchor = transcriptAnchor{slot: successor}
		return
	}
	if predecessor != 0 {
		p.anchor.slot = predecessor
		return
	}
	rank := min(oldRank, int(p.end-p.first)-1)
	p.anchor.slot = p.at(p.first + uint64(rank)).slot
}

// commit has no validation or recoverable failure path. Empty cells are zeroed
// before empty pages are retired, including when a removed page is held by a
// diagnostic/test observer. No consumed command or plan is retained by owner.
func (p *transcriptPlan) commit() {
	t := p.owner
	for ordinal, entry := range p.cells {
		number := ordinal / transcriptPageSize
		page := t.pages[number]
		if page == nil {
			if entry.slot == 0 {
				continue
			}
			page = &transcriptPage{}
			t.pages[number] = page
		}
		cell := &page.cells[ordinal%transcriptPageSize]
		page.count += boolInt(entry.slot != 0) - boolInt(cell.slot != 0)
		oldCounts, newCounts := transcriptToolCounts(cell.message), transcriptToolCounts(entry.message)
		for index := range p.toolCounts {
			p.toolCounts[index] += newCounts[index] - oldCounts[index]
		}
		oldKinds, newKinds := transcriptSummaryMembership(cell.message), transcriptSummaryMembership(entry.message)
		for kind := range t.summaries {
			if oldKinds[kind] == newKinds[kind] {
				continue
			}
			if newKinds[kind] {
				t.summaries[kind].add(ordinal)
			} else {
				t.summaries[kind].remove(ordinal)
			}
		}
		*cell = entry
		if page.count == 0 {
			delete(t.pages, number)
		}
	}
	for slot, ordinal := range p.slots {
		if ordinal == 0 {
			delete(t.bySlot, slot)
		} else {
			t.bySlot[slot] = ordinal
		}
	}
	for id, occurrences := range p.ids {
		if occurrences.first == 0 {
			delete(t.byID, id)
		} else {
			t.byID[id] = occurrences
		}
	}
	t.transcriptState = p.transcriptState
}

// Payload accounting counts every owned string byte, including URLs and nested
// styled/markdown/preview payloads. Shared decoded strings still count once per
// occurrence, so revisions and removals have exact additive resource effects.
func transcriptPayloadBytes(message protocol.AgentChatMessage) uint64 {
	total := uint64(len(message.Text)) + uint64(len(message.Name)) + uint64(len(message.Summary)) + uint64(len(message.Result))
	total += uint64(len(message.ApprovalTarget.SessionID)) + uint64(len(message.ApprovalTarget.RequestID)) + uint64(len(message.ApprovalTarget.ToolCallID))
	total += transcriptStyledBytes(message.StyledLines)
	for _, block := range message.MarkdownBlocks {
		total += transcriptStyledBytes(block.Lines) + uint64(len(block.Language)) + uint64(len(block.Label)) + uint64(len(block.TargetPath))
	}
	for _, line := range message.PreviewLines {
		total += uint64(len(line))
	}
	return total
}

func transcriptStyledBytes(lines []protocol.AgentStyledLine) uint64 {
	var total uint64
	for _, line := range lines {
		for _, run := range line {
			total += uint64(len(run.Text)) + uint64(len(run.URL))
		}
	}
	return total
}

const (
	transcriptSummaryError = iota
	transcriptSummaryUsage
	transcriptSummaryTool
	transcriptSummaryThinking
	transcriptSummaryKinds
)

// Summary indexes own only ordinals. Indexed max-heaps permit in-place kind
// changes without a history walk or lazy dead keys retaining removed entries.
type transcriptSummaryIndex struct {
	ordinals  []uint64
	positions map[uint64]int
}

func (s *transcriptSummaryIndex) swap(left, right int) {
	s.ordinals[left], s.ordinals[right] = s.ordinals[right], s.ordinals[left]
	s.positions[s.ordinals[left]], s.positions[s.ordinals[right]] = left, right
}

func (s *transcriptSummaryIndex) up(index int) int {
	for index > 0 {
		parent := (index - 1) / 2
		if s.ordinals[parent] >= s.ordinals[index] {
			break
		}
		s.swap(parent, index)
		index = parent
	}
	return index
}

func (s *transcriptSummaryIndex) add(ordinal uint64) {
	if s.positions == nil {
		s.positions = make(map[uint64]int)
	}
	s.positions[ordinal] = len(s.ordinals)
	s.ordinals = append(s.ordinals, ordinal)
	s.up(len(s.ordinals) - 1)
}

func (s *transcriptSummaryIndex) remove(ordinal uint64) {
	index := s.positions[ordinal]
	last := len(s.ordinals) - 1
	s.swap(index, last)
	delete(s.positions, ordinal)
	s.ordinals[last] = 0
	s.ordinals = s.ordinals[:last]
	if index == last {
		return
	}
	index = s.up(index)
	for {
		child := index*2 + 1
		if child >= len(s.ordinals) {
			return
		}
		if child+1 < len(s.ordinals) && s.ordinals[child+1] > s.ordinals[child] {
			child++
		}
		if s.ordinals[index] >= s.ordinals[child] {
			return
		}
		s.swap(index, child)
		index = child
	}
}

func transcriptSummaryMembership(message protocol.AgentChatMessage) [transcriptSummaryKinds]bool {
	return [transcriptSummaryKinds]bool{
		message.Text != "" && ((message.Kind == agentKindSystem && message.Status == 1) || message.IsError),
		message.Kind == agentKindUsage,
		message.ID > 0 && (message.Kind == agentKindTool || message.Kind == agentKindStyledTool),
		message.ID > 0 && message.Kind == agentKindThinking,
	}
}

func transcriptToolCounts(message protocol.AgentChatMessage) [3]int {
	if message.Kind != agentKindTool && message.Kind != agentKindStyledTool && message.Kind != agentKindApprovalTool {
		return [3]int{}
	}
	return [3]int{1, boolInt(message.Status == 0), boolInt(message.Status == 2 || message.IsError)}
}

func (t *residentTranscript) latest(kind int) (protocol.AgentChatMessage, bool) {
	if t == nil || len(t.summaries[kind].ordinals) == 0 {
		return protocol.AgentChatMessage{}, false
	}
	return t.at(t.summaries[kind].ordinals[0]).message, true
}
