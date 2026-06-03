package ui

import (
	"strings"

	"charm.land/bubbles/v2/list"
	"charm.land/bubbles/v2/table"
	"charm.land/bubbles/v2/textinput"
	"charm.land/lipgloss/v2"
)

type componentItem struct {
	title       string
	description string
}

func (i componentItem) Title() string {
	return i.title
}

func (i componentItem) Description() string {
	return i.description
}

func (i componentItem) FilterValue() string {
	return strings.TrimSpace(i.title + " " + i.description)
}

func (m Model) charmList(title string, items []componentItem, selected int, height int, descriptions bool) []string {
	if len(items) == 0 {
		return nil
	}
	theme := m.palette()
	delegate := list.NewDefaultDelegate()
	delegate.ShowDescription = descriptions
	delegate.SetSpacing(0)
	delegate.Styles.NormalTitle = lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface())
	delegate.Styles.NormalDesc = lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.PopupSurface())
	delegate.Styles.SelectedTitle = lipgloss.NewStyle().Bold(true).Foreground(theme.SelectionText()).Background(theme.Selection()).Padding(0, 1)
	delegate.Styles.SelectedDesc = lipgloss.NewStyle().Foreground(theme.SelectionText()).Background(theme.Selection()).Padding(0, 1)
	delegate.Styles.DimmedTitle = lipgloss.NewStyle().Foreground(theme.Muted())
	delegate.Styles.DimmedDesc = lipgloss.NewStyle().Foreground(theme.Muted())
	delegate.Styles.FilterMatch = lipgloss.NewStyle().Foreground(theme.Accent()).Underline(true)

	listItems := make([]list.Item, 0, len(items))
	for _, item := range items {
		listItems = append(listItems, item)
	}
	component := list.New(listItems, delegate, max(m.width, 1), max(height, 1))
	component.Title = title
	component.Styles.Title = lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupSurface())
	component.Styles.TitleBar = lipgloss.NewStyle().Background(theme.PopupSurface()).Width(m.width)
	component.Styles.StatusBar = lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.PopupSurface())
	component.Styles.NoItems = lipgloss.NewStyle().Foreground(theme.Muted()).Background(theme.PopupSurface())
	component.SetShowStatusBar(false)
	component.SetShowPagination(len(items) > height)
	component.SetShowHelp(false)
	component.SetFilteringEnabled(false)
	component.Select(min(max(selected, 0), len(items)-1))
	return strings.Split(component.View(), "\n")
}

func (m Model) charmTable(columns []table.Column, rows []table.Row, selected int, height int) []string {
	if len(rows) == 0 {
		return nil
	}
	theme := m.palette()
	styles := table.DefaultStyles()
	styles.Header = lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupSurface()).Padding(0, 1)
	styles.Cell = lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).Padding(0, 1)
	styles.Selected = lipgloss.NewStyle().Bold(true).Foreground(theme.SelectionText()).Background(theme.Selection())
	component := table.New(
		table.WithColumns(columns),
		table.WithRows(rows),
		table.WithFocused(true),
		table.WithHeight(max(height, 2)),
		table.WithWidth(max(m.width, 1)),
		table.WithStyles(styles),
	)
	component.SetCursor(min(max(selected, 0), len(rows)-1))
	return strings.Split(component.View(), "\n")
}

func (m Model) charmInput(prompt string, value string, cursor uint16) string {
	theme := m.palette()
	input := textinput.New()
	input.Prompt = prompt
	styles := input.Styles()
	styles.Focused.Prompt = lipgloss.NewStyle().Foreground(theme.Accent()).Bold(true)
	styles.Focused.Text = lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface())
	styles.Cursor.Color = theme.Accent()
	input.SetStyles(styles)
	input.SetValue(value)
	input.SetCursor(int(cursor))
	input.Focus()
	return lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).Width(m.width).Render(fit(input.View(), m.width))
}
