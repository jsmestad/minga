package ui

import (
	"fmt"
	"image/color"
	"sort"
	"strings"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const maxTabLabelWidth = 24

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

	lines := []string{}
	if spaces, ok := m.workspaceBar(); ok && len(spaces.Spaces) > 1 {
		lines = append(lines, m.renderWorkspaces(spaces, mainWidth))
	}
	if tabBar, ok := m.tabBar(); ok && len(tabBar.Tabs) > 0 {
		lines = append(lines, m.renderTabs(tabBar, mainWidth))
	}
	if crumb, ok := m.breadcrumb(); ok && len(crumb.Segments) > 0 && m.width >= 100 {
		lines = append(lines, m.renderBreadcrumb(crumb, mainWidth))
	}
	if len(lines) == 0 {
		title := m.title
		if title == "" {
			title = "Minga"
		}
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(m.palette().Accent()).Background(m.palette().Surface()).Width(mainWidth).Render(title))
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
			left = fillStyle.Render(strings.Repeat(" ", max(sidebarWidth-1, 1)))
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
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.TabActiveText()).Background(editorBG).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(chromeBG).Padding(0, 1)
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
		segments = append(segments, m.zones.Mark(zoneIDBreadcrumbSegment(index), style.Render(segment)))
	}
	separator := lipgloss.NewStyle().Foreground(m.palette().BreadcrumbSeparator()).Background(bg).Render(" ❯ ")
	text := "  " + strings.Join(segments, separator)
	if git, ok := m.gitStatus(); ok && git.Branch != "" {
		gitText := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(bg).Render("  ·  " + m.gitSummary(git))
		if lipgloss.Width(text)+lipgloss.Width(gitText) <= width {
			text += gitText
		}
	}
	return lipgloss.NewStyle().Background(bg).Width(width).Render(fitStyled(text, width))
}

func (m Model) footerLines() []string {
	status := fmt.Sprintf("row %d col %d", m.cursorRow+1, m.cursorCol+1)
	if chromeStatus, ok := m.statusBar(); ok {
		if len(chromeStatus.Left) > 0 || len(chromeStatus.Right) > 0 || chromeStatus.PendingKeys != "" {
			status = m.renderStatusSegments(chromeStatus)
		} else if chromeStatus.Filename != "" {
			icon := devIconForPath(chromeStatus.Filename, false)
			prefix := chromeStatus.Filename
			if icon.glyph != "" {
				prefix = icon.glyph + " " + chromeStatus.Filename
			}
			status = fmt.Sprintf("%s  %d:%d", prefix, chromeStatus.Line, chromeStatus.Column)
			if message := m.renderStatusMessage(chromeStatus.Message); message != "" {
				status += "  " + message
			}
		} else if message := m.renderStatusMessage(chromeStatus.Message); message != "" {
			status = message
		}
	}
	if m.lastError != "" {
		status = m.lastError
	}
	if search, ok := m.searchState(); ok && search.Active {
		status += fmt.Sprintf("  search %d/%d", search.CurrentIndex, search.Count)
	}
	if changes, ok := m.changeSummary(); ok && changes.Visible && len(changes.Entries) > 0 {
		status += fmt.Sprintf("  changes %d", len(changes.Entries))
	}
	if ext := m.extensionRuntimeStatus(); ext != "" {
		status += "  " + ext
	}
	if m.resyncPending {
		// A frame transaction was discarded and the model asked the BEAM for a
		// keyframe (#2219). Surface a subtle indicator while it waits so a stalled
		// resync is visible without competing with real status content; it clears
		// when a valid commit applies. Styled with the muted error tone at low
		// intensity rather than the loud full-screen surface.
		badge := lipgloss.NewStyle().Faint(true).Foreground(m.palette().Warning()).Background(m.palette().Base()).Render("resync…")
		status += "  " + badge
	}
	lines := []string{
		lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().Base()).Width(m.width).Render(fitStyled(status, m.width)),
	}
	// The single active secondary overlay is no longer footer-appended here: it is
	// composited at its BEAM placement rect by overlayLayer (#2281). The footer
	// still carries the minibuffer when no full overlay is active so the prompt
	// line stays in the vertical layout.
	if !m.modalOverlayActive() {
		if _, active := m.overlayWinner(); !active {
			if mini, ok := m.minibuffer(); ok && mini.Visible {
				lines = append(lines, m.renderMinibuffer(mini))
			}
		}
	}
	return lines
}

