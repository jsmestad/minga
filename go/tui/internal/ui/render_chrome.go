package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
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
	if git, ok := m.gitStatus(); ok && git.Branch != "" {
		lines = append(lines, m.renderGitStatus(git))
	}
	if len(lines) == 0 {
		title := m.title
		if title == "" {
			title = "Minga"
		}
		if crumb, ok := m.breadcrumb(); ok && len(crumb.Segments) > 0 {
			title += "  " + strings.Join(crumb.Segments, " / ")
		}
		lines = append(lines, lipgloss.NewStyle().Bold(true).Foreground(m.palette().Accent()).Background(m.palette().Surface()).Width(m.width).Render(title))
	}
	return lines
}

func (m Model) renderWorkspaces(spaces protocol.WorkspaceBar) string {
	theme := m.palette()
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.TabActiveText()).Background(theme.Selection()).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(theme.SurfaceAlt()).Padding(0, 1)
	alertStyle := lipgloss.NewStyle().Foreground(theme.Warning())
	rendered := make([]string, 0, len(spaces.Spaces))
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
	return lipgloss.NewStyle().Background(theme.SurfaceAlt()).Width(m.width).Render(strings.Join(rendered, ""))
}

func (m Model) renderTabs(tabBar protocol.TabBar) string {
	theme := m.palette()
	activeStyle := lipgloss.NewStyle().Bold(true).Foreground(theme.TabActiveText()).Background(theme.TabActive()).Padding(0, 1)
	inactiveStyle := lipgloss.NewStyle().Foreground(theme.TabInactiveText()).Background(theme.Surface()).Padding(0, 1)
	dirtyStyle := lipgloss.NewStyle().Foreground(theme.TabDirty())
	rendered := make([]string, 0, len(tabBar.Tabs))
	for _, tab := range tabBar.Tabs {
		label := strings.TrimSpace(tab.Icon + " " + tab.Label)
		if tab.Dirty {
			label += dirtyStyle.Render(" *")
		}
		if tab.Attention {
			label += lipgloss.NewStyle().Foreground(theme.TabAttention()).Render(" !")
		}
		style := inactiveStyle
		if tab.Active {
			style = activeStyle
		}
		rendered = append(rendered, style.Render(label))
	}
	return lipgloss.NewStyle().Background(theme.Surface()).Width(m.width).Render(strings.Join(rendered, ""))
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
	overlay := m.overlayLines()
	if len(overlay) > 0 {
		lines = append(lines, overlay...)
	} else if mini, ok := m.minibuffer(); ok && mini.Visible {
		lines = append(lines, m.renderMinibuffer(mini))
	}
	return lines
}

func (m Model) renderStatusSegments(status protocol.StatusBar) string {
	left := m.renderSegmentList(status.Left)
	right := m.renderSegmentList(status.Right)
	leftWidth := lipgloss.Width(left)
	rightWidth := lipgloss.Width(right)
	spacer := strings.Repeat(" ", max(m.width-leftWidth-rightWidth, 1))
	return left + lipgloss.NewStyle().Background(m.palette().Base()).Render(spacer) + right
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
		parts = append(parts, style.Render(text))
	}
	return strings.Join(parts, "")
}

func (m Model) renderGitStatus(git protocol.GitStatus) string {
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
	return lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().SurfaceAlt()).Width(m.width).Render(fit(strings.Join(parts, "  "), m.width))
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

	itemBudget := max(m.maxOverlayHeight()-1, 1)
	if preview.Visible && len(preview.Lines) > 0 && m.width < 100 {
		itemBudget = max(itemBudget/2, 1)
	}
	items := make([]componentItem, 0, len(picker.Items))
	for _, item := range picker.Items {
		marker := " "
		if item.Marked {
			marker = "*"
		}
		detail := item.Description
		if detail == "" {
			detail = item.Annotation
		}
		if detail != "" {
			detail = strings.TrimSpace(detail)
		}
		items = append(items, componentItem{title: marker + " " + item.Label, description: detail})
	}
	lines := takeLines(m.charmList(title, items, int(picker.Selected), itemBudget+1, true), itemBudget+1)
	if picker.ActionVisible && len(picker.Actions) > 0 {
		lines = append(lines, lipgloss.NewStyle().Foreground(m.palette().Muted()).Render(fit(strings.Join(picker.Actions, "  "), m.width)))
	}
	if preview.Visible && len(preview.Lines) > 0 {
		if m.width >= 100 {
			return m.renderPickerWithSidePreview(lines, preview)
		}
		lines = append(lines, m.renderPickerPreview(preview, max(m.maxOverlayHeight()-len(lines), 1), m.width)...)
	}
	return takeLines(lines, m.maxOverlayHeight())
}

func (m Model) renderPickerWithSidePreview(left []string, preview protocol.PickerPreview) []string {
	leftWidth := max(m.width*45/100, 36)
	rightWidth := max(m.width-leftWidth, 20)
	leftStyle := lipgloss.NewStyle().Width(leftWidth)
	right := m.renderPickerPreview(preview, max(m.maxOverlayHeight(), len(left)), rightWidth)
	height := min(max(len(left), len(right)), m.maxOverlayHeight())
	lines := make([]string, 0, height)
	for i := 0; i < height; i++ {
		leftLine := ""
		if i < len(left) {
			leftLine = left[i]
		}
		rightLine := ""
		if i < len(right) {
			rightLine = right[i]
		}
		lines = append(lines, lipgloss.JoinHorizontal(lipgloss.Top, leftStyle.Render(leftLine), rightLine))
	}
	return lines
}

func (m Model) renderPickerPreview(preview protocol.PickerPreview, height int, width int) []string {
	theme := m.palette()
	style := lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).Width(width)
	limit := min(len(preview.Lines), max(height-1, 0))
	lines := []string{style.Bold(true).Foreground(theme.Accent()).Render(fit("Preview", width))}
	for _, line := range preview.Lines[:limit] {
		var builder strings.Builder
		for _, segment := range line.Segments {
			segmentStyle := lipgloss.NewStyle()
			if segment.FG != 0 {
				segmentStyle = segmentStyle.Foreground(lipgloss.Color(fmt.Sprintf("#%06X", segment.FG)))
			}
			if segment.Bold {
				segmentStyle = segmentStyle.Bold(true)
			}
			builder.WriteString(segmentStyle.Render(segment.Text))
		}
		lines = append(lines, style.Render(fit(builder.String(), width)))
	}
	return lines
}
