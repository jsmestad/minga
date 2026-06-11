package board

import (
	"fmt"
	"strings"
)

// RenderLines renders a compact extension-owned Board summary for terminal frontends. The Charm TUI no longer carries this renderer in core parity code.
func RenderLines(board Board, maxHeight int) []string {
	if !board.Visible || len(board.Cards) == 0 || maxHeight <= 0 {
		return nil
	}
	lines := []string{fmt.Sprintf("Board  %d cards", len(board.Cards))}
	for _, card := range board.Cards {
		marker := " "
		if card.ID == board.FocusedCardID || card.Flags&0x02 != 0 {
			marker = ">"
		}
		lines = append(lines, fmt.Sprintf("%s %s  %s", marker, statusName(card.Status), card.Task))
		if len(lines) >= maxHeight {
			break
		}
	}
	return lines
}

// ZoomHeaderLine renders the single-line zoom header shown at the top of the
// zoomed card view: status icon, task, optional model, and the "ESC back to
// Board" affordance right-aligned to width. It returns "" when the board is not
// zoomed or the zoomed card is missing. This restores the capability the old
// cell-grid build_zoom_context_bar provided before it was disposed (#2328); it
// is a contextual header over the editor, not a cell-grid draw path.
func ZoomHeaderLine(board Board, width int) string {
	card := board.ZoomedCard()
	if card == nil || width <= 0 {
		return ""
	}

	left := fmt.Sprintf(" %s %s", zoomStatusIcon(card.Status), card.Task)
	if card.Model != "" {
		left += " · " + card.Model
	}
	hint := " ESC back to Board "

	leftRunes := []rune(left)
	hintRunes := []rune(hint)
	if len(leftRunes)+len(hintRunes) >= width {
		// No room for the hint: clamp the identity to the available width.
		if len(leftRunes) > width {
			return string(leftRunes[:width])
		}
		return left
	}
	gap := width - len(leftRunes) - len(hintRunes)
	return left + strings.Repeat(" ", gap) + hint
}

func zoomStatusIcon(status byte) string {
	switch status {
	case 0:
		return "○"
	case 1:
		return "●"
	case 2:
		return "◉"
	case 3:
		return "◆"
	case 4:
		return "✓"
	case 5:
		return "✗"
	default:
		return "○"
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
		return "errored"
	default:
		return "unknown"
	}
}
