package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m Model) headerLines() []string {
	lines := []string{}
	if spaces, ok := m.workspaceBar(); ok && len(spaces.Spaces) > 0 {
		lines = append(lines, m.renderWorkspaces(spaces))
	}
	if tabBar, ok := m.tabBar(); ok && len(tabBar.Tabs) > 0 {
		lines = append(lines, m.renderTabs(tabBar))
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
	rowStyle := lipgloss.NewStyle().Background(theme.SurfaceAlt()).Width(m.width)
	labelStyle := lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.SurfaceAlt()).Padding(0, 1)
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.TabActiveText()).Background(theme.Surface()).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(theme.SurfaceAlt()).Padding(0, 1)
	alertStyle := lipgloss.NewStyle().Foreground(theme.Warning()).Background(theme.SurfaceAlt())
	rendered := []string{labelStyle.Render("workspace")}
	for _, space := range spaces.Spaces {
		label := strings.TrimSpace(space.Icon + " " + space.Label)
		if space.TabCount > 0 {
			label += fmt.Sprintf(" %d", space.TabCount)
		}
		if space.DraftCount > 0 {
			label += alertStyle.Render(fmt.Sprintf(" D%d", space.DraftCount))
		}
		if space.ConflictCount > 0 {
			label += alertStyle.Render(fmt.Sprintf(" C%d", space.ConflictCount))
		}
		if space.BackgroundCount > 0 {
			label += alertStyle.Render(fmt.Sprintf(" B%d", space.BackgroundCount))
		}
		if space.Attention {
			label += alertStyle.Render(" !")
		}
		style := inactiveStyle
		if space.Active {
			style = activeStyle
		}
		rendered = append(rendered, style.Render(label))
	}
	return rowStyle.Render(fitStyled(strings.Join(rendered, " "), m.width))
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
		label := strings.TrimSpace(iconText + " " + tab.Label)
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
		rendered = append(rendered, style.Render(label))
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
		segments = append(segments, style.Render(segment))
	}
	separator := lipgloss.NewStyle().Foreground(m.palette().GutterText()).Background(m.palette().EditorSurface()).Render(" › ")
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
			status = fmt.Sprintf("%s  %d:%d", chromeStatus.Filename, chromeStatus.Line, chromeStatus.Column)
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
	lines := []string{
		lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().Base()).Width(m.width).Render(fitStyled(status, m.width)),
	}
	if !m.pickerVisible() && !m.whichKeyVisible() && !m.agentChatVisible() {
		overlay := m.overlayLines()
		if len(overlay) > 0 {
			lines = append(lines, overlay...)
		} else if mini, ok := m.minibuffer(); ok && mini.Visible {
			lines = append(lines, m.renderMinibuffer(mini))
		}
	}
	return lines
}

func (m Model) renderStatusSegments(status protocol.StatusBar) string {
	left := m.renderSegmentList(status.Left)
	right := m.renderSegmentList(status.Right)
	message := m.renderStatusMessage(status.Message)
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
	spacerStyle := lipgloss.NewStyle().Background(m.palette().Base())
	return left + spacerStyle.Render(leftSpacer) + message + spacerStyle.Render(rightSpacer) + right
}

func (m Model) renderStatusMessage(message string) string {
	if message == "" {
		return ""
	}
	return lipgloss.NewStyle().Bold(true).Foreground(m.palette().Warning()).Background(m.palette().Base()).Render(message)
}

func (m Model) renderSegmentList(segments []protocol.StatusSegment) string {
	parts := make([]string, 0, len(segments))
	for _, segment := range segments {
		text := segment.Text
		if text == "" {
			continue
		}
		style := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().Base())
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
		rendered := style.Render(text)
		if segment.Command != "" {
			rendered = m.zones.Mark(zoneIDModelineCommand(segment.Command), rendered)
		}
		parts = append(parts, rendered)
	}
	return strings.Join(parts, "")
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

