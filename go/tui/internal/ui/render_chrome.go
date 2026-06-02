package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func (m Model) headerLines() []string {
	title := m.title
	if title == "" {
		title = "Minga"
	}
	if crumb, ok := m.breadcrumb(); ok && len(crumb.Segments) > 0 {
		title += "  " + strings.Join(crumb.Segments, " / ")
	}

	lines := []string{
		lipgloss.NewStyle().Bold(true).Foreground(m.palette().Accent()).Background(m.palette().Surface()).Width(m.width).Render(title),
	}
	if spaces, ok := m.workspaceBar(); ok && len(spaces.Spaces) > 0 {
		lines = append(lines, m.renderWorkspaces(spaces))
	}
	if tabBar, ok := m.tabBar(); ok && len(tabBar.Tabs) > 0 {
		lines = append(lines, m.renderTabs(tabBar))
	}
	if git, ok := m.gitStatus(); ok && git.Branch != "" {
		lines = append(lines, m.renderGitStatus(git))
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
	if chromeStatus, ok := m.statusBar(); ok && chromeStatus.Filename != "" {
		status = fmt.Sprintf("%s  %d:%d", chromeStatus.Filename, chromeStatus.Line, chromeStatus.Column)
		if chromeStatus.Message != "" {
			status += "  " + chromeStatus.Message
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
		lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(m.palette().Base()).Width(m.width).Render(status),
	}
	overlay := m.overlayLines()
	if len(overlay) > 0 {
		lines = append(lines, overlay...)
	} else if mini, ok := m.minibuffer(); ok && mini.Visible {
		lines = append(lines, m.renderMinibuffer(mini))
	}
	return lines
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
	value := strings.TrimSpace(mini.Prompt + mini.Input)
	if mini.Context != "" {
		value += "  " + mini.Context
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color("#D8DEE9")).Background(lipgloss.Color("#101318")).Width(m.width).Render(value)
}

func (m Model) renderCompletion(completion protocol.Completion) []string {
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#D8DEE9")).Background(lipgloss.Color("#101318")).Width(m.width)
	selectedStyle := style.Bold(true).Foreground(lipgloss.Color("#FFFFFF")).Background(lipgloss.Color("#30445C"))
	limit := min(len(completion.Items), m.maxOverlayHeight())
	lines := make([]string, 0, limit)
	for i, item := range completion.Items[:limit] {
		detail := item.Detail
		if detail != "" {
			detail = "  " + detail
		}
		text := fit(item.Label+detail, m.width)
		if uint16(i) == completion.Selected {
			lines = append(lines, selectedStyle.Render(text))
		} else {
			lines = append(lines, style.Render(text))
		}
	}
	return lines
}

func (m Model) renderWhichKey(which protocol.WhichKey) []string {
	title := "Keys"
	if which.Prefix != "" {
		title += " " + which.Prefix
	}
	if which.PageCount > 1 {
		title += fmt.Sprintf("  %d/%d", which.Page+1, which.PageCount)
	}
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#B8C0CC")).Background(lipgloss.Color("#111720")).Width(m.width)
	lines := []string{style.Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Render(fit(title, m.width))}
	limit := min(len(which.Bindings), max(m.maxOverlayHeight()-1, 0))
	for _, binding := range which.Bindings[:limit] {
		label := strings.TrimSpace(binding.Icon + " " + binding.Description)
		text := fit(binding.Key+"  "+label, m.width)
		lines = append(lines, style.Render(text))
	}
	return lines
}

func (m Model) renderPicker(picker protocol.Picker, preview protocol.PickerPreview) []string {
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#D8DEE9")).Background(lipgloss.Color("#101318")).Width(m.width)
	selectedStyle := style.Bold(true).Foreground(lipgloss.Color("#FFFFFF")).Background(lipgloss.Color("#30445C"))
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

	lines := []string{style.Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Render(fit(title, m.width))}
	itemBudget := max(m.maxOverlayHeight()-1, 1)
	if preview.Visible && len(preview.Lines) > 0 && m.width < 100 {
		itemBudget = max(itemBudget/2, 1)
	}
	limit := min(len(picker.Items), itemBudget)
	for i, item := range picker.Items[:limit] {
		marker := " "
		if item.Marked {
			marker = "*"
		}
		detail := item.Description
		if detail == "" {
			detail = item.Annotation
		}
		if detail != "" {
			detail = "  " + detail
		}
		text := fit(marker+" "+item.Label+detail, m.width)
		if uint16(i) == picker.Selected {
			lines = append(lines, selectedStyle.Render(text))
		} else {
			lines = append(lines, style.Render(text))
		}
	}
	if picker.ActionVisible && len(picker.Actions) > 0 {
		lines = append(lines, style.Foreground(lipgloss.Color("#AEB7C2")).Render(fit(strings.Join(picker.Actions, "  "), m.width)))
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
	style := lipgloss.NewStyle().Foreground(lipgloss.Color("#AEB7C2")).Background(lipgloss.Color("#111720")).Width(width)
	limit := min(len(preview.Lines), max(height-1, 0))
	lines := []string{style.Bold(true).Foreground(lipgloss.Color("#C7D1FF")).Render(fit("Preview", width))}
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
