package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	transcriptChunkRows     = 32
	transcriptCacheByteCap  = 1 << 20
	transcriptOverscanLimit = 64
)

type transcriptCacheKey struct {
	slot     uint64
	revision uint64
	chunk    int
}

type transcriptCacheEntry struct {
	rows     []string
	bytes    int
	lastUsed uint64
}

// transcriptRenderWork is reset for each production compose. Tests and
// benchmarks use it as the portable complexity gate.
type transcriptRenderWork struct {
	MessagesVisited  int
	MessagesMeasured int
	RowsStyled       int
	CacheHits        int
	CacheMisses      int
	CacheEvictions   int
	RetainedRows     int
	RetainedBytes    int
}

// agentTranscriptRenderer owns disposable styled output. It retains only one
// active width/theme generation and evicts by both rows and bytes.
type agentTranscriptRenderer struct {
	cache   map[transcriptCacheKey]transcriptCacheEntry
	width   int
	theme   uint64
	rowCap  int
	rows    int
	bytes   int
	clock   uint64
	work    transcriptRenderWork
	visited map[uint64]struct{}
}

type transcriptPosition struct {
	index int
	row   int
}

func newAgentTranscriptRenderer() *agentTranscriptRenderer {
	return &agentTranscriptRenderer{cache: map[transcriptCacheKey]transcriptCacheEntry{}}
}

func (r *agentTranscriptRenderer) begin(width int, theme uint64, budget int) {
	if r.cache == nil {
		r.cache = map[transcriptCacheKey]transcriptCacheEntry{}
	}
	if r.width != width || r.theme != theme {
		r.cache = map[transcriptCacheKey]transcriptCacheEntry{}
		r.rows = 0
		r.bytes = 0
		r.width = width
		r.theme = theme
	}
	r.rowCap = max(budget*4, 0)
	r.work = transcriptRenderWork{}
	r.visited = map[uint64]struct{}{}
	r.enforceCaps()
}

func (r *agentTranscriptRenderer) finish() {
	r.work.RetainedRows = r.rows
	r.work.RetainedBytes = r.bytes
}

func (r *agentTranscriptRenderer) markVisited(slot uint64) {
	if _, found := r.visited[slot]; found {
		return
	}
	r.visited[slot] = struct{}{}
	r.work.MessagesVisited++
}

func (r *agentTranscriptRenderer) messageHeight(m Model, entry *transcriptEntry, width int) int {
	r.markVisited(entry.slot)
	if entry.heightRevision == entry.revision && entry.heightWidth == width && entry.height > 0 {
		return entry.height
	}
	entry.height = agentMessageRowCount(entry.message)
	entry.heightWidth = width
	entry.heightRevision = entry.revision
	r.work.MessagesMeasured++
	return entry.height
}

func (r *agentTranscriptRenderer) render(m Model, transcript *residentTranscript, budget int, width int) []string {
	r.begin(width, m.paletteFingerprint(), budget)
	defer r.finish()
	if transcript == nil || budget <= 0 || len(transcript.entries) == 0 {
		if transcript != nil {
			transcript.discardPendingScroll()
		}
		return nil
	}

	rows := transcript.discardPendingScroll()

	if transcript.pinned {
		tail, _ := r.tailStart(m, transcript, budget, width)
		allFits := r.allFits(m, transcript, budget, width)
		if rows >= 0 || allFits {
			return r.renderPinned(m, transcript, budget, width)
		}
		position := tail
		if -rows > max(budget*8, 256) {
			position = transcriptPosition{}
		} else {
			position = r.moveBackward(m, transcript, position, -rows, width)
		}
		transcript.pinned = false
		transcript.anchor = r.anchorFor(transcript, position)
		transcript.recordPinTransition(pinScrolledAway)
		return r.renderFrom(m, transcript, position, budget, width)
	}

	position := r.positionForAnchor(m, transcript, width)
	if rows < 0 {
		if -rows > max(budget*8, 256) {
			position = transcriptPosition{}
		} else {
			position = r.moveBackward(m, transcript, position, -rows, width)
		}
	} else if rows > 0 {
		tail, _ := r.tailStart(m, transcript, budget, width)
		if rows > max(budget*8, 256) {
			position = tail
		} else {
			position = r.moveForward(m, transcript, position, rows, width)
		}
		if r.positionAtOrAfter(position, tail) {
			transcript.pinned = true
			transcript.anchor = transcriptAnchor{}
			transcript.recordPinTransition(pinReturned)
			return r.renderPinned(m, transcript, budget, width)
		}
	}

	if r.allFits(m, transcript, budget, width) {
		transcript.returnToBottom()
		return r.renderPinned(m, transcript, budget, width)
	}

	transcript.anchor = r.anchorFor(transcript, position)
	lines := r.renderFrom(m, transcript, position, budget, width)
	if len(lines) == budget {
		return lines
	}

	// A trim or replacement can leave a retained anchor too close to the end to
	// fill the viewport. Reaching the bounded tail means the reader is at the
	// bottom again, so re-pin and report the edge instead of leaving BEAM follow
	// state disengaged after a content shrink.
	transcript.returnToBottom()
	return r.renderPinned(m, transcript, budget, width)
}

