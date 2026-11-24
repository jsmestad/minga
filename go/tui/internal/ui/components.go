package ui

import (
	"image/color"
	"io"
	"strings"

	"charm.land/bubbles/v2/list"
	"charm.land/bubbles/v2/textinput"
	"charm.land/lipgloss/v2"
)

type componentItem struct {
	title       string
	description string
	// titleColor draws the title in a colour of its own, such as a state's colour role.
	// Nil or lipgloss.NoColor, such as a role the theme has not sent yet, keeps the list's title colour.
	titleColor color.Color
}

// componentDelegate is the list's default delegate, drawing each item's title in the item's titleColor when it has one.
type componentDelegate struct {
	list.DefaultDelegate
}

func (d componentDelegate) Render(w io.Writer, m list.Model, index int, item list.Item) {
	if component, ok := item.(componentItem); ok && hasColor(component.titleColor) {
		d.Styles.NormalTitle = d.Styles.NormalTitle.Foreground(component.titleColor)
		d.Styles.SelectedTitle = d.Styles.SelectedTitle.Foreground(component.titleColor)
	}
	d.DefaultDelegate.Render(w, m, index, item)
}

func hasColor(c color.Color) bool {
	_, none := c.(lipgloss.NoColor)
	return c != nil && !none
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
	delegate.Styles.NormalDesc = lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(theme.PopupSurface())
	delegate.Styles.SelectedTitle = lipgloss.NewStyle().Bold(true).Foreground(theme.PopupSelectionText()).Background(theme.PopupSelection()).Padding(padding(spaceHairline, spaceSM))
	delegate.Styles.SelectedDesc = lipgloss.NewStyle().Foreground(theme.PopupSelectionText()).Background(theme.PopupSelection()).Padding(padding(spaceHairline, spaceSM))
	delegate.Styles.DimmedTitle = lipgloss.NewStyle().Foreground(theme.PopupMutedText())
	delegate.Styles.DimmedDesc = lipgloss.NewStyle().Foreground(theme.PopupMutedText())
	delegate.Styles.FilterMatch = lipgloss.NewStyle().Foreground(theme.Accent()).Underline(true)

	listItems := make([]list.Item, 0, len(items))
	for _, item := range items {
		listItems = append(listItems, item)
	}
	component := list.New(listItems, componentDelegate{delegate}, max(m.width, 1), max(height, 1))
	component.Title = title
	component.Styles.Title = lipgloss.NewStyle().Bold(true).Foreground(theme.Accent()).Background(theme.PopupSurface())
	component.Styles.TitleBar = lipgloss.NewStyle().Background(theme.PopupSurface()).Width(m.width)
	component.Styles.StatusBar = lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(theme.PopupSurface())
	component.Styles.NoItems = lipgloss.NewStyle().Foreground(theme.PopupMutedText()).Background(theme.PopupSurface())
	component.SetShowStatusBar(false)
	component.SetShowPagination(len(items) > height)
	component.SetShowHelp(false)
	component.SetFilteringEnabled(false)
	component.Select(min(max(selected, 0), len(items)-1))
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
	return lipgloss.NewStyle().Foreground(theme.PopupText()).Background(theme.PopupSurface()).Render(fitStyled(input.View(), m.width))
}
