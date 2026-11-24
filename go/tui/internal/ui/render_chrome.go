package ui

import (
	"fmt"
	"image/color"
	"sort"
	"strings"
	"unicode"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const maxTabLabelWidth = 24

type headerChrome struct {
	workspaces protocol.WorkspaceBar
	tabs       protocol.TabBar
	breadcrumb protocol.Breadcrumb
}

func (m Model) headerChrome() headerChrome {
	spaces, _ := m.workspaceBar()
	tabs, _ := m.tabBar()
	var crumb protocol.Breadcrumb
	if m.width >= 100 {
		crumb, _ = m.breadcrumb()
	}
	return headerChrome{workspaces: spaces, tabs: tabs, breadcrumb: crumb}
}

func (h headerChrome) height() int {
	rows := 0
	if len(h.workspaces.Spaces) > 1 {
		rows++
	}
	if len(h.tabs.Tabs) > 0 {
		rows++
	}
	if len(h.breadcrumb.Segments) > 0 {
		rows++
	}
	return max(rows, 1) // the title occupies one row when semantic chrome is absent
}

func (m Model) headerLines() []string {
	tree, hasTree := m.fileTree()
	sidebarWidth := 0
	if hasTree && tree.Visible && tree.Width > 0 && m.width >= 50 {
		sidebarWidth = fileTreeWidth(m.width, tree)
	}
	mainWidth := m.width
	if sidebarWidth > 0 {
		mainWidth = max(m.width-sidebarWidth, 1)
	}

	header := m.headerChrome()
	lines := make([]string, 0, header.height())
	if len(header.workspaces.Spaces) > 1 {
		lines = append(lines, m.renderWorkspaces(header.workspaces, mainWidth))
	}
	if len(header.tabs.Tabs) > 0 {
		lines = append(lines, m.renderTabs(header.tabs, mainWidth))
	}
	if len(header.breadcrumb.Segments) > 0 {
		lines = append(lines, m.renderBreadcrumb(header.breadcrumb, mainWidth))
	}
	if len(lines) == 0 {
		title := m.title
		if title == "" {
			title = "Minga"
		}
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(m.palette().Accent()).Background(m.palette().Surface()).Width(mainWidth).Render(fitStyled(title, mainWidth)))
	}

	if sidebarWidth > 0 {
		lines = m.compositeHeaderWithSidebar(lines, tree, sidebarWidth)
	}
	return lines
}

// compositeHeaderWithSidebar prepends a sidebar column to each header line so
// the file tree header aligns with the tab bar and the tree separator runs
// continuously from header through body.
func (m Model) compositeHeaderWithSidebar(mainLines []string, tree protocol.FileTree, sidebarWidth int) []string {
	theme := m.palette()
	sepColor := theme.TreeSeparator()
	if tree.Focused {
		sepColor = theme.Accent()
	}
	treeBG := theme.TreeSurface()
	sepStyle := lipgloss.NewStyle().Foreground(sepColor).Background(treeBG)
	sep := sepStyle.Render("│")

	headerStyle := lipgloss.NewStyle().Foreground(theme.TreeHeaderText()).Background(treeBG).Width(sidebarWidth)
	fillStyle := lipgloss.NewStyle().Background(treeBG).Width(sidebarWidth)

	projectName := lastPathComponent(tree.Root)
	lines := make([]string, len(mainLines))
	for i, main := range mainLines {
		var left string
		if i == 0 {
			left = headerStyle.Bold(true).Render(fit(" 󰙅 "+projectName, sidebarWidth))
		} else {
			left = fillStyle.Render(strings.Repeat(" ", max(sidebarWidth-lipgloss.Width(sep), 1)))
		}
		left = replaceVisibleCell(left, max(sidebarWidth-1, 0), sep)
		lines[i] = lipgloss.JoinHorizontal(lipgloss.Top, left, main)
	}
	return lines
}

func lastPathComponent(path string) string {
	for i := len(path) - 1; i >= 0; i-- {
		if path[i] == '/' {
			if i == len(path)-1 {
				continue
			}
			return path[i+1:]
		}
	}
	return path
}

func (m Model) renderWorkspaces(spaces protocol.WorkspaceBar, width int) string {
	theme := m.palette()
	bg := theme.Surface()
	rowStyle := lipgloss.NewStyle().Background(bg).Width(width)
	labelStyle := lipgloss.NewStyle().Foreground(theme.Muted()).Background(bg)
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(bg)
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(bg)
	metaStyle := lipgloss.NewStyle().Foreground(theme.Muted()).Background(bg)
	alertStyle := lipgloss.NewStyle().Foreground(theme.Warning()).Background(bg)
	rendered := []string{labelStyle.Render("Spaces")}
	separator := metaStyle.Render(" · ")
	for _, space := range spaces.Spaces {
		primaryStyle := inactiveStyle
		marker := ""
		if space.Active {
			primaryStyle = activeStyle
			marker = activeStyle.Render("▎")
		}
		label := strings.TrimSpace(space.Icon + " " + space.Label)
		item := marker + primaryStyle.Render(label)
		meta := workspaceSpaceMetadata(space)
		if meta != "" {
			item += metaStyle.Render(" (" + meta + ")")
		}
		if space.Attention {
			item += alertStyle.Render(" !")
		}
		rendered = append(rendered, item)
	}
	return rowStyle.Render(fitStyled(strings.Join(rendered, separator), width))
}

