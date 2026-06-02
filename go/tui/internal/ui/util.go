package ui

import (
	"strings"

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

func displayWidth(value string) int {
	width := 0
	for range value {
		width++
	}
	return width
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

func fit(value string, width int) string {
	if width <= 0 {
		return ""
	}
	if displayWidth(value) <= width {
		return value + strings.Repeat(" ", width-displayWidth(value))
	}
	runes := []rune(value)
	if len(runes) <= width {
		return value
	}
	return string(runes[:width])
}

func takeLines(lines []string, limit int) []string {
	if len(lines) <= limit {
		return lines
	}
	return lines[:limit]
}