func (r *agentTranscriptRenderer) renderPinned(m Model, transcript *residentTranscript, budget int, width int) []string {
	overscan := min(budget, transcriptOverscanLimit)
	start := r.moveBackward(m, transcript, r.endPosition(m, transcript, width), budget+overscan, width)
	lines := r.renderForward(m, transcript, start, budget+overscan, width)
	lines = windowBottom(lines, budget)
	if transcript.truncated && len(lines) < budget && start.index == 0 && start.row == 0 {
		return append([]string{m.renderAgentEarlierMessagesHidden(width)}, lines...)
	}
	return lines
}

func (r *agentTranscriptRenderer) renderFrom(m Model, transcript *residentTranscript, position transcriptPosition, budget int, width int) []string {
	showTruncated := transcript.truncated && position.index == 0 && position.row == 0
	rowBudget := budget
	if showTruncated {
		rowBudget--
	}
	overscan := min(max(rowBudget, 0), transcriptOverscanLimit)
	lines := r.renderForward(m, transcript, position, max(rowBudget, 0)+overscan, width)
	lines = takeLines(lines, max(rowBudget, 0))
	if showTruncated {
		return append([]string{m.renderAgentEarlierMessagesHidden(width)}, lines...)
	}
	return lines
}

func (r *agentTranscriptRenderer) tailStart(m Model, transcript *residentTranscript, budget int, width int) (transcriptPosition, bool) {
	start := r.moveBackward(m, transcript, r.endPosition(m, transcript, width), budget, width)
	return start, start.index == 0 && start.row == 0
}

func (r *agentTranscriptRenderer) allFits(m Model, transcript *residentTranscript, budget int, width int) bool {
	effectiveBudget := budget
	if transcript.truncated {
		effectiveBudget--
	}
	if effectiveBudget <= 0 || len(transcript.entries)*2-1 > effectiveBudget {
		return false
	}
	_, allFits := r.tailStart(m, transcript, effectiveBudget, width)
	return allFits
}

func (r *agentTranscriptRenderer) endPosition(m Model, transcript *residentTranscript, width int) transcriptPosition {
	last := len(transcript.entries) - 1
	height := r.messageHeight(m, &transcript.entries[last], width)
	return transcriptPosition{index: last, row: height}
}

func (r *agentTranscriptRenderer) blockHeight(m Model, transcript *residentTranscript, index int, width int) int {
	height := r.messageHeight(m, &transcript.entries[index], width)
	if index < len(transcript.entries)-1 {
		height++
	}
	return height
}

func (r *agentTranscriptRenderer) positionForAnchor(m Model, transcript *residentTranscript, width int) transcriptPosition {
	index, found := transcript.bySlot[transcript.anchor.slot]
	if !found {
		return transcriptPosition{}
	}
	blockHeight := r.blockHeight(m, transcript, index, width)
	return transcriptPosition{index: index, row: clampInt(transcript.anchor.row, 0, max(blockHeight-1, 0))}
}