func workspaceSpaceMetadata(space protocol.Workspace) string {
	parts := make([]string, 0, 4)
	if space.TabCount > 0 {
		parts = append(parts, pluralCount(space.TabCount, "tab"))
	}
	if space.DraftCount > 0 {
		parts = append(parts, pluralCount(space.DraftCount, "draft"))
	}
	if space.ConflictCount > 0 {
		parts = append(parts, pluralCount(space.ConflictCount, "conflict"))
	}
	if space.BackgroundCount > 0 {
		parts = append(parts, fmt.Sprintf("%d running", space.BackgroundCount))
	}
	return strings.Join(parts, ", ")
}

func pluralCount(count uint16, label string) string {
	if count == 1 {
		return fmt.Sprintf("%d %s", count, label)
	}
	return fmt.Sprintf("%d %ss", count, label)
}

func (m Model) renderTabs(tabBar protocol.TabBar, width int) string {
	theme := m.palette()
	chromeBG := theme.Surface()
	editorBG := m.editorBackground()
	rowStyle := lipgloss.NewStyle().Background(chromeBG).Width(width)
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.TabActiveText()).Background(editorBG).Padding(padding(spaceHairline, spaceSM))
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(chromeBG).Padding(padding(spaceHairline, spaceSM))
	rendered := make([]string, 0, len(tabBar.Tabs))
	for _, tab := range tabBar.Tabs {
		tabBG := chromeBG
		if tab.Active {
			tabBG = editorBG
		}
		icon := tabIcon(tab)
		iconText := icon.glyph
		if icon.color != "" {
			iconText = lipgloss.NewStyle().Foreground(lipgloss.Color(icon.color)).Background(tabBG).Render(icon.glyph)
		}
		tabLabel := ansi.TruncateWc(tab.Label, maxTabLabelWidth, "…")
		label := strings.TrimSpace(iconText + " " + tabLabel)
		if tab.Active {
			label = lipgloss.NewStyle().Foreground(theme.Accent()).Background(editorBG).Render("▌") + " " + label
		}
		if tab.Dirty {
			label += lipgloss.NewStyle().Foreground(theme.TabDirty()).Background(tabBG).Render(" *")
		}
		if tab.Attention {
			label += lipgloss.NewStyle().Foreground(theme.TabAttention()).Background(tabBG).Render(" !")
		}
		style := inactiveStyle
		if tab.Active {
			style = activeStyle
		} else if tab.Tint != 0 {
			style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", tab.Tint&0xFFFFFF)))
		}
		// Ephemeral (not-on-disk) buffers like Untitled-1 render dim, but
		// the active tab keeps its active foreground (matching the GUI,
		// which styles ephemeral with italics only).
		if tab.Ephemeral && !tab.Active {
			style = style.Foreground(theme.Muted())
		}
		rendered = append(rendered, m.zones.Mark(zoneIDTab(tab.ID), style.Render(label)))
	}
	return rowStyle.Render(fitStyled(strings.Join(rendered, " "), width))
}

func (m Model) renderBreadcrumb(crumb protocol.Breadcrumb, width int) string {
	bg := m.editorBackground()
	segments := make([]string, 0, len(crumb.Segments))
	for index, segment := range crumb.Segments {
		style := lipgloss.NewStyle().Foreground(m.palette().BreadcrumbText()).Background(bg)
		if index == len(crumb.Segments)-1 {
			style = style.Foreground(m.palette().Text())
		}
		segments = append(segments, style.Render(segment))
	}
	separator := lipgloss.NewStyle().Foreground(m.palette().BreadcrumbSeparator()).Background(bg).Render(" ❯ ")
	text := gap(spaceXL) + strings.Join(segments, separator)
	if git, ok := m.gitStatus(); ok && git.Branch != "" {
		gitText := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(bg).Render(gap(spaceXL) + "·" + gap(spaceXL) + m.gitSummary(git))
		if lipgloss.Width(text)+lipgloss.Width(gitText) <= width {
			text += gitText
		}
	}
	return lipgloss.NewStyle().Background(bg).Width(width).Render(fitStyled(text, width))
}

func (m Model) footerRows() int {
	if mini, ok := m.minibuffer(); ok && mini.Visible {
		return 2
	}
	return 1
}

func (m Model) footerLines() []string {
	status := fmt.Sprintf("row %d col %d", m.cursorRow+1, m.cursorCol+1)
	if chromeStatus, ok := m.statusBar(); ok {
		if chromeStatus.Review != nil {
			status = m.renderReviewStatus(*chromeStatus.Review)
		} else if len(chromeStatus.Left) > 0 || len(chromeStatus.Right) > 0 || chromeStatus.PendingKeys != "" {
			status = m.renderStatusSegments(chromeStatus)
		} else if chromeStatus.Filename != "" {
			icon := devIconForPath(chromeStatus.Filename, false)
			prefix := chromeStatus.Filename
			if icon.glyph != "" {
				prefix = icon.glyph + " " + chromeStatus.Filename
			}
			status = prefix + gap(modelineSegmentGap) + fmt.Sprintf("%d:%d", chromeStatus.Line, chromeStatus.Column)
			if message := m.renderStatusMessage(chromeStatus.Message); message != "" {
				status += gap(modelineSegmentGap) + message
			}
		} else if message := m.renderStatusMessage(chromeStatus.Message); message != "" {
			status = message
		}
	}
	if search, ok := m.searchState(); ok && search.Active {
		status += gap(modelineSegmentGap) + fmt.Sprintf("search %d/%d", search.CurrentIndex, search.Count)
	}
	if ext := m.extensionRuntimeStatus(); ext != "" {
		status += gap(modelineSegmentGap) + ext
	}
	if m.resyncPending {
		// A frame transaction was discarded and the model asked the BEAM for a
		// keyframe (#2219). Surface a subtle indicator while it waits so a stalled
		// resync is visible without competing with real status content; it clears
		// when a valid commit applies. Styled with the muted error tone at low
		// intensity rather than the loud full-screen surface.
		badge := lipgloss.NewStyle().Faint(true).Foreground(m.palette().Warning()).Background(m.palette().Base()).Render("resync…")
		status += gap(modelineSegmentGap) + badge
	}
	lines := []string{
		lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().Base()).Width(m.width).Render(fitStyled(status, m.width)),
	}
	// The committed minibuffer visibility authors the second footer row. Popup
	// visibility must not independently change the body's available allocation.
	if mini, ok := m.minibuffer(); ok && mini.Visible {
		lines = append(lines, m.renderMinibuffer(mini))
	}
	return lines
}