func (m Model) renderCompletion(completion protocol.Completion) []string {
	items := make([]componentItem, 0, len(completion.Items))
	for _, item := range completion.Items {
		items = append(items, componentItem{title: item.Label, description: item.Detail})
	}
	return takeLines(m.charmList("Completion", items, int(completion.Selected), m.maxOverlayHeight(), true), m.maxOverlayHeight())
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
		title += "  loading"
	} else if picker.LoadStatus == 2 && picker.LoadError != "" {
		title += "  " + picker.LoadError
	}

	height := m.maxOverlayHeight()
	if preview.Visible && len(preview.Lines) > 0 && m.width >= 100 {
		return m.renderPickerWithSidePreview(title, picker, preview, height)
	}

	itemBudget := max(height-1, 1)
	if preview.Visible && len(preview.Lines) > 0 {
		itemBudget = max(itemBudget/2, 1)
	}
	lines := m.renderPickerList(title, picker, itemBudget+1, m.width)
	if picker.ActionVisible && len(picker.Actions) > 0 {
		lines = append(lines, m.popupLineStyle(m.width).Foreground(m.palette().Muted()).Render(fit(strings.Join(picker.Actions, "  "), m.width)))
	}
	if preview.Visible && len(preview.Lines) > 0 {
		lines = append(lines, m.renderPickerPreview(preview, max(height-len(lines), 1), m.width)...)
	}
	return takeLines(m.fillPopupLines(lines, height, m.width), height)
}

func (m Model) renderPickerList(title string, picker protocol.Picker, height int, width int) []string {
	theme := m.palette()
	panelStyle := m.popupLineStyle(width)
	titleStyle := panelStyle.Bold(true).Foreground(theme.Accent())
	lines := []string{titleStyle.Render(fit(title, width))}
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
	detail := item.Description
	if detail == "" {
		detail = item.Annotation
	}
	icon := pickerItemIcon(title, item)
	iconText := icon.glyph
	iconBackground := m.palette().PopupSurface()
	if selected {
		iconBackground = theme.Selection()
	}
	if icon.color != "" {
		iconText = lipgloss.NewStyle().Foreground(lipgloss.Color(icon.color)).Background(iconBackground).Render(icon.glyph)
	}
	text := strings.TrimSpace(marker + " " + iconText + " " + item.Label)
	if strings.TrimSpace(detail) != "" {
		text += "  " + strings.TrimSpace(detail)
	}
	style := m.popupLineStyle(width)
	if selected {
		style = style.Bold(true).Foreground(theme.SelectionText()).Background(theme.Selection())
	}
	return style.Render(fit(text, width))
}

func (m Model) renderPickerWithSidePreview(title string, picker protocol.Picker, preview protocol.PickerPreview, height int) []string {
	leftWidth := min(max(m.width*45/100, 36), max(m.width-20, 1))
	rightWidth := max(m.width-leftWidth, 1)
	left := m.renderPickerList(title, picker, height, leftWidth)
	right := m.renderPickerPreview(preview, height, rightWidth)
	left = m.fillPopupLines(left, height, leftWidth)
	right = m.fillPopupLines(right, height, rightWidth)
	lines := make([]string, 0, height)
	leftStyle := lipgloss.NewStyle().Width(leftWidth).Background(m.palette().PopupSurface())
	for i := 0; i < height; i++ {
		lines = append(lines, lipgloss.JoinHorizontal(lipgloss.Top, leftStyle.Render(left[i]), right[i]))
	}
	return lines
}

func (m Model) renderPickerPreview(preview protocol.PickerPreview, height int, width int) []string {
	theme := m.palette()
	style := m.popupLineStyle(width)
	limit := min(len(preview.Lines), max(height-1, 0))
	lines := []string{style.Bold(true).Foreground(theme.Accent()).Render(fit("Preview", width))}
	for _, line := range preview.Lines[:limit] {
		var builder strings.Builder
		for _, segment := range line.Segments {
			segmentStyle := lipgloss.NewStyle().Background(theme.PopupSurface())
			if segment.FG != 0 {
				segmentStyle = segmentStyle.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", segment.FG)))
			}
			if segment.Bold {
				segmentStyle = segmentStyle.Bold(true)
			}
			builder.WriteString(segmentStyle.Render(segment.Text))
		}
		lines = append(lines, style.Render(fitStyled(builder.String(), width)))
	}
	return m.fillPopupLines(lines, height, width)
}

func (m Model) popupLineStyle(width int) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(m.palette().PopupText()).Background(m.palette().PopupSurface()).Width(width)
}

func (m Model) fillPopupLines(lines []string, height int, width int) []string {
	style := m.popupLineStyle(width)
	out := make([]string, 0, height)
	for _, line := range lines[:min(len(lines), height)] {
		out = append(out, style.Render(fitStyled(line, width)))
	}
	for len(out) < height {
		out = append(out, style.Render(strings.Repeat(" ", max(width, 1))))
	}
	return out
}
