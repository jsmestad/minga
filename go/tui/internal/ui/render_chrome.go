package ui

import (
	"fmt"
	"sort"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const maxTabLabelWidth = 24

func (m Model) headerLines() []string {
	lines := []string{}
	if spaces, ok := m.workspaceBar(); ok && len(spaces.Spaces) > 0 {
		lines = append(lines, m.renderWorkspaces(spaces))
	}
	if tabBar, ok := m.tabBar(); ok && len(tabBar.Tabs) > 0 {
		lines = append(lines, m.renderTabs(tabBar))
		lines = append(lines, lipgloss.NewStyle().Foreground(m.palette().TreeSeparator()).Background(m.palette().EditorSurface()).Width(m.width).Render(strings.Repeat("─", m.width)))
	}
	if crumb, ok := m.breadcrumb(); ok && len(crumb.Segments) > 0 && m.width >= 100 {
		lines = append(lines, m.renderBreadcrumb(crumb))
	}
	if len(lines) == 0 {
		title := m.title
		if title == "" {
			title = "Minga"
		}
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(m.palette().Accent()).Background(m.palette().Surface()).Width(m.width).Render(title))
	}
	return lines
}

func (m Model) renderWorkspaces(spaces protocol.WorkspaceBar) string {
	theme := m.palette()
	rowStyle := lipgloss.NewStyle().Background(theme.EditorSurface()).Width(m.width)
	labelStyle := lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.EditorSurface())
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.EditorSurface())
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(theme.EditorSurface())
	metaStyle := lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.EditorSurface())
	alertStyle := lipgloss.NewStyle().Foreground(theme.Warning()).Background(theme.EditorSurface())
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
	return rowStyle.Render(fitStyled(strings.Join(rendered, separator), m.width))
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

func (m Model) renderTabs(tabBar protocol.TabBar) string {
	theme := m.palette()
	rowStyle := lipgloss.NewStyle().Background(theme.Surface()).Width(m.width)
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.TabActiveText()).Background(theme.TabActive()).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(theme.Surface()).Padding(0, 1)
	dirtyStyle := lipgloss.NewStyle().Foreground(theme.TabDirty()).Background(theme.TabActive())
	rendered := make([]string, 0, len(tabBar.Tabs))
	for _, tab := range tabBar.Tabs {
		icon := tabIcon(tab)
		iconText := icon.glyph
		iconBackground := theme.Surface()
		if tab.Active {
			iconBackground = theme.TabActive()
		}
		if icon.color != "" {
			iconText = lipgloss.NewStyle().Foreground(lipgloss.Color(icon.color)).Background(iconBackground).Render(icon.glyph)
		}
		tabLabel := ansi.TruncateWc(tab.Label, maxTabLabelWidth, "…")
		label := strings.TrimSpace(iconText + " " + tabLabel)
		if tab.Active {
			label = lipgloss.NewStyle().Foreground(theme.Accent()).Background(theme.TabActive()).Render("▌") + " " + label
		}
		if tab.Dirty {
			label += dirtyStyle.Render(" *")
		}
		if tab.Attention {
			label += lipgloss.NewStyle().Foreground(theme.TabAttention()).Background(theme.Surface()).Render(" !")
		}
		style := inactiveStyle
		if tab.Active {
			style = activeStyle
		} else if tab.Tint != 0 {
			style = style.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", tab.Tint&0xFFFFFF)))
		}
		rendered = append(rendered, m.zones.Mark(zoneIDTab(tab.ID), style.Render(label)))
	}
	return rowStyle.Render(fitStyled(strings.Join(rendered, " "), m.width))
}