// renderStatusSegments draws the modeline: the left cluster from the leading inset, the right cluster at the trailing inset, and the echo text between them.
// The BEAM sends the segments in order with drop ranks; this frontend measures its own width (ADR-0001) and applies the ranks, lowest first, until everything fits.
// The echo text reserves at most a third of the row, as on macOS, and a rank-0 segment never drops, so a long notice is cut to the room that is left instead of replacing the modeline.
func (m Model) renderStatusSegments(status protocol.StatusBar) string {
	surface := lipgloss.NewStyle().Background(m.palette().ChromeSurface())
	message := m.renderStatusMessage(status.Message)
	reserved := 0
	if width := lipgloss.Width(message); width > 0 {
		reserved = min(width+2*modelineSegmentGap.cols(), m.width*34/100)
	}
	// Hover text is a local preview: it fills only the room the segments leave and never moves them.
	if message == "" {
		if hover := m.modelineHoverText(status); hover != "" {
			message = lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().ChromeSurface()).Render(sanitizeTerminalText(hover))
		}
	}
	// showcmd: echo the pending key sequence as a dim segment at the head of the right cluster so every keypress is acknowledged instantly (issue #2666).
	// The BEAM clears it (empty string) when the sequence resolves, aborts, or which-key opens, so no timer lives here.
	pending := ""
	if status.PendingKeys != "" {
		pending = lipgloss.NewStyle().Faint(true).Foreground(m.palette().Muted()).Background(m.palette().ChromeSurface()).Render(status.PendingKeys) + surface.Render(gap(modelineSegmentGap))
	}
	inset := modelineInset.cols()
	budget := max(m.width-2*inset-lipgloss.Width(pending), 0)
	fitted := fitModeline(append(append([]protocol.StatusSegment{}, status.Left...), status.Right...), len(status.Left), budget-reserved, m.modelineSegmentWidth)
	left := m.renderModelineCluster(fitted.left)
	right := pending + m.renderModelineCluster(fitted.right)
	available := max(m.width-2*inset-lipgloss.Width(left)-lipgloss.Width(right), 0)
	if lipgloss.Width(message) > max(available-2*modelineSegmentGap.cols(), 0) {
		message = fitStyled(message, max(available-2*modelineSegmentGap.cols(), 0))
	}
	messageWidth := lipgloss.Width(message)
	leftSpacer := strings.Repeat(" ", max((available-messageWidth)/2, 0))
	rightSpacer := strings.Repeat(" ", max(available-messageWidth-len(leftSpacer), 0))
	edge := surface.Render(gap(modelineInset))
	// Only segments that never drop are left when the row is still too wide; the terminal edge cuts them.
	return fitStyled(edge+left+surface.Render(leftSpacer)+message+surface.Render(rightSpacer)+right+edge, m.width)
}

// fittedSegment is one segment the modeline keeps: its index in the BEAM's order and whether it shows its compact form (the state mark and compact text).
type fittedSegment struct {
	index   int
	segment protocol.StatusSegment
	compact bool
}

type fittedModeline struct {
	left  []fittedSegment
	right []fittedSegment
}

// fitModeline applies the BEAM's drop ranks in ascending order until the segments, with one segment gap between neighbours in each cluster, fit in width.
// Every segment at the current rank goes at once; a segment with a compact form collapses instead and stays. Rank 0 never drops.
func fitModeline(segments []protocol.StatusSegment, leftCount int, width int, measure func(protocol.StatusSegment, bool) int) fittedModeline {
	compact := make([]bool, len(segments))
	dropped := make([]bool, len(segments))
	total := func() int {
		sum := 0
		clusters := [2]int{}
		for i, segment := range segments {
			if dropped[i] {
				continue
			}
			sum += measure(segment, compact[i])
			if i < leftCount {
				clusters[0]++
			} else {
				clusters[1]++
			}
		}
		for _, count := range clusters {
			if count > 1 {
				sum += (count - 1) * modelineSegmentGap.cols()
			}
		}
		if clusters[0] > 0 && clusters[1] > 0 {
			sum += modelineSegmentGap.cols()
		}
		return sum
	}
	for _, rank := range modelineDropRanks(segments) {
		if total() <= width {
			break
		}
		for i, segment := range segments {
			if segment.Drop != rank {
				continue
			}
			if segment.HasCompact {
				compact[i] = true
			} else {
				dropped[i] = true
			}
		}
	}
	var fitted fittedModeline
	for i, segment := range segments {
		if dropped[i] {
			continue
		}
		kept := fittedSegment{index: i, segment: segment, compact: compact[i]}
		if i < leftCount {
			fitted.left = append(fitted.left, kept)
		} else {
			fitted.right = append(fitted.right, kept)
		}
	}
	return fitted
}