func (m Model) renderStatusSegments(status protocol.StatusBar) string {
	left := m.renderSegmentList(status.Left)
	right := m.renderSegmentList(status.Right)
	message := m.renderStatusMessage(status.Message)
	// Prepend a devicon for the current file type before the right segments.
	if status.Filename != "" {
		icon := devIconForPath(status.Filename, false)
		if icon.glyph != "" {
			fileStyle := lipgloss.NewStyle().Foreground(m.palette().ChromeText()).Background(m.palette().ChromeSurface())
			if icon.color != "" {
				fileStyle = fileStyle.Foreground(lipgloss.Color(icon.color))
			}
			right = fileStyle.Render(icon.glyph+" ") + right
		}
	}
	// showcmd: echo the pending key sequence as a dim, right-aligned segment so
	// every keypress is acknowledged instantly (issue #2666). Rendered leftmost
	// within the right cluster; the BEAM clears it (empty string) when the
	// sequence resolves, aborts, or which-key opens, so no timer lives here.
	if status.PendingKeys != "" {
		pending := lipgloss.NewStyle().Faint(true).Foreground(m.palette().Muted()).Background(m.palette().ChromeSurface()).Render(status.PendingKeys + "  ")
		right = pending + right
	}
	leftWidth := lipgloss.Width(left)
	rightWidth := lipgloss.Width(right)
	messageWidth := lipgloss.Width(message)
	available := max(m.width-leftWidth-rightWidth, 1)
	if messageWidth > available {
		// Feedback decoration and metadata are already styled. Truncate that one
		// finalized value so narrow widths cannot fall back to the raw notice.
		message = fitStyled(message, available)
		messageWidth = lipgloss.Width(message)
	}
	leftSpacer := strings.Repeat(" ", max((available-messageWidth)/2, 0))
	rightSpacer := strings.Repeat(" ", max(available-messageWidth-lipgloss.Width(leftSpacer), 0))
	spacerStyle := lipgloss.NewStyle().Background(m.palette().ChromeSurface())
	return left + spacerStyle.Render(leftSpacer) + message + spacerStyle.Render(rightSpacer) + right
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

func (m Model) renderSegmentList(segments []protocol.StatusSegment) string {
	sep := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().ChromeSurface()).Render("│")
	parts := make([]string, 0, len(segments))
	theme := m.palette()
	for _, segment := range segments {
		text := segment.Text
		if text == "" {
			continue
		}
		style := lipgloss.NewStyle().Foreground(theme.ChromeText()).Background(theme.ChromeSurface())

		// Apply semantic styling based on segment name. Mode segments become
		// colored pill badges; info segments use the modeline-info palette;
		// other segments can inherit the statusbar accent for bold emphasis.
		// Inline FG/BG from the BEAM still win when present so the editor can
		// override theme defaults per-segment.
		switch segment.Name {
		case "mode":
			bg, fg := m.modeColors(text)
			style = style.Background(bg).Foreground(fg).Bold(true)
		case "info":
			style = style.Background(theme.ModelineInfo()).Foreground(theme.ModelineInfoText())
		default:
			if segment.Attrs&0x01 != 0 && segment.FG == 0 {
				style = style.Foreground(theme.StatusbarAccent())
			}
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
		// Prepend a nerd font icon when the segment carries a vi mode name.
		if icon := modeIcon(strings.TrimSpace(text)); icon != "" {
			text = strings.Replace(text, strings.TrimSpace(text), icon+" "+strings.TrimSpace(text), 1)
		}
		rendered := style.Render(text)
		if segment.Command != "" {
			rendered = m.zones.Mark(zoneIDModelineCommand(segment.Command), rendered)
		}
		parts = append(parts, rendered)
	}
	return strings.Join(parts, sep)
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
	return strings.Join(parts, "  ")
}

func (m Model) renderGitStatus(git protocol.GitStatus) string {
	return lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().SurfaceAlt()).Width(m.width).Render(fit(m.gitSummary(git), m.width))
}

func (m Model) renderMinibuffer(mini protocol.Minibuffer) string {
	prompt := mini.Prompt
	if prompt == "" {
		prompt = "> "
	}
	value := mini.Input
	if mini.Context != "" {
		value += "  " + mini.Context
	}
	return m.charmInput(prompt, value, mini.CursorPos)
}