func (r *agentTranscriptRenderer) anchorFor(transcript *residentTranscript, position transcriptPosition) transcriptAnchor {
	if len(transcript.entries) == 0 {
		return transcriptAnchor{}
	}
	position.index = clampInt(position.index, 0, len(transcript.entries)-1)
	return transcriptAnchor{slot: transcript.entries[position.index].slot, row: max(position.row, 0)}
}

func (r *agentTranscriptRenderer) moveBackward(m Model, transcript *residentTranscript, position transcriptPosition, rows int, width int) transcriptPosition {
	for rows > 0 {
		if position.row >= rows {
			position.row -= rows
			return position
		}
		rows -= position.row
		if position.index == 0 {
			return transcriptPosition{}
		}
		position.index--
		position.row = r.blockHeight(m, transcript, position.index, width)
	}
	return position
}

func (r *agentTranscriptRenderer) moveForward(m Model, transcript *residentTranscript, position transcriptPosition, rows int, width int) transcriptPosition {
	for rows > 0 {
		blockHeight := r.blockHeight(m, transcript, position.index, width)
		remaining := blockHeight - position.row
		if rows < remaining {
			position.row += rows
			return position
		}
		rows -= remaining
		if position.index == len(transcript.entries)-1 {
			return transcriptPosition{index: position.index, row: blockHeight}
		}
		position.index++
		position.row = 0
	}
	return position
}

func (r *agentTranscriptRenderer) positionAtOrAfter(left transcriptPosition, right transcriptPosition) bool {
	return left.index > right.index || (left.index == right.index && left.row >= right.row)
}

func (r *agentTranscriptRenderer) renderForward(m Model, transcript *residentTranscript, position transcriptPosition, limit int, width int) []string {
	if limit <= 0 {
		return nil
	}
	lines := make([]string, 0, limit)
	for position.index < len(transcript.entries) && len(lines) < limit {
		entry := &transcript.entries[position.index]
		height := r.messageHeight(m, entry, width)
		if position.row < height {
			count := min(limit-len(lines), height-position.row)
			lines = append(lines, r.messageRows(m, *entry, position.row, count, width)...)
			position.row += count
			continue
		}
		if position.index < len(transcript.entries)-1 && position.row == height {
			lines = append(lines, m.renderAgentTranscriptSeparator(width))
			position.row++
			continue
		}
		position.index++
		position.row = 0
	}
	return lines
}

func (r *agentTranscriptRenderer) messageRows(m Model, entry transcriptEntry, start int, count int, width int) []string {
	if count <= 0 {
		return nil
	}
	if agentMessageAnimated(entry.message) {
		rows := m.renderAgentMessageRows(entry.message, width, start, count)
		r.work.RowsStyled += len(rows)
		return rows
	}

	end := start + count
	out := make([]string, 0, count)
	for chunk := start / transcriptChunkRows; chunk <= (end-1)/transcriptChunkRows; chunk++ {
		chunkStart := chunk * transcriptChunkRows
		key := transcriptCacheKey{slot: entry.slot, revision: entry.revision, chunk: chunk}
		rows, found := r.cached(key)
		if !found {
			height := agentMessageRowCount(entry.message)
			chunkCount := min(transcriptChunkRows, height-chunkStart)
			rows = m.renderAgentMessageRows(entry.message, width, chunkStart, chunkCount)
			r.work.RowsStyled += len(rows)
			r.work.CacheMisses++
			r.admit(key, rows)
		}
		from := max(start-chunkStart, 0)
		to := min(end-chunkStart, len(rows))
		if from < to {
			out = append(out, rows[from:to]...)
		}
	}
	return out
}

func (r *agentTranscriptRenderer) cached(key transcriptCacheKey) ([]string, bool) {
	entry, found := r.cache[key]
	if !found {
		return nil, false
	}
	r.clock++
	entry.lastUsed = r.clock
	r.cache[key] = entry
	r.work.CacheHits++
	return entry.rows, true
}