// modelineDropRanks lists the nonzero drop ranks present, lowest first.
func modelineDropRanks(segments []protocol.StatusSegment) []byte {
	seen := map[byte]bool{}
	ranks := []byte{}
	for _, segment := range segments {
		if segment.Drop != 0 && !seen[segment.Drop] {
			seen[segment.Drop] = true
			ranks = append(ranks, segment.Drop)
		}
	}
	sort.Slice(ranks, func(a, b int) bool { return ranks[a] < ranks[b] })
	return ranks
}

func (m Model) modelineSegmentWidth(segment protocol.StatusSegment, compact bool) int {
	return lipgloss.Width(m.renderModelineSegment(segment, compact))
}

// renderModelineCluster draws kept segments one segment gap apart.
// Each segment is its own mouse zone, so a click runs its command and pointer motion over it echoes what it means and its key.
func (m Model) renderModelineCluster(segments []fittedSegment) string {
	surface := lipgloss.NewStyle().Background(m.palette().ChromeSurface())
	parts := make([]string, 0, len(segments))
	for _, kept := range segments {
		parts = append(parts, m.zones.Mark(zoneIDModelineSegment(kept.index), m.renderModelineSegment(kept.segment, kept.compact)))
	}
	return strings.Join(parts, surface.Render(gap(modelineSegmentGap)))
}

// renderModelineSegment draws one segment: the mode pill as the one saturated block, a state's glyph before its words, E and W as the marks of error and warning counts, and the compact form as the state glyph and its compact text.
func (m Model) renderModelineSegment(segment protocol.StatusSegment, compact bool) string {
	theme := m.palette()
	style := lipgloss.NewStyle().Foreground(theme.ChromeText()).Background(theme.ChromeSurface())
	if segment.Name == "mode" {
		bg, fg := m.modeColors(segment.Text)
		style = style.Background(bg).Foreground(fg).Bold(true).Padding(0, modelinePillPaddingH.cols())
	}
	if segment.FG != 0 {
		style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", segment.FG)))
	}
	if segment.BG != 0 {
		style = style.Background(lipgloss.Color(fmt.Sprintf("#%06X", segment.BG)))
	}
	if segment.Attrs&0x01 != 0 {
		style = style.Bold(true)
	}
	if segment.Attrs&0x02 != 0 {
		style = style.Underline(true)
	}
	if segment.Attrs&0x04 != 0 {
		style = style.Italic(true)
	}
	words := sanitizeTerminalText(segment.Text)
	if compact {
		words = sanitizeTerminalText(segment.Compact)
	}
	mark := ""
	if state, ok := generated.SpineStateFromWire(segment.State); ok {
		mark = state.Token().Glyph
	} else if segment.Name == "errors" {
		mark = "E"
	} else if segment.Name == "warnings" {
		mark = "W"
	}
	switch {
	case mark == "":
		return style.Render(words)
	case words == "":
		return style.Render(mark)
	default:
		return style.Render(mark + gap(modelineGlyphToWords) + words)
	}
}

// modelineHoverText is what the echo line says while the pointer rests on a modeline segment: its meaning and the key that does what a click does ("1 task needs you · SPC a a").
// It is read from the current segments, so a segment that changes or goes away takes its hover text with it.
func (m Model) modelineHoverText(status protocol.StatusBar) string {
	index := m.modelineHoverSegment - 1
	segments := append(append([]protocol.StatusSegment{}, status.Left...), status.Right...)
	if index < 0 || index >= len(segments) {
		return ""
	}
	segment := segments[index]
	if segment.Label != "" && segment.Key != "" {
		return segment.Label + " · " + segment.Key
	}
	return segment.Label
}

// modelineSegmentUnder returns the 1-based index of the modeline segment under the pointer, or 0 for none.
// Terminals that report pointer motion only during a drag never call it, as the design allows.
func (m Model) modelineSegmentUnder(msg tea.MouseMsg) int {
	status, ok := m.statusBar()
	if !ok {
		return 0
	}
	for index := range len(status.Left) + len(status.Right) {
		if zoneInfo := m.zones.Get(zoneIDModelineSegment(index)); zoneInfo != nil && zoneInfo.InBounds(msg) {
			return index + 1
		}
	}
	return 0
}

