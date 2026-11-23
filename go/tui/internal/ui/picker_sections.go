package ui

import (
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// pickerItemWindow chooses which picker items a list of rowBudget rows draws, counting the section header rows that the drawn items need.
//
// It returns the half-open item range [start, end) and whether section headers are drawn. The selected item is always in the range. As for ungrouped pickers, the window starts at the first item that still keeps the selected item and the headers above it within the budget. When even the selected item and its header do not fit (a one-row list), headers are dropped so the selected item stays visible. Headers are never items: the range, the selection and the click slots all count items only.
func pickerItemWindow(items []protocol.PickerItem, selected int, rowBudget int) (int, int, bool) {
	if rowBudget <= 0 || len(items) == 0 {
		return 0, 0, false
	}
	selected = min(max(selected, 0), len(items)-1)
	headers := pickerItemRows(items, selected, selected, true) <= rowBudget
	start := 0
	for start < selected && pickerItemRows(items, start, selected, headers) > rowBudget {
		start++
	}
	end, rows := start, 0
	for end < len(items) {
		need := 1
		if headers && pickerStartsSection(items, end, start) {
			need = 2
		}
		if rows+need > rowBudget {
			break
		}
		rows += need
		end++
	}
	return start, end, headers
}

// pickerItemRows counts the rows that items[start] through items[last] take, including their section headers when headers is true.
func pickerItemRows(items []protocol.PickerItem, start int, last int, headers bool) int {
	rows := 0
	for index := start; index <= last; index++ {
		rows++
		if headers && pickerStartsSection(items, index, start) {
			rows++
		}
	}
	return rows
}

// pickerStartsSection reports whether a section header goes above items[index] in a list whose first drawn item is items[start]. A grouped item starts a section when its group differs from the previous item's, and the first drawn item always names its section so a scrolled list keeps its context.
func pickerStartsSection(items []protocol.PickerItem, index int, start int) bool {
	group := items[index].Group
	if group == "" {
		return false
	}
	return index == start || items[index-1].Group != group
}

// renderPickerSectionHeader draws a non-selectable section header row. It carries no pointer zone, so a click on it activates nothing.
func (m Model) renderPickerSectionHeader(group string, width int) string {
	theme := m.palette()
	style := lipgloss.NewStyle().Bold(true).Foreground(theme.PopupMutedText()).Background(theme.PopupSurface()).Width(width).ColorWhitespace(true)
	return renderPadded(style, "  "+ansi.TruncateWc(group, max(width-3, 1), "…"), width)
}