func (r *agentTranscriptRenderer) admit(key transcriptCacheKey, rows []string) {
	bytes := 0
	for _, row := range rows {
		bytes += len(row)
	}
	if len(rows) == 0 || len(rows) > r.rowCap || bytes > transcriptCacheByteCap {
		return
	}
	r.clock++
	r.cache[key] = transcriptCacheEntry{rows: rows, bytes: bytes, lastUsed: r.clock}
	r.rows += len(rows)
	r.bytes += bytes
	r.enforceCaps()
}

func (r *agentTranscriptRenderer) enforceCaps() {
	for (r.rows > r.rowCap || r.bytes > transcriptCacheByteCap) && len(r.cache) > 0 {
		var oldestKey transcriptCacheKey
		oldestUse := ^uint64(0)
		for key, entry := range r.cache {
			if entry.lastUsed < oldestUse {
				oldestKey = key
				oldestUse = entry.lastUsed
			}
		}
		entry := r.cache[oldestKey]
		delete(r.cache, oldestKey)
		r.rows -= len(entry.rows)
		r.bytes -= entry.bytes
		r.work.CacheEvictions++
	}
}

func agentMessageAnimated(message protocol.AgentChatMessage) bool {
	return (message.Kind == agentKindThinking && !message.Collapsed) || ((message.Kind == agentKindTool || message.Kind == agentKindStyledTool) && message.Status == 0)
}

func agentMessageRowCount(message protocol.AgentChatMessage) int {
	switch message.Kind {
	case agentKindSystem, agentKindUsage:
		return 1
	case agentKindUser:
		return 1 + max(compactTextLineCount(message.Text, 2), 1)
	case agentKindAssistant, agentKindStyled:
		return agentAssistantMessageRowCount(message)
	case agentKindAssistantMarkdown:
		return agentAssistantMessageRowCount(message)
	case agentKindThinking:
		text := message.Text
		if text == "" {
			text = "working through the request"
		}
		return 1 + compactTextLineCount(text, agentThinkingBodyLines(message.Collapsed))
	case agentKindTool, agentKindStyledTool:
		count := 2 + cappedRows(len(message.PreviewLines), 8)
		if message.IsError && message.Result != "" {
			return count + cappedRows(len(agentToolTextLines(message.Result)), agentToolExpandedLines)
		}
		if hasAgentToolResult(message) && message.Collapsed {
			return count + 1
		}
		if !message.Collapsed {
			if len(message.StyledLines) > 0 {
				return count + cappedRows(len(message.StyledLines), agentToolExpandedLines)
			}
			return count + cappedRows(len(agentToolTextLines(message.Result)), agentToolExpandedLines)
		}
		return count
	case agentKindApprovalTool:
		return 4 + min(len(message.PreviewLines), 2)
	default:
		return 1 + max(compactTextLineCount(message.Text, 3), 1)
	}
}

func agentAssistantMessageRowCount(message protocol.AgentChatMessage) int {
	count := 1
	if len(message.MarkdownBlocks) > 0 {
		for _, block := range message.MarkdownBlocks {
			count += agentMarkdownBlockRowCount(block)
		}
		return count
	}
	if len(message.StyledLines) > 0 {
		return count + cappedRows(len(message.StyledLines), agentAssistantStyledLines)
	}
	return count + max(compactTextLineCount(message.Text, 3), 1)
}

func agentMarkdownBlockRowCount(block protocol.AgentMarkdownBlock) int {
	switch block.Kind {
	case 0x01, 0x02, 0x03, 0x04:
		return cappedRows(len(block.Lines), agentAssistantStyledLines)
	case 0x05, 0x06:
		return 1
	case 0x07:
		return len(block.Lines) + 2
	default:
		return 0
	}
}

func cappedRows(length int, limit int) int {
	if length <= 0 || limit <= 0 {
		return 0
	}
	return min(length, limit) + boolInt(length > limit)
}