// extensionRuntimeStatus returns a compact, deterministic summary of the active
// gui_extension_runtime (0xA3) envelopes for the footer status line. It is the
// minimal honest "expose to render" surface until an extension ships a terminal
// view (mirroring the macOS registry, which also has no in-tree renderer): it
// proves the envelope was consumed and names which extensions are live without
// inventing payload-specific UI.
func (m Model) extensionRuntimeStatus() string {
	if len(m.extensionRuntimes) == 0 {
		return ""
	}
	ids := make([]string, 0, len(m.extensionRuntimes))
	for id := range m.extensionRuntimes {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return "ext " + strings.Join(ids, ",")
}

func (m Model) renderStatusMessage(message string) string {
	text, status, hasOperationPresentation := m.feedback.presentation()
	operationOwnsLane := hasOperationPresentation && (activeOperation(status) || message == "")
	foreground := m.palette().Warning()
	if operationOwnsLane {
		switch status {
		case generated.OperationStatusPending, generated.OperationStatusQueued:
			foreground = m.palette().ChromeText()
		case generated.OperationStatusRunning:
			foreground = m.palette().Accent()
		case generated.OperationStatusSuccess:
			foreground = m.palette().Hint()
		case generated.OperationStatusError:
			foreground = m.palette().Error()
		case generated.OperationStatusTimeout:
			foreground = m.palette().Warning()
		case generated.OperationStatusCanceled:
			foreground = m.palette().Muted()
		case generated.OperationStatusStale:
			foreground = m.palette().Info()
		}
	} else {
		text = message
	}
	text = sanitizeTerminalText(text)
	if text == "" {
		return ""
	}
	return lipgloss.NewStyle().Bold(true).Foreground(foreground).Background(m.palette().ChromeSurface()).Render(text)
}

func sanitizeTerminalText(text string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, ansi.Strip(text))
}

// modeColors returns the background and foreground colors for a vi mode pill
// badge based on the segment text content. The palette accessors (ModeNormal,
// ModeInsert, ModeVisual) fall back gracefully when theme slots are absent.
func (m Model) modeColors(text string) (bg, fg color.Color) {
	theme := m.palette()
	trimmed := strings.TrimSpace(strings.ToUpper(text))
	switch {
	case strings.Contains(trimmed, "INSERT"):
		return theme.ModeInsert(), theme.ModeInsertText()
	case strings.Contains(trimmed, "VISUAL"):
		return theme.ModeVisual(), theme.ModeVisualText()
	default:
		// NORMAL and any other/unknown mode get the normal treatment.
		return theme.ModeNormal(), theme.ModeNormalText()
	}
}

func (m Model) gitSummary(git protocol.GitStatus) string {
	parts := []string{"git " + git.Branch}
	if git.Syncing {
		parts = append(parts, "syncing")
	}
	if git.Ahead > 0 {
		parts = append(parts, fmt.Sprintf("ahead %d", git.Ahead))
	}
	if git.Behind > 0 {
		parts = append(parts, fmt.Sprintf("behind %d", git.Behind))
	}
	if len(git.Entries) > 0 {
		parts = append(parts, fmt.Sprintf("%d files", len(git.Entries)))
	}
	if git.Toast.Visible && git.Toast.Message != "" {
		parts = append(parts, git.Toast.Message)
	}
	return strings.Join(parts, gap(spaceXL))
}

func (m Model) renderGitStatusPanel(git protocol.GitStatus, style, selected lipgloss.Style, width, height int, hits *gitStatusHits) []string {
	lines := make([]string, height)
	if height == 0 {
		return lines
	}
	toast := git.Toast
	git.Toast.Visible = false
	title := m.gitSummary(git)
	switch {
	case git.RepoState == 1:
		title = "Not a Git repository"
	case git.RepoState == 2:
		title = "Loading Git status…"
	case len(git.Entries) == 0 && !git.Syncing:
		title += " · Clean"
	}
	lines[0] = style.Bold(true).Render(fit(title, width))
	startRow := 1
	if toast.Visible && toast.Action == 1 && toast.ID != 0 && height >= 4 {
		lines[startRow] = style.Bold(true).Render(fit("Pull & Retry (r)", width))
		if startRow < hits.box.Height {
			hits.retryID = toast.ID
			lines[startRow] = m.zones.Mark(zoneIDGitRetry, lines[startRow])
		}
		startRow++
	}
	cursor := int(git.TerminalCursor)
	start := max(cursor-(height-startRow)+1, 0)
	rank := 0
	drawRow := func(label string, entry *protocol.GitStatusEntry) {
		if i := rank - start + startRow; i >= startRow && i < height {
			rowStyle := style
			if rank == cursor {
				rowStyle = selected
			}
			line := rowStyle.Render(fit(label, width))
			if entry != nil && git.PanelID != 0 && i < hits.box.Height {
				if hits.rows == nil {
					hits.rows = make([]gitStatusRowTarget, 0, min(len(git.Entries), hits.box.Height-startRow))
				}
				line = m.zones.Mark(zoneIDGitStatusRow(i), line)
				hits.rows = append(hits.rows, gitStatusRowTarget{row: i, path: entry.Path, section: entry.Section})
			}
			lines[i] = line
		}
		rank++
	}

	var counts [4]int
	for _, entry := range git.Entries {
		if entry.Section < 4 {
			counts[entry.Section]++
		}
	}
	names := [4]string{"Staged", "Changes", "Untracked", "Conflicts"}
	for _, section := range [...]byte{3, 0, 1, 2} {
		if counts[section] == 0 || rank >= start+height-startRow {
			continue
		}
		marker := "▾ "
		collapsed := git.TerminalCollapsed&(1<<section) != 0
		if collapsed {
			marker = "▸ "
		}
		drawRow(fmt.Sprintf("%s%s (%d)", marker, names[section], counts[section]), nil)
		if !collapsed {
			for _, entry := range git.Entries {
				if rank >= start+height-startRow {
					break
				}
				if entry.Section == section {
					drawRow(gap(spaceXL)+entry.Path, &entry)
				}
			}
		}
	}
	for i := 1; i < len(lines); i++ {
		if lines[i] == "" {
			lines[i] = style.Render(strings.Repeat(" ", width))
		}
	}
	return lines
}