// renderCompletion draws the completion popup as directly-styled rows rather
// than a charm list so each row can carry a lipgloss zone marker. Mouse routing
// (semantic_mouse.go) maps a row click to completion_select, matching the GUI
// (CompletionOverlay.swift:93); the visual stays a titled, selectable list.
// The content is wrapped in a rounded border matching the picker/which-key
// treatment (#2534): PopupBorder foreground, PopupSurface background,
// BorderBackground, and ColorWhitespace so the border band stays solid.
func (m Model) renderCompletion(completion protocol.Completion) []string {
	height := m.maxOverlayHeight()
	width := max(m.width, 1)
	theme := m.palette()

	// Reserve space for the rounded border: 2 columns (left+right) and 2 rows
	// (top+bottom). Inner content renders inside the border box.
	innerWidth := max(width-2, 1)
	innerHeight := max(height-2, 0)

	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(innerWidth).ColorWhitespace(true)
	lines := []string{renderPadded(titleStyle, " Completion", innerWidth)}

	// The doc pane renders for the BEAM-committed selection (two-index split:
	// highlight follows local preview, docs follow committed).
	doc := strings.TrimSpace(completion.Documentation)
	docLines := []string(nil)
	if doc != "" {
		docLines = m.renderCompletionDocPane(doc, innerWidth, innerHeight-1)
		// The pane must never starve the item list: at extreme overlay
		// heights, showing the item being selected beats showing its docs.
		if innerHeight-1-len(docLines) < 1 {
			docLines = nil
		}
	}

	rowBudget := max(innerHeight-1-len(docLines), 0)
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
	lines = takeLines(lines, innerHeight)

	// Wrap inner content in a rounded border matching the picker/which-key style.
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
// word-wrapped block below the completion list. It caps itself at roughly half
// the remaining overlay budget so the item list stays usable; markdown is shown
// as plain styled text for v1 (matching the GUI preview's plain rendering).
func (m Model) renderCompletionDocPane(doc string, width int, budget int) []string {
	if budget < 2 {
		return nil
	}
	theme := m.palette()
	paneBudget := max(min(budget/2, 6), 2)
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.PopupMutedText()).Background(theme.PopupChrome()).Width(width).ColorWhitespace(true)
	bodyStyle := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)

	lines := []string{renderPadded(titleStyle, " Documentation", width)}
	wrapped := lipgloss.NewStyle().Width(max(width-1, 1)).Render(doc)
	for _, line := range strings.Split(wrapped, "\n") {
		if len(lines) >= paneBudget {
			break
		}
		lines = append(lines, renderPadded(bodyStyle, " "+line, width))
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
		text += lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(rowBackground).ColorWhitespace(true).Render("  " + strings.TrimSpace(item.Detail))
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
		title += fmt.Sprintf("  %d/%d", which.Page+1, which.PageCount)
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
		title += "  " + picker.Query
	}
	if picker.Marked > 0 {
		title += fmt.Sprintf("  marked %d", picker.Marked)
	}
	if picker.LoadStatus == 1 {
		title += "  " + m.feedback.spinner() + " loading"
	} else if picker.LoadStatus == 2 && picker.LoadError != "" {
		title += "  " + picker.LoadError
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
	start := 0
	if selected >= rowBudget && rowBudget > 0 {
		start = selected - rowBudget + 1
	}
	end := min(start+rowBudget, len(picker.Items))
	for index := start; index < end; index++ {
		lines = append(lines, m.renderPickerItemRow(title, picker.Items[index], index == selected, width))
	}
	for len(lines) < height {
		lines = append(lines, panelStyle.Render(strings.Repeat(" ", max(width, 1))))
	}
	return lines
}

func (m Model) renderPickerItemRow(title string, item protocol.PickerItem, selected bool, width int) string {
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
		text += lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(rowBackground).ColorWhitespace(true).Render("  " + strings.TrimSpace(detail))
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
	right := "↑↓ move  Enter choose  Esc close"
	textStyle := lipgloss.NewStyle().Foreground(p.PopupMutedText()).Background(p.PopupChrome()).ColorWhitespace(true)
	leftText := textStyle.Render(left)
	rightText := textStyle.Render(right)
	spacer := textStyle.Render(strings.Repeat(" ", max(width-lipgloss.Width(leftText)-lipgloss.Width(rightText), 0)))
	rowStyle := lipgloss.NewStyle().Background(p.PopupChrome()).Width(width).ColorWhitespace(true)
	return renderPadded(rowStyle, leftText+spacer+rightText, width)
}

func (m Model) renderPickerPreview(preview protocol.PickerPreview, height int, width int) []string {
	theme := m.palette()
	style := m.popupLineStyle(width)
	limit := min(len(preview.Lines), max(height-1, 0))
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(width).ColorWhitespace(true)
	lines := []string{renderPadded(titleStyle, " Preview", width)}
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
