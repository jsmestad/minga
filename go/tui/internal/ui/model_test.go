package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestFooterOverlayPrioritizesPickerOverCompletionWhichKeyAndMinibuffer(t *testing.T) {
	model := New(80, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiMinibuffer: {
			Mini: protocol.Minibuffer{Visible: true, Prompt: ":", Input: "write"},
		},
		generated.OPGuiCompletion: {
			Complete: protocol.Completion{Visible: true, Items: []protocol.CompletionItem{{Label: "Enum.map"}}},
		},
		generated.OPGuiWhichKey: {
			Which: protocol.WhichKey{Visible: true, Prefix: "SPC", Bindings: []protocol.WhichKeyBinding{{Key: "f", Description: "file"}}},
		},
		generated.OPGuiPicker: {
			Picker: protocol.Picker{Visible: true, Title: "Files", Query: "main", Items: []protocol.PickerItem{{Label: "main.ex"}}},
		},
	}

	footer := strings.Join(model.footerLines(), "\n")
	if !strings.Contains(footer, "Files") || !strings.Contains(footer, "main.ex") {
		t.Fatalf("footer should render picker: %q", footer)
	}
	if strings.Contains(footer, "Enum.map") || strings.Contains(footer, "SPC") || strings.Contains(footer, ":write") {
		t.Fatalf("footer rendered lower-priority overlays: %q", footer)
	}
}

func TestPickerPreviewRendersWithPicker(t *testing.T) {
	model := New(80, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiPicker: {
			Picker: protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{{Label: "main.ex"}}},
		},
		generated.OPGuiPickerPreview: {
			Preview: protocol.PickerPreview{
				Visible: true,
				Lines: []protocol.PreviewLine{{
					Segments: []protocol.PreviewSegment{{Text: "def main", FG: 0xCCDDEE, Bold: true}},
				}},
			},
		},
	}

	footer := strings.Join(model.footerLines(), "\n")
	if !strings.Contains(footer, "Preview") || !strings.Contains(footer, "def main") {
		t.Fatalf("footer should render picker preview: %q", footer)
	}
}

func TestPickerOverlayIsBounded(t *testing.T) {
	model := New(100, 24, nil)
	items := make([]protocol.PickerItem, 20)
	lines := make([]protocol.PreviewLine, 20)
	for i := range items {
		items[i] = protocol.PickerItem{Label: "item"}
		lines[i] = protocol.PreviewLine{Segments: []protocol.PreviewSegment{{Text: "preview"}}}
	}
	rendered := model.renderPicker(
		protocol.Picker{Visible: true, Title: "Files", Items: items},
		protocol.PickerPreview{Visible: true, Lines: lines},
	)
	if len(rendered) > model.maxOverlayHeight() {
		t.Fatalf("picker overlay height = %d, want <= %d", len(rendered), model.maxOverlayHeight())
	}
}

func TestWidePickerPreviewRendersBesideList(t *testing.T) {
	model := New(120, 30, nil)
	rendered := model.renderPicker(
		protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{{Label: "main.ex"}}},
		protocol.PickerPreview{Visible: true, Lines: []protocol.PreviewLine{{Segments: []protocol.PreviewSegment{{Text: "def main"}}}}},
	)
	joined := strings.Join(rendered, "\n")
	if !strings.Contains(joined, "main.ex") || !strings.Contains(joined, "def main") {
		t.Fatalf("wide picker should render list and preview together: %q", joined)
	}
	if len(rendered) > model.maxOverlayHeight() {
		t.Fatalf("wide picker overlay height = %d, want <= %d", len(rendered), model.maxOverlayHeight())
	}
}

func TestApplyWindowDeltaResolvesRefsAndReplacesRowSnapshot(t *testing.T) {
	model := New(80, 24, nil)
	model.putWindow(protocol.WindowContent{
		ID: 7,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "old one"},
			{ID: 2, ContentHash: 22, Text: "old two"},
			{ID: 3, ContentHash: 33, Text: "removed"},
		},
	})

	model.applyWindowDelta(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 2,
		Rows: []protocol.WindowRow{
			{Ref: true, ID: 1, ContentHash: 11},
			{ID: 2, ContentHash: 44, Text: "new two"},
		},
	})

	rows := model.windows[7].Rows
	if len(rows) != 2 {
		t.Fatalf("row count = %d, want 2: %+v", len(rows), rows)
	}
	if rows[0].Text != "old one" || rows[1].Text != "new two" {
		t.Fatalf("delta rows resolved incorrectly: %+v", rows)
	}
}

func TestCursorShapeSequenceTracksProtocolShape(t *testing.T) {
	model := New(80, 24, nil)
	model.cursorShape = 1
	if got := model.cursorStyleSequence(); got != "\x1b[6 q" {
		t.Fatalf("beam cursor sequence = %q", got)
	}
	model.cursorShape = 2
	if got := model.cursorStyleSequence(); got != "\x1b[4 q" {
		t.Fatalf("underline cursor sequence = %q", got)
	}
}