func (m Model) renderMinibuffer(mini protocol.Minibuffer) string {
	if mini.Mode == 10 && len(mini.Items) > 0 {
		return m.renderPromptChoices(mini)
	}
	prompt := mini.Prompt
	if prompt == "" {
		prompt = "> "
	}
	value := mini.Input
	if mini.Context != "" {
		value += gap(spaceXL) + mini.Context
	}
	return m.charmInput(prompt, value, mini.CursorPos)
}

// Completion rows carry semantic hit zones. Give items the available rows
// first, then committed documentation, then the frame and title.
func (m Model) renderCompletion(completion protocol.Completion, width, height int) []string {
	theme := m.palette()
	innerWidth, innerHeight := width, height
	itemRows := min(len(completion.Items), height)
	spareRows := height - itemRows
	doc := strings.TrimSpace(completion.Documentation)
	frameRows := 3
	if doc != "" && spareRows >= 2 {
		frameRows += 2 // Keep room for the documentation title and its first line.
	}
	framed := spareRows >= frameRows && width >= 3
	titleRows := 0
	var lines []string
	if framed {
		innerWidth -= 2
		innerHeight -= 2
		titleRows = 1
		titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(innerWidth).ColorWhitespace(true)
		lines = append(lines, renderPadded(titleStyle, " Completion", innerWidth))
	}

	// The doc pane renders for the BEAM-committed selection (two-index split:
	// highlight follows local preview, docs follow committed).
	docLines := []string(nil)
	if doc != "" {
		docLines = m.renderCompletionDocPane(doc, innerWidth, innerHeight-titleRows-itemRows)
	}

	rowBudget := innerHeight - titleRows - len(docLines)
	selected := m.effectiveCompletionIndex(completion)
	start := 0
	if selected >= rowBudget && rowBudget > 0 {
		start = selected - rowBudget + 1
	}
	end := min(start+rowBudget, len(completion.Items))
	for index := start; index < end; index++ {
		row := m.renderCompletionItemRow(completion.Items[index], index == selected, innerWidth)
		lines = append(lines, m.zones.Mark(zoneIDCompletionItem(index), row))
	}
	lines = append(lines, docLines...)
	if !framed {
		return lines
	}

	content := strings.Join(lines, "\n")
	bordered := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(theme.PopupBorder()).
		BorderBackground(theme.PopupSurface()).
		Background(theme.PopupSurface()).
		ColorWhitespace(true).
		Render(content)

	return strings.Split(bordered, "\n")
}

// renderCompletionDocPane renders the selected item's documentation as a titled,
// word-wrapped block below the completion list. The caller already reserves
// item rows before passing the available documentation budget.
func (m Model) renderCompletionDocPane(doc string, width int, budget int) []string {
	if budget < 2 {
		return nil
	}
	theme := m.palette()
	paneBudget := min(budget, 6)
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.PopupMutedText()).Background(theme.PopupChrome()).Width(width).ColorWhitespace(true)
	bodyStyle := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)

	lines := []string{renderPadded(titleStyle, gap(spaceXS)+"Documentation", width)}
	wrapped := lipgloss.NewStyle().Width(max(width-spaceXS.cols(), 1)).Render(doc)
	for _, line := range strings.Split(wrapped, "\n") {
		if len(lines) >= paneBudget {
			break
		}
		lines = append(lines, renderPadded(bodyStyle, gap(spaceXS)+line, width))
	}
	return lines
}

func (m Model) renderCompletionItemRow(item protocol.CompletionItem, selected bool, width int) string {
	theme := m.palette()
	rowBackground := theme.PopupSurface()
	rowForeground := theme.PopupText()
	if selected {
		rowBackground = theme.PopupSelection()
		rowForeground = theme.PopupSelectionText()
	}
	labelStyle := lipgloss.NewStyle().Foreground(rowForeground).Background(rowBackground).ColorWhitespace(true)
	if selected {
		labelStyle = labelStyle.Bold(true)
	}
	marker := " "
	if selected {
		marker = "▌"
	}
	markerStyle := lipgloss.NewStyle().Foreground(theme.Accent()).Background(rowBackground).ColorWhitespace(true)
	text := markerStyle.Render(marker) + labelStyle.Render(" "+item.Label)
	if strings.TrimSpace(item.Detail) != "" {
		text += lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(rowBackground).ColorWhitespace(true).Render(gap(listRowTitleToMeta) + strings.TrimSpace(item.Detail))
	}
	rowStyle := lipgloss.NewStyle().Background(rowBackground).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, text, width)
}

func (m Model) renderWhichKey(which protocol.WhichKey) []string {
	title := "Keys"
	if which.Prefix != "" {
		title += " " + which.Prefix
	}
	if which.PageCount > 1 {
		title += gap(spaceXL) + fmt.Sprintf("%d/%d", which.Page+1, which.PageCount)
	}
	items := make([]componentItem, 0, len(which.Bindings))
	for _, binding := range which.Bindings {
		label := strings.TrimSpace(binding.Icon + " " + binding.Description)
		items = append(items, componentItem{title: binding.Key, description: label})
	}
	return takeLines(m.charmList(title, items, 0, m.maxOverlayHeight(), true), m.maxOverlayHeight())
}

