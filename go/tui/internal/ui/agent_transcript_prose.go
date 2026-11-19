package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/rivo/uniseg"
)

const agentProseRail = "  │ "
const agentProseRailWidth = 4
const agentProseTabWidth = 4

// Source offsets for wrapped blocks only. Text and style stay in the resident message.
type agentProseLayout map[int][]agentProseRow

type agentProsePosition struct{ run, offset int }

type agentProseRow struct {
	line       int
	start, end agentProsePosition
}

func layoutAgentProse(lines []protocol.AgentStyledLine, width int) []agentProseRow {
	var rows []agentProseRow
	for lineIndex, line := range lines[:min(len(lines), agentAssistantStyledLines)] {
		if agentStyledLineIsAllCode(line) {
			if rows != nil {
				rows = append(rows, agentProseRow{line: lineIndex})
			}
			continue
		}
		var start agentProsePosition
		cells := 0
		var wordStart agentProsePosition
		wordColumn := 0
		space := false
		wrapped := false
		for runIndex, run := range line {
			state := -1
			for text := run.Text; text != ""; {
				cluster, rest, clusterWidth, next := uniseg.FirstGraphemeClusterInString(text, state)
				switch {
				case cluster == "\t":
					clusterWidth = agentProseTabWidth
				case len(cluster) > 1:
					// Match terminals without grapheme clustering.
					clusterWidth = displayWidth(cluster)
				}
				position := agentProsePosition{runIndex, len(run.Text) - len(text)}
				whitespace := cluster == " " || cluster == "\t"
				if space && !whitespace {
					wordStart, wordColumn = position, cells
				}
				if cells > 0 && cells+clusterWidth > width {
					if rows == nil {
						rows = make([]agentProseRow, lineIndex, lineIndex+2)
						for index := range rows {
							rows[index].line = index
						}
					}
					boundary := position
					if wordColumn > 0 && cells-wordColumn+clusterWidth <= width {
						boundary = wordStart
						cells -= wordColumn
					} else {
						cells = 0
					}
					rows = append(rows, agentProseRow{lineIndex, start, boundary})
					start, wordColumn, wrapped = boundary, 0, true
				}
				cells += clusterWidth
				space = whitespace
				text, state = rest, next
			}
		}
		if wrapped {
			rows = append(rows, agentProseRow{lineIndex, start, agentProsePosition{run: len(line)}})
		} else if rows != nil {
			rows = append(rows, agentProseRow{line: lineIndex})
		}
	}
	return rows
}

func agentProseBodyWidth(width int) int {
	return max(width-agentProseRailWidth, 1)
}

func (m Model) renderAgentProseRows(lines []protocol.AgentStyledLine, wrapped []agentProseRow, width, start, count int) []string {
	p := m.palette()
	surface := p.AgentPanel()
	rail := lipgloss.NewStyle().Foreground(p.AgentAssistantBorder()).Background(surface).Render(agentProseRail)
	pad := lipgloss.NewStyle().Background(surface)
	visible := min(len(lines), agentAssistantStyledLines)
	bodyRows := visible
	if wrapped != nil {
		bodyRows = len(wrapped)
	}
	out := make([]string, 0, count)
	for index := start; index < min(start+count, bodyRows); index++ {
		row := agentProseRow{line: index}
		if wrapped != nil {
			row = wrapped[index]
		}
		line := lines[row.line]
		if agentStyledLineIsAllCode(line) {
			body := m.renderAgentStyledLine(line, agentProseBodyWidth(width))
			out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rail+body, width)))
			continue
		}
		var body strings.Builder
		if row.start == row.end {
			row.end = agentProsePosition{run: len(line)}
		}
		for ri := row.start.run; ri < len(line) && ri <= row.end.run; ri++ {
			run := line[ri]
			from, to := 0, len(run.Text)
			if ri == row.start.run {
				from = row.start.offset
			}
			if ri == row.end.run {
				to = row.end.offset
			}
			if from < to {
				body.WriteString(agentStyledRunStyle(run, surface).TabWidth(agentProseTabWidth).Render(run.Text[from:to]))
			}
		}
		styled := rail + body.String()
		styled = ansi.TruncateWc(styled, width, "")
		if remaining := width - displayWidth(styled); remaining > 0 {
			styled += pad.Render(strings.Repeat(" ", remaining))
		}
		out = append(out, styled)
	}
	if hidden := len(lines) - visible; hidden > 0 && start <= bodyRows && bodyRows < start+count {
		more := lipgloss.NewStyle().Foreground(p.Muted()).Background(surface).Render(fmt.Sprintf("… +%d lines · ⏎ expand", hidden))
		out = append(out, lipgloss.NewStyle().Background(surface).Width(width).Render(fitStyled(rail+more, width)))
	}
	return out
}