func compactTextLineCount(text string, limit int) int {
	text = strings.TrimSpace(text)
	if text == "" || limit <= 0 {
		return 0
	}
	count := 0
	for _, raw := range strings.Split(text, "\n") {
		if strings.TrimSpace(raw) == "" {
			continue
		}
		count++
		if count == limit {
			break
		}
	}
	return count
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func (m Model) renderAgentMessageRows(message protocol.AgentChatMessage, width int, start int, count int) []string {
	if count <= 0 {
		return nil
	}
	if message.Kind != agentKindAssistantMarkdown || len(message.MarkdownBlocks) == 0 {
		rows := m.renderAgentMessage(message, width)
		return sliceRows(rows, start, count)
	}
	return m.renderAgentAssistantMarkdownRows(message, width, start, count)
}

func (m Model) renderAgentAssistantMarkdownRows(message protocol.AgentChatMessage, width int, start int, count int) []string {
	end := start + count
	rows := make([]string, 0, count)
	if start == 0 {
		rows = append(rows, m.renderAgentAssistantHeader(width))
	}
	offset := 1
	for _, block := range message.MarkdownBlocks {
		blockHeight := agentMarkdownBlockRowCount(block)
		if blockHeight == 0 || offset+blockHeight <= start {
			offset += blockHeight
			continue
		}
		if offset >= end {
			break
		}
		blockStart := max(start-offset, 0)
		blockCount := min(end-offset, blockHeight) - blockStart
		rows = append(rows, m.renderAgentMarkdownBlockRows(block, width, blockStart, blockCount)...)
		offset += blockHeight
	}
	return rows
}

func (m Model) renderAgentMarkdownBlockRows(block protocol.AgentMarkdownBlock, width int, start int, count int) []string {
	if count <= 0 {
		return nil
	}
	if block.Kind != 0x07 {
		return sliceRows(m.renderAgentMarkdownBlock(block, width), start, count)
	}
	return m.renderAgentCodeCardRows(block, width, start, count)
}

func (m Model) renderAgentCodeCardRows(block protocol.AgentMarkdownBlock, width int, start int, count int) []string {
	p := m.palette()
	surface := p.AgentCodeSurface()
	codeBorder := p.AgentCodeBorder()
	rail := lipgloss.NewStyle().Foreground(codeBorder).Background(surface).Render("  │ ")
	bodyWidth := max(width-lipgloss.Width(rail)-2, 8)
	label := nonEmpty(block.Label, "Code")
	if block.TargetPath != "" {
		label += " · " + block.TargetPath
	}
	if !block.Complete() {
		label += " · streaming"
	}
	height := len(block.Lines) + 2
	end := min(start+count, height)
	rows := make([]string, 0, end-start)
	for row := start; row < end; row++ {
		switch {
		case row == 0:
			header := rail + lipgloss.NewStyle().Foreground(codeBorder).Background(surface).Bold(true).Render("╭─ "+label)
			rows = append(rows, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(header, width)))
		case row == height-1:
			footer := rail + lipgloss.NewStyle().Foreground(codeBorder).Background(surface).Render("╰"+strings.Repeat("─", max(min(bodyWidth, width-6), 1)))
			rows = append(rows, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(footer, width)))
		default:
			body := m.renderAgentCodeCardLine(block.Lines[row-1], bodyWidth)
			rows = append(rows, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rail+"│ "+body, width)))
		}
	}
	return rows
}

func sliceRows(rows []string, start int, count int) []string {
	if start >= len(rows) || count <= 0 {
		return nil
	}
	end := min(start+count, len(rows))
	return rows[max(start, 0):end]
}

func (m Model) renderAgentAssistantHeader(width int) string {
	p := m.palette()
	headerMarker := lipgloss.NewStyle().Bold(true).Foreground(p.AgentAssistantBorder()).Background(p.AgentPanel()).Render("  ◇")
	headerLabel := lipgloss.NewStyle().Bold(true).Foreground(p.AgentAssistantLabel()).Background(p.AgentPanel()).Render(" Minga")
	header := headerMarker + headerLabel
	return lipgloss.NewStyle().Background(p.AgentPanel()).Width(width).Render(fitStyled(header, width))
}

func (r transcriptRenderWork) String() string {
	return fmt.Sprintf("visited=%d measured=%d styled=%d hits=%d misses=%d evictions=%d retained_rows=%d retained_bytes=%d", r.MessagesVisited, r.MessagesMeasured, r.RowsStyled, r.CacheHits, r.CacheMisses, r.CacheEvictions, r.RetainedRows, r.RetainedBytes)
}