func (m Model) renderPicker(picker protocol.Picker, preview protocol.PickerPreview) []string {
	title := picker.Title
	if picker.Query != "" {
		title += gap(promptLabelToQuery) + picker.Query
	}
	if picker.Marked > 0 {
		title += gap(spaceXL) + fmt.Sprintf("marked %d", picker.Marked)
	}
	if picker.LoadStatus == 1 {
		title += gap(spaceXL) + m.feedback.spinner() + " loading"
	} else if picker.LoadStatus == 2 && picker.LoadError != "" {
		title += gap(spaceXL) + picker.LoadError
	}

	height := m.maxOverlayHeight()
	if preview.Visible && len(preview.Lines) > 0 && m.width >= 100 {
		return m.renderPickerWithSidePreview(title, picker, preview, height)
	}

	itemBudget := max(height-2, 1)
	if preview.Visible && len(preview.Lines) > 0 {
		itemBudget = max(itemBudget/2, 1)
	}
	lines := m.renderPickerList(title, picker, itemBudget+1, m.width)
	if preview.Visible && len(preview.Lines) > 0 {
		lines = append(lines, m.renderPickerPreview(preview, max(height-len(lines)-1, 1), m.width)...)
	}
	lines = append(lines, m.renderPickerHelp(picker, m.width))
	return takeLines(m.fillPopupLines(lines, height, m.width), height)
}

func (m Model) renderPickerList(title string, picker protocol.Picker, height int, width int) []string {
	theme := m.palette()
	panelStyle := m.popupLineStyle(width)
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(width).ColorWhitespace(true)
	lines := []string{renderPadded(titleStyle, " "+title, width)}
	headerRows := 1
	if height > 2 {
		sepStyle := lipgloss.NewStyle().Foreground(theme.PopupBorder()).Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)
		lines = append(lines, renderPadded(sepStyle, strings.Repeat("─", max(width, 1)), width))
		headerRows = 2
	}
	rowBudget := max(height-headerRows, 0)
	selected := m.effectivePickerIndex(picker)
	start, end, headers := pickerItemWindow(picker.Items, selected, rowBudget)
	activeSlot := pickerHasActiveItem(picker.Items[start:end])
	for index := start; index < end; index++ {
		item := picker.Items[index]
		if headers && pickerStartsSection(picker.Items, index, start) {
			lines = append(lines, m.renderPickerSectionHeader(item.Group, width))
		}
		row := m.renderPickerItemRow(title, item, index == selected, activeSlot, width)
		if slot := index - start; slot < len(m.zones.picker.items) && item.ActivationID != 0 {
			m.zones.picker.items[slot] = item.ActivationID
			row = m.zones.Mark(pickerPointerZone(slot), row)
		}
		lines = append(lines, row)
	}
	for len(lines) < height {
		lines = append(lines, panelStyle.Render(strings.Repeat(" ", max(width, 1))))
	}
	return lines
}

func (m Model) renderPickerItemRow(title string, item protocol.PickerItem, selected bool, activeSlot bool, width int) string {
	if item.HasStatus() {
		return m.renderPickerStatusRow(item, selected, activeSlot, width)
	}
	theme := m.palette()
	marker := " "
	if item.Marked {
		marker = "*"
	}
	if selected {
		marker = "▌"
	}
	detail := item.Description
	if detail == "" {
		detail = item.Annotation
	}
	icon := pickerItemIcon(title, item)
	rowBackground := theme.PopupSurface()
	rowForeground := theme.PopupText()
	if selected {
		rowBackground = theme.PopupSelection()
		rowForeground = theme.PopupSelectionText()
	}
	markerText := lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(rowBackground).ColorWhitespace(true).Render(marker)
	if selected {
		markerText = lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(rowBackground).ColorWhitespace(true).Render(marker)
	} else if item.Marked {
		markerText = lipgloss.NewStyle().Foreground(theme.Warning()).Background(rowBackground).ColorWhitespace(true).Render(marker)
	}
	labelStyle := lipgloss.NewStyle().Foreground(rowForeground).Background(rowBackground).ColorWhitespace(true)
	if selected {
		labelStyle = labelStyle.Bold(true)
	}
	text := markerText + labelStyle.Render(" ")
	if item.Active {
		text += lipgloss.NewStyle().Foreground(theme.Accent()).Background(rowBackground).ColorWhitespace(true).Render(pickerActiveGlyph) + labelStyle.Render(gap(listRowGlyphToTitle))
	} else if activeSlot {
		text += labelStyle.Render(strings.Repeat(" ", pickerActiveSlotWidth))
	}
	if icon.glyph != "" {
		if icon.color != "" && !selected {
			text += lipgloss.NewStyle().Foreground(lipgloss.Color(icon.color)).Background(rowBackground).ColorWhitespace(true).Render(icon.glyph)
		} else {
			text += labelStyle.Render(icon.glyph)
		}
		text += labelStyle.Render(" ")
	}
	text += labelStyle.Render(item.Label)
	if strings.TrimSpace(detail) != "" {
		text += lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(rowBackground).ColorWhitespace(true).Render(gap(listRowTitleToMeta) + strings.TrimSpace(detail))
	}
	rowStyle := lipgloss.NewStyle().Background(rowBackground).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, " "+text, width)
}

