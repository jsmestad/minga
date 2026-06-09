package board

import "fmt"

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
