package ui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func lineAt(lines []string, index int) string {
	if index >= 0 && index < len(lines) {
		return lines[index]
	}
	return ""
}

func renderRichLine(line protocol.RichLine) string {
	parts := make([]string, 0, len(line.Segments))
	for _, segment := range line.Segments {
		parts = append(parts, segment.Text)
	}
	return strings.Join(parts, "")
}

func agentMessagePrefix(kind byte) string {
	switch kind {
	case 0x01:
		return "you"
	case 0x02, 0x07:
		return "assistant"
	case 0x03:
		return "thinking"
	case 0x04, 0x08:
		return "tool"
	case 0x05:
		return "system"
	case 0x06:
		return "usage"
	case 0x09:
		return "approval"
	default:
		return "message"
	}
}

// cardSpineState returns the design token state an agent context-card status shows, matching macOS CardStatus.spineState.
// Idle and unknown statuses show no state; iterating shows the working state.
func cardSpineState(status byte) (generated.SpineState, bool) {
	switch status {
	case 1, 2:
		return generated.StateWorking, true
	case 3:
		return generated.StateNeedsYou, true
	case 4:
		return generated.StateDone, true
	case 5:
		return generated.StateFailed, true
	case 6:
		return generated.StateStopped, true
	default:
		return 0, false
	}
}

// cardStatusLabel returns the word an agent context-card status is shown with, matching macOS CardStatus.label.
// Every status that shows a state uses the state's design token word, so the card names it the way the modeline does; the rest read Idle.
func cardStatusLabel(status byte) string {
	if state, ok := cardSpineState(status); ok {
		return state.Token().Word
	}
	return "Idle"
}

// cardStatusRole returns the colour role an agent context-card status is drawn in, matching macOS CardStatus.role.
// Idle and unknown statuses use the waiting role.
func cardStatusRole(status byte) generated.ColorRole {
	if state, ok := cardSpineState(status); ok {
		return state.Token().Role
	}
	return generated.ColorRoleWaiting
}

func levelName(level byte) string {
	switch level {
	case 1:
		return "warn"
	case 2:
		return "error"
	case 3:
		return "ok"
	case 4:
		return "progress"
	default:
		return "info"
	}
}

func displayWidth(value string) int {
	return ansi.StringWidthWc(value)
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}

func fit(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if displayWidth(value) <= width {
		return value + strings.Repeat(" ", width-displayWidth(value))
	}
	return ansi.TruncateWc(value, width, "")
}

func takeLines(lines []string, limit int) []string {
	if len(lines) <= limit {
		return lines
	}
	return lines[:limit]
}