func (m Model) renderPickerWithSidePreview(title string, picker protocol.Picker, preview protocol.PickerPreview, height int) []string {
	dividerWidth := 1
	leftWidth := min(max(m.width*42/100, 36), max(m.width-20-dividerWidth, 1))
	rightWidth := max(m.width-leftWidth-dividerWidth, 1)
	bodyHeight := max(height-1, 1)
	left := m.renderPickerList(title, picker, bodyHeight, leftWidth)
	right := m.renderPickerPreview(preview, bodyHeight, rightWidth)
	left = m.fillPopupLines(left, bodyHeight, leftWidth)
	right = m.fillPopupLines(right, bodyHeight, rightWidth)
	lines := make([]string, 0, height)
	leftStyle := lipgloss.NewStyle().Width(leftWidth).Background(m.palette().PopupSurface()).ColorWhitespace(true)
	divider := lipgloss.NewStyle().Foreground(m.palette().PopupBorder()).Background(m.palette().PopupSurface()).Render("│")
	for i := 0; i < bodyHeight; i++ {
		lines = append(lines, lipgloss.JoinHorizontal(lipgloss.Top, leftStyle.Render(left[i]), divider, right[i]))
	}
	lines = append(lines, m.renderPickerHelp(picker, m.width))
	return lines
}

func (m Model) renderPickerHelp(picker protocol.Picker, width int) string {
	p := m.palette()
	selected := 0
	if len(picker.Items) > 0 {
		selected = min(max(int(picker.Selected)+1, 1), len(picker.Items))
	}
	left := fmt.Sprintf(" %d/%d", selected, len(picker.Items))
	right := strings.Join([]string{"↑↓ move", "Enter choose", "Esc close"}, gap(spaceXL))
	textStyle := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).ColorWhitespace(true)
	leftText := textStyle.Render(left)
	rightText := textStyle.Render(right)
	if remedy := m.selectedPickerRemedy(picker); remedy != "" {
		// An unusable row's description says why and what to do; the key hints give way to it.
		room := max(width-lipgloss.Width(leftText)-pickerStatusGap-1, 1)
		rightText = lipgloss.NewStyle().Foreground(p.PopupText()).Background(p.PopupChrome()).ColorWhitespace(true).Render(ansi.TruncateWc(remedy, room, "…") + " ")
		leftText += textStyle.Render(strings.Repeat(" ", pickerStatusGap))
		rowStyle := lipgloss.NewStyle().Background(p.PopupChrome()).Width(width).ColorWhitespace(true)
		return renderPadded(rowStyle, leftText+rightText, width)
	}
	spacer := textStyle.Render(strings.Repeat(" ", max(width-lipgloss.Width(leftText)-lipgloss.Width(rightText), 0)))
	rowStyle := lipgloss.NewStyle().Background(p.PopupChrome()).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, leftText+spacer+rightText, width)
}

// selectedPickerRemedy returns the selected row's description when its status chip is an error, such as
// an unavailable model route whose description carries the remedy. Otherwise it returns "".
func (m Model) selectedPickerRemedy(picker protocol.Picker) string {
	index := m.effectivePickerIndex(picker)
	if index < 0 || index >= len(picker.Items) {
		return ""
	}
	item := picker.Items[index]
	if !item.HasStatus() || item.StatusTone != generated.PickerStatusToneError {
		return ""
	}
	return strings.TrimSpace(item.Description)
}

func (m Model) renderPickerPreview(preview protocol.PickerPreview, height int, width int) []string {
	theme := m.palette()
	style := m.popupLineStyle(width)
	first := 1
	if height == 1 && len(preview.Lines) == 1 {
		// A short overlay can still show a complete one-row preview.
		first = 0
	}
	limit := min(len(preview.Lines), max(height-first, 0))
	lines := make([]string, 0, height)
	if first != 0 {
		titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(width).ColorWhitespace(true)
		lines = append(lines, renderPadded(titleStyle, " Preview", width))
	}
	for _, line := range preview.Lines[:limit] {
		var builder strings.Builder
		builder.WriteString(lipgloss.NewStyle().Background(theme.PopupSurface()).ColorWhitespace(true).Render(" "))
		for _, segment := range line.Segments {
			segmentStyle := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).ColorWhitespace(true)
			if segment.FG != 0 {
				segmentStyle = segmentStyle.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", segment.FG)))
			}
			if segment.Bold {
				segmentStyle = segmentStyle.Bold(true)
			}
			builder.WriteString(segmentStyle.Render(segment.Text))
		}
		lines = append(lines, renderPadded(style, builder.String(), width))
	}
	return m.fillPopupLines(lines, height, width)
}

func (m Model) popupLineStyle(width int) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(m.palette().PopupText()).Background(m.palette().PopupSurface()).Width(width).ColorWhitespace(true)
}

func (m Model) fillPopupLines(lines []string, height int, width int) []string {
	style := m.popupLineStyle(width)
	out := make([]string, 0, height)
	for _, line := range lines[:min(len(lines), height)] {
		out = append(out, renderPadded(style, line, width))
	}
	for len(out) < height {
		out = append(out, renderPadded(style, "", width))
	}
	return out
}

func renderPadded(style lipgloss.Style, value string, width int) string {
	return style.Render(fitStyledWithPad(value, width, style))
}

func fitStyledWithPad(value string, width int, padStyle lipgloss.Style) string {
	if width <= 0 {
		return ""
	}
	value = lipgloss.NewStyle().Inline(true).MaxWidth(width).Render(value)
	visible := lipgloss.Width(value)
	if visible >= width {
		return value
	}
	return value + padStyle.Render(strings.Repeat(" ", width-visible))
}
