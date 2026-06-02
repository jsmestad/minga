package ui

import (
	"strings"

	"github.com/charmbracelet/x/ansi"
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

func statusName(status byte) string {
	switch status {
	case 0:
		return "idle"
	case 1:
		return "working"
	case 2:
		return "iterating"
	case 3:
		return "needs you"
	case 4:
		return "done"
	case 5:
		return "error"
	default:
		return "unknown"
	}
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