func (m Model) renderBreadcrumb(crumb protocol.Breadcrumb) string {
	segments := make([]string, 0, len(crumb.Segments))
	for index, segment := range crumb.Segments {
		style := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().EditorSurface())
		if index == len(crumb.Segments)-1 {
			style = style.Foreground(m.palette().Text())
		}
		segments = append(segments, m.zones.Mark(zoneIDBreadcrumbSegment(index), style.Render(segment)))
	}
	separator := lipgloss.NewStyle().Foreground(m.palette().GutterText()).Background(m.palette().EditorSurface()).Render(" ❯ ")
	text := "  " + strings.Join(segments, separator)
	if git, ok := m.gitStatus(); ok && git.Branch != "" {
		gitText := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().EditorSurface()).Render("  ·  " + m.gitSummary(git))
		if lipgloss.Width(text)+lipgloss.Width(gitText) <= m.width {
			text += gitText
		}
	}
	return lipgloss.NewStyle().Background(m.palette().EditorSurface()).Width(m.width).Render(fitStyled(text, m.width))
}

func (m Model) footerLines() []string {
	status := fmt.Sprintf("row %d col %d", m.cursorRow+1, m.cursorCol+1)
	if chromeStatus, ok := m.statusBar(); ok {
		if len(chromeStatus.Left) > 0 || len(chromeStatus.Right) > 0 {
			status = m.renderStatusSegments(chromeStatus)
		} else if chromeStatus.Filename != "" {
			icon := devIconForPath(chromeStatus.Filename, false)
			prefix := chromeStatus.Filename
			if icon.glyph != "" {
				prefix = icon.glyph + " " + chromeStatus.Filename
			}
			status = fmt.Sprintf("%s  %d:%d", prefix, chromeStatus.Line, chromeStatus.Column)
			if chromeStatus.Message != "" {
				status += "  " + chromeStatus.Message
			}
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
	leftWidth := lipgloss.Width(left)
	rightWidth := lipgloss.Width(right)
	messageWidth := lipgloss.Width(message)
	available := max(m.width-leftWidth-rightWidth, 1)
	if messageWidth > available {
		message = m.renderStatusMessage(fit(status.Message, available))
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
	if message == "" {
		return ""
	}
	displayed := m.feedback.formatMessage(message)
	return lipgloss.NewStyle().Bold(true).Foreground(m.palette().Warning()).Background(m.palette().ChromeSurface()).Render(displayed)
}

func (m Model) renderSegmentList(segments []protocol.StatusSegment) string {
	sep := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().ChromeSurface()).Render("│")
	parts := make([]string, 0, len(segments))
	for _, segment := range segments {
		text := segment.Text
		if text == "" {
			continue
		}
		style := lipgloss.NewStyle().Foreground(m.palette().ChromeText()).Background(m.palette().ChromeSurface())
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
func (m Model) renderCompletion(completion protocol.Completion) []string {
	height := m.maxOverlayHeight()
	width := max(m.width, 1)
	theme := m.palette()
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupChrome()).Width(width).ColorWhitespace(true)
	lines := []string{renderPadded(titleStyle, " Completion", width)}

	// The doc pane renders for the BEAM-committed selection (two-index split:
	// highlight follows local preview, docs follow committed).
	doc := strings.TrimSpace(completion.Documentation)
	docLines := []string(nil)
	if doc != "" {
		docLines = m.renderCompletionDocPane(doc, width, height-1)
		if height-1-len(docLines) < 1 {
			docLines = nil
		}
	}

	rowBudget := max(height-1-len(docLines), 0)
	selected := m.effectiveCompletionIndex(completion)
	start := 0
	if selected >= rowBudget && rowBudget > 0 {
		start = selected - rowBudget + 1
	}
	end := min(start+rowBudget, len(completion.Items))
	for index := start; index < end; index++ {
		row := m.renderCompletionItemRow(completion.Items[index], index == selected, width)
		lines = append(lines, m.zones.Mark(zoneIDCompletionItem(index), row))
	}
	lines = append(lines, docLines...)
	return takeLines(lines, height)
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
	rowBudget := max(height-1, 0)
	selected := min(max(int(picker.Selected), 0), max(len(picker.Items)-1, 0))
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
