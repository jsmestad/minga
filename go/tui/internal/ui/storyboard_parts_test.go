package ui

// Storyboard anatomy parts in the TUI (#4036, the layout audit).
//
// The layout audit (design/tools/storyboard/audit.py) measures the parts docs/design/anatomy.md names. macOS tags its
// views and exports their frames; here the semantic model the frame came from says which text belongs to which part,
// and the part is found in the drawn cell grid, so the audit checks the cells the user sees, not the layout code.
// Frames are [column, row, width, height] in cells.

import (
	"strings"

	uv "github.com/charmbracelet/ultraviolet"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// storyboardPart is one measured instance of an anatomy part.
type storyboardPart struct {
	Part      string `json:"part"`
	Frame     [4]int `json:"frame"`
	Text      string `json:"text,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`
	Ellipsis  bool   `json:"ellipsis,omitempty"`
}

// cellGrid is the drawn buffer as one cell per column: wide glyphs keep their first cell and leave an empty one after.
type cellGrid [][]string

func newCellGrid(buffer uv.ScreenBuffer, cols, rows int) cellGrid {
	grid := make(cellGrid, rows)
	for y := range rows {
		grid[y] = make([]string, cols)
		for x := range cols {
			if cell := buffer.CellAt(x, y); cell != nil {
				grid[y][x] = cell.Content
			} else {
				grid[y][x] = " "
			}
		}
	}
	return grid
}

// find returns the first column at or after from in row y where text starts, cell by cell.
func (g cellGrid) find(y, from, to int, text string) int {
	runes := []string{}
	for _, r := range text {
		runes = append(runes, string(r))
	}
	if len(runes) == 0 {
		return -1
	}
	for x := max(from, 0); x+len(runes) <= min(to, len(g[y])); x++ {
		match := true
		for i, r := range runes {
			if g[y][x+i] != r {
				match = false
				break
			}
		}
		if match {
			return x
		}
	}
	return -1
}

// box finds the rounded border that starts at the first ╭ in the grid: [column, row, width, height].
func (g cellGrid) box() ([4]int, bool) {
	for y, row := range g {
		for x, cell := range row {
			if cell != "╭" {
				continue
			}
			right := x + 1
			for right < len(row) && row[right] != "╮" {
				right++
			}
			bottom := y + 1
			for bottom < len(g) && g[bottom][x] != "╰" {
				bottom++
			}
			if right < len(row) && bottom < len(g) {
				return [4]int{x, y, right - x + 1, bottom - y + 1}, true
			}
		}
	}
	return [4]int{}, false
}

// storyboardParts locates the which-key panel and the modeline in a drawn frame.
func storyboardParts(model Model, grid cellGrid) []storyboardPart {
	var parts []storyboardPart
	if which, ok := model.whichKey(); ok && which.Visible && len(which.Bindings) > 0 {
		parts = append(parts, whichKeyParts(which, grid)...)
	}
	if status, ok := model.statusBar(); ok {
		parts = append(parts, modelineParts(status, grid)...)
	}
	return parts
}

func whichKeyParts(which protocol.WhichKey, grid cellGrid) []storyboardPart {
	panel, ok := grid.box()
	if !ok {
		return nil
	}
	parts := []storyboardPart{{Part: "whichKey.panel", Frame: panel}}
	left, right := panel[0]+1, panel[0]+panel[2]-1
	top, bottom := panel[1]+1, panel[1]+panel[3]-1
	if prefix := which.Prefix; prefix != "" {
		if x := grid.find(top, left, right, prefix); x >= 0 {
			parts = append(parts, storyboardPart{Part: "whichKey.breadcrumb", Frame: [4]int{x, top, len([]rune(prefix)), 1}, Text: prefix})
		}
	}
	// Each binding is found by its description; its key is the nearest match of the key text before it on that row.
	used := map[[2]int]bool{}
	for _, binding := range which.Bindings {
		description := strings.TrimSpace(binding.Description)
		key := strings.TrimSpace(binding.Key)
		for y := top; y < bottom; y++ {
			x, shown, truncated := findLabel(grid, y, left, right, description, used)
			if x < 0 {
				continue
			}
			keyX := lastBefore(grid, y, left, x, key)
			if keyX < 0 {
				continue
			}
			used[[2]int{x, y}] = true
			labelStart := firstInk(grid, y, keyX+len([]rune(key)), x)
			ellipsis := truncated && x+shown < right && grid[y][x+shown] == "…"
			parts = append(parts,
				storyboardPart{Part: "whichKey.entryKey", Frame: [4]int{keyX, y, len([]rune(key)), 1}, Text: key},
				storyboardPart{Part: "whichKey.entryLabel", Frame: [4]int{labelStart, y, x + shown - labelStart, 1}, Text: description,
					Truncated: truncated, Ellipsis: ellipsis},
			)
			break
		}
	}
	return parts
}

// findLabel finds the description on row y, whole or as its longest shown prefix (at least three cells), and says
// how many cells of it are shown.
func findLabel(grid cellGrid, y, from, to int, text string, used map[[2]int]bool) (int, int, bool) {
	runes := []rune(text)
	for length := len(runes); length >= min(3, len(runes)); length-- {
		for start := from; start < to; {
			x := grid.find(y, start, to, string(runes[:length]))
			if x < 0 {
				break
			}
			if !used[[2]int{x, y}] {
				return x, length, length < len(runes)
			}
			start = x + 1
		}
	}
	return -1, 0, false
}

func lastBefore(grid cellGrid, y, from, before int, text string) int {
	found := -1
	for x := from; x < before; {
		at := grid.find(y, x, before, text)
		if at < 0 {
			break
		}
		found = at
		x = at + 1
	}
	return found
}

// firstInk is the first non-blank cell in [from, to), or to when the range is blank: where a label's glyph begins.
func firstInk(grid cellGrid, y, from, to int) int {
	for x := from; x < to; x++ {
		if strings.TrimSpace(grid[y][x]) != "" {
			return x
		}
	}
	return to
}

// modelineParts finds each segment's visible words on the modeline row, left segments from the leading edge and right
// segments back from the trailing edge, in the order the BEAM sent them.
func modelineParts(status protocol.StatusBar, grid cellGrid) []storyboardPart {
	for y := len(grid) - 1; y >= max(len(grid)-3, 0); y-- {
		row := grid[y]
		var parts []storyboardPart
		x := 0
		for _, segment := range status.Left {
			text := strings.TrimSpace(segment.Text)
			if text == "" {
				continue
			}
			at := grid.find(y, x, len(row), text)
			if at < 0 {
				parts = nil
				break
			}
			parts = append(parts, storyboardPart{Part: "modeline.segment", Frame: [4]int{at, y, len([]rune(text)), 1}, Text: segment.Name + ": " + text})
			x = at + len([]rune(text))
		}
		if len(parts) == 0 {
			continue
		}
		for _, segment := range status.Right {
			text := strings.TrimSpace(segment.Text)
			if text == "" {
				continue
			}
			if at := grid.find(y, x, len(row), text); at >= 0 {
				parts = append(parts, storyboardPart{Part: "modeline.segment", Frame: [4]int{at, y, len([]rune(text)), 1}, Text: segment.Name + ": " + text})
				x = at + len([]rune(text))
			}
		}
		return append([]storyboardPart{{Part: "modeline", Frame: [4]int{0, y, len(row), 1}}}, parts...)
	}
	return nil
}