func TestThemeCommandUpdatesModelPalette(t *testing.T) {
	model := New(20, 4, nil)
	_ = model.applyCommands([]protocol.Command{{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: map[byte]uint32{themeEditorBG: 0x010203, themePopupSelBG: 0x112233}}}}})

	if got := model.activePalette.colors[themeEditorBG]; got != 0x010203 {
		t.Fatalf("editor background slot = 0x%06X, want 0x010203", got)
	}
	if got := model.activePalette.colors[themePopupSelBG]; got != 0x112233 {
		t.Fatalf("selection slot = 0x%06X, want 0x112233", got)
	}
}

func TestSemanticWindowUsesThemeForSelectionOverlay(t *testing.T) {
	model := New(20, 4, nil)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{themePopupSelBG: 0x112233}})
	style := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 1, EndRow: 0, EndCol: 3}}, 0, 1)

	if style.GetBackground() != model.palette().Selection() {
		t.Fatalf("selection overlay should use theme selection color")
	}
}

func TestSemanticWindowRendersGutterCursorlineTildesAndModeline(t *testing.T) {
	model := New(30, 6, nil)
	model.gutters = map[uint16]protocol.Gutter{
		7: {
			WindowID:        7,
			ContentHeight:   3,
			CursorLine:      0,
			LineNumberStyle: 0,
			LineNumberWidth: 3,
			SignColWidth:    2,
			Entries: []protocol.GutterEntry{
				{BufferLine: 0},
				{BufferLine: 1},
				{BufferLine: 2, DisplayType: 5},
			},
		},
	}
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {
			Status: protocol.StatusBar{
				Left:  []protocol.StatusSegment{{Text: " NORMAL "}},
				Right: []protocol.StatusSegment{{Text: "1:1 Top"}},
			},
		},
	}
	model.putWindow(protocol.WindowContent{
		ID:         7,
		Cursorline: protocol.Cursorline{Visible: true, Row: 0, BG: 0x333333},
		Rows:       []protocol.WindowRow{{BufferLine: 0, Text: "hello"}},
	})
	model.viewport.SetContent(model.content())

	view := ansi.Strip(model.View())

	if !strings.Contains(view, "1 hello") || !strings.Contains(view, "~") {
		t.Fatalf("semantic view should include gutter line number, content, and tilde filler: %q", view)
	}
	if !strings.Contains(view, " NORMAL ") || !strings.Contains(view, "1:1 Top") {
		t.Fatalf("semantic view should render modeline segments: %q", view)
	}
}

func TestOverlayLinesRenderRemainingSemanticSurfaces(t *testing.T) {
	model := New(60, 12, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiAgentContext: {AgentContext: protocol.AgentContext{Visible: true, Task: "Review diff", Status: 1, CanApprove: true}}}
	if got := strings.Join(model.overlayLines(), "\n"); !strings.Contains(got, "Review diff") {
		t.Fatalf("agent context overlay missing content: %q", got)
	}

	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiToolManager: {ToolManager: protocol.ToolManager{Visible: true, Tools: []protocol.ToolSummary{{Name: "elixir-ls", Label: "Elixir LS", Status: 1}}}}}
	if got := strings.Join(model.overlayLines(), "\n"); !strings.Contains(got, "Elixir LS") || !strings.Contains(got, "installed") {
		t.Fatalf("tool manager overlay missing content: %q", got)
	}
}

func TestSplitSeparatorsRenderOnContent(t *testing.T) {
	model := New(24, 6, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{Verticals: []protocol.VerticalSeparator{{Col: 2, StartRow: 0, EndRow: 1}}, Horizontals: []protocol.HorizontalSeparator{{Row: 1, Col: 0, Width: 16, Filename: "main.ex"}}}}}
	styled := "\x1b[1mabcd\x1b[0m"
	lines := model.withSplitSeparators([]string{styled, "efghijklmnop"})
	joined := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(joined, "│") || !strings.Contains(joined, "main.ex") {
		t.Fatalf("split separators not rendered: %q", joined)
	}
	if !strings.Contains(lines[0], "\x1b[") || !strings.Contains(lines[0], "\x1b[1md") {
		t.Fatalf("vertical replacement should preserve and resume existing ANSI styling: %q", lines[0])
	}
}

func TestLegacyCursorlineAppliesToCellFallback(t *testing.T) {
	model := New(10, 4, nil)
	model.cursorlineChrome = protocol.CursorlineChrome{Visible: true, Row: 0, BG: 0x112233}
	lines := model.withLegacyCursorline([]string{"hello     "})
	if len(lines) != 1 || ansi.Strip(lines[0]) == "" {
		t.Fatalf("legacy cursorline should preserve row content: %+v", lines)
	}
}

func TestApplyCommandsStoresIndentGuidesByWindow(t *testing.T) {
	model := New(30, 6, nil)
	_ = model.applyCommands([]protocol.Command{{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiIndentGuides, IndentGuides: protocol.IndentGuides{WindowID: 7, TabWidth: 2, GuideCols: []uint16{2}, IndentLevels: []byte{2}}}}})

	guides, ok := model.indentGuides[7]
	if !ok || len(guides.GuideCols) != 1 || guides.GuideCols[0] != 2 {
		t.Fatalf("indent guides should be retained per window: %+v", model.indentGuides)
	}
}

