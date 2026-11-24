package ui

// Storyboard anatomy parts in the TUI (#4036, the layout audit).
//
// The layout audit (design/tools/storyboard/audit.py) measures the parts docs/design/anatomy.md names. macOS tags its
// views and exports their frames; here the semantic model the frame came from says which text belongs to which part,
// and the part is found in the drawn cell grid, so the audit checks the cells the user sees, not the layout code.
// Frames are [column, row, width, height] in cells.

import (
	"strings"
	"testing"

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
	// Missing marks a part the semantic model says is on screen but the locator could not find in the cells, so
	// the audit fails it instead of skipping the rules it would have measured.
	Missing bool `json:"missing,omitempty"`
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
		return []storyboardPart{{Part: "whichKey.panel", Missing: true}}
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
		found := false
		for y := top; y < bottom && !found; y++ {
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
			found = true
		}
		if !found {
			parts = append(parts, storyboardPart{Part: "whichKey.entry", Text: key + " " + description, Missing: true})
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

// modelineParts finds each segment's visible words on the modeline row, in the order the BEAM sent them. The row is
// the one near the bottom that shows the first left segment. A left segment that is not there is reported missing; a
// right segment may be dropped on purpose (the TUI drops the lowest-priority right segments to fit), so it is not.
func modelineParts(status protocol.StatusBar, grid cellGrid) []storyboardPart {
	var left []protocol.StatusSegment
	for _, segment := range status.Left {
		if strings.TrimSpace(segment.Text) != "" {
			left = append(left, segment)
		}
	}
	if len(left) == 0 {
		return nil
	}
	first := strings.TrimSpace(left[0].Text)
	y := -1
	for row := len(grid) - 1; row >= max(len(grid)-3, 0) && y < 0; row-- {
		if grid.find(row, 0, len(grid[row]), first) >= 0 {
			y = row
		}
	}
	if y < 0 {
		return []storyboardPart{{Part: "modeline", Text: first, Missing: true}}
	}
	parts := []storyboardPart{{Part: "modeline", Frame: [4]int{0, y, len(grid[y]), 1}}}
	x := 0
	for _, segment := range left {
		text := strings.TrimSpace(segment.Text)
		at := grid.find(y, x, len(grid[y]), text)
		if at < 0 {
			parts = append(parts, storyboardPart{Part: "modeline.segment", Text: segment.Name + ": " + text, Missing: true})
			continue
		}
		parts = append(parts, storyboardPart{Part: "modeline.segment", Frame: [4]int{at, y, len([]rune(text)), 1}, Text: segment.Name + ": " + text})
		x = at + len([]rune(text))
	}
	for _, segment := range status.Right {
		text := strings.TrimSpace(segment.Text)
		if text == "" {
			continue
		}
		if at := grid.find(y, x, len(grid[y]), text); at >= 0 {
			parts = append(parts, storyboardPart{Part: "modeline.segment", Frame: [4]int{at, y, len([]rune(text)), 1}, Text: segment.Name + ": " + text})
			x = at + len([]rune(text))
		}
	}
	return parts
}

// A surface the semantic model says is on screen but the locator cannot find is reported missing, so the audit fails
// the frame instead of skipping the rules it would have measured.
func TestStoryboardPartsReportWhatTheyCannotFind(t *testing.T) {
	grid := cellGrid{
		strings.Split("hello     ", ""),
		strings.Split(" NORMAL  x", ""),
	}
	which := protocol.WhichKey{Visible: true, Bindings: []protocol.WhichKeyBinding{{Key: "f", Description: "Find file"}}}
	if parts := whichKeyParts(which, grid); len(parts) != 1 || parts[0].Part != "whichKey.panel" || !parts[0].Missing {
		t.Fatalf("a which-key panel without its border is missing, got %+v", parts)
	}

	status := protocol.StatusBar{Left: []protocol.StatusSegment{{Name: "mode", Text: "NORMAL"}, {Name: "file", Text: "a.ex"}}}
	parts := modelineParts(status, grid)
	missing := []string{}
	for _, part := range parts {
		if part.Missing {
			missing = append(missing, part.Text)
		}
	}
	if len(missing) != 1 || missing[0] != "file: a.ex" {
		t.Fatalf("a left segment that is not drawn is missing, got %+v", parts)
	}

	if parts := modelineParts(protocol.StatusBar{Left: []protocol.StatusSegment{{Name: "mode", Text: "INSERT"}}}, grid); len(parts) != 1 || !parts[0].Missing {
		t.Fatalf("a modeline whose first segment is not drawn is missing, got %+v", parts)
	}
}