func TestFileTreeSelectionUpdatesExistingTree(t *testing.T) {
	model := New(30, 6, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Rows: []protocol.FileTreeRow{{ID: "a", Name: "a"}, {ID: "b", Name: "b"}}}}}
	model.applyFileTreeSelection(protocol.FileTreeSelection{Focused: true, SelectedID: "b"})

	tree := model.chrome[generated.OPGuiFileTree].Tree
	if tree.Selected != "b" || !tree.Focused || tree.Rows[0].Selected || !tree.Rows[1].Selected || !tree.Rows[1].Focused {
		t.Fatalf("file tree selection not applied: %+v", tree)
	}
}

func TestApplyCommandsStoresSemanticGuttersByWindow(t *testing.T) {
	model := New(30, 6, nil)
	_ = model.applyCommands([]protocol.Command{
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiGutter, WindowGutter: protocol.Gutter{WindowID: 1, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 0}}}}},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiGutter, WindowGutter: protocol.Gutter{WindowID: 2, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 9}}}}},
	})

	first, firstOK := model.windowGutter(1)
	second, secondOK := model.windowGutter(2)
	if !firstOK || !secondOK || first.Entries[0].BufferLine != 0 || second.Entries[0].BufferLine != 9 {
		t.Fatalf("gutters should be retained per window: first=%+v second=%+v", first, second)
	}
}

func TestSemanticWindowsUsePerWindowHeights(t *testing.T) {
	model := New(40, 8, nil)
	model.gutters = map[uint16]protocol.Gutter{
		1: {WindowID: 1, ContentHeight: 1, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 0}}},
		2: {WindowID: 2, ContentHeight: 1, LineNumberWidth: 3, Entries: []protocol.GutterEntry{{BufferLine: 10}}},
	}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "first"}}})
	model.putWindow(protocol.WindowContent{ID: 2, Rows: []protocol.WindowRow{{Text: "second"}}})

	lines := model.semanticLines()
	joined := ansi.Strip(strings.Join(lines, "\n"))
	if len(lines) != 2 || !strings.Contains(joined, "first") || !strings.Contains(joined, "second") {
		t.Fatalf("semantic windows should not pad the first window over later windows: lines=%d %q", len(lines), joined)
	}
}

func TestCellLinesAdvanceByGraphemeWidth(t *testing.T) {
	model := New(8, 5, nil)
	model.cells[position{row: 0, col: 0}] = cell{text: "👍🏼x"}
	model.cells[position{row: 0, col: 3}] = cell{text: "z"}

	rendered := model.cellLines()
	stripped := ansi.Strip(rendered[0])

	if !strings.HasPrefix(stripped, "👍🏼xz") {
		t.Fatalf("cell line = %q, want grapheme-width placement prefix %q", stripped, "👍🏼xz")
	}
	if width := ansi.StringWidthWc(stripped); width != 8 {
		t.Fatalf("cell line width = %d, want 8 for %q", width, stripped)
	}
}

func TestCellLinesPreserveDrawOrderForOverlappingClearThenContent(t *testing.T) {
	// The scroll-redraw path sends a full-row space clear and then the
	// replacement content for that row. The clear must render before the
	// content, otherwise it blanks the freshly drawn row. Because m.cells is a
	// Go map, replaying it in iteration order is nondeterministic, so this drives
	// the real applyDraw path (which records draw order) and asserts the content
	// survives. Run repeatedly to defeat any accidental iteration-order reliance.
	for attempt := 0; attempt < 50; attempt++ {
		model := New(20, 5, nil)
		model.applyDraw(protocol.DrawText{Row: 0, Col: 0, Text: strings.Repeat(" ", 20)})
		model.applyDraw(protocol.DrawText{Row: 0, Col: 2, Text: "HELLO"})

		stripped := ansi.Strip(model.cellLines()[0])
		if !strings.Contains(stripped, "HELLO") {
			t.Fatalf("attempt %d: clear blanked redrawn content: %q", attempt, stripped)
		}
	}
}

func TestCellbufStyleMapsProtocolAttrs(t *testing.T) {
	style := cellbufStyle(cell{fg: 0x112233, bg: 0x445566, attrs: 0x01 | 0x02 | 0x04 | 0x08 | 0x10})

	if style.Fg == nil || style.Bg == nil {
		t.Fatalf("style should carry foreground and background: %+v", style)
	}
	if !style.Attrs.Contains(cellbuf.BoldAttr) || !style.Attrs.Contains(cellbuf.ItalicAttr) || !style.Attrs.Contains(cellbuf.ReverseAttr) || !style.Attrs.Contains(cellbuf.StrikethroughAttr) {
		t.Fatalf("style attrs not mapped: %+v", style.Attrs)
	}
	if style.UlStyle != cellbuf.SingleUnderline {
		t.Fatalf("underline style = %v, want single underline", style.UlStyle)
	}
}
