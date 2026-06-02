package ui

import (
	"bytes"
	"runtime"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/cellbuf"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	zone "github.com/lrstanley/bubblezone"
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
		ID:           7,
		ContentEpoch: 2,
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

func TestApplyWindowDeltaInvalidatesMissingRetainedRowRef(t *testing.T) {
	model := New(80, 24, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{ID: 1, ContentHash: 11, Text: "old one"}}})
	model.putWindow(protocol.WindowContent{ID: 8, ContentEpoch: 3, Rows: []protocol.WindowRow{{Text: "other"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{Ref: true, ID: 99, ContentHash: 99}}})

	if _, ok := model.windows[7]; ok {
		t.Fatalf("window with missing retained row ref should be invalidated: %+v", model.windows[7])
	}
	if len(model.windowOrder) != 1 || model.windowOrder[0] != 8 {
		t.Fatalf("window order should drop invalidated window: %+v", model.windowOrder)
	}
}

func TestApplyWindowDeltaInvalidatesHashMismatchedRetainedRowRef(t *testing.T) {
	model := New(80, 24, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{ID: 1, ContentHash: 11, Text: "old one"}}})
	model.putWindow(protocol.WindowContent{ID: 8, ContentEpoch: 3, Rows: []protocol.WindowRow{{Text: "other"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 2, Rows: []protocol.WindowRow{{Ref: true, ID: 1, ContentHash: 99}}})

	if _, ok := model.windows[7]; ok {
		t.Fatalf("window with hash-mismatched retained row ref should be invalidated: %+v", model.windows[7])
	}
	if len(model.windowOrder) != 1 || model.windowOrder[0] != 8 {
		t.Fatalf("window order should drop invalidated window: %+v", model.windowOrder)
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
	_ = model.applyCommands([]protocol.Command{{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiTheme, Theme: protocol.Theme{Colors: map[byte]uint32{themeEditorBG: 0x010203, themeSelectionBG: 0x112233}}}}})

	if got := model.activePalette.colors[themeEditorBG]; got != 0x010203 {
		t.Fatalf("editor background slot = 0x%06X, want 0x010203", got)
	}
	if got := model.activePalette.colors[themeSelectionBG]; got != 0x112233 {
		t.Fatalf("selection slot = 0x%06X, want 0x112233", got)
	}
}

func TestSemanticWindowUsesThemeForSelectionOverlay(t *testing.T) {
	model := New(20, 4, nil)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{themeSelectionBG: 0x112233}})
	style := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Selection: protocol.Selection{Type: 1, StartRow: 0, StartCol: 1, EndRow: 0, EndCol: 3}}, 0, 1)

	if style.GetBackground() != model.palette().Selection() {
		t.Fatalf("selection overlay should use theme selection color")
	}
}

func TestSemanticWindowUsesKindSpecificDocumentHighlightTheme(t *testing.T) {
	model := New(20, 4, nil)
	model.activePalette = paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{themeHighlightReadBG: 0x223344, themeHighlightWriteBG: 0x334455, themeSelectionBG: 0x445566}})
	readStyle := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Highlights: []protocol.DocumentHighlight{{Kind: 2, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1}}}, 0, 0)
	writeStyle := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Highlights: []protocol.DocumentHighlight{{Kind: 3, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1}}}, 0, 0)
	textStyle := model.applyWindowOverlays(lipgloss.NewStyle(), protocol.WindowContent{Highlights: []protocol.DocumentHighlight{{Kind: 1, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1}}}, 0, 0)

	if readStyle.GetBackground() != lipgloss.Color("#223344") || writeStyle.GetBackground() != lipgloss.Color("#334455") || textStyle.GetBackground() != lipgloss.Color("#445566") {
		t.Fatalf("document highlight colors should be kind-specific: read=%v write=%v text=%v", readStyle.GetBackground(), writeStyle.GetBackground(), textStyle.GetBackground())
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
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{Verticals: []protocol.VerticalSeparator{{Col: 2, StartRow: 1, EndRow: 1}}}}}
	lines := model.withSplitSeparators([]string{"\x1b[1mabcd\x1b[0m", "efgh"})
	if !strings.Contains(lines[0], "│") {
		t.Fatalf("vertical replacement should render on visible content: %q", lines[0])
	}
	if !strings.Contains(lines[0], "\x1b[1md") {
		t.Fatalf("vertical replacement should resume existing ANSI styling after separator: %q", lines[0])
	}
}

func TestSplitSeparatorsRenderOnBlankRow(t *testing.T) {
	model := New(24, 6, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{Horizontals: []protocol.HorizontalSeparator{{Row: 1, Col: 0, Width: 16, Filename: "main.ex"}}}}}
	lines := model.withSplitSeparators([]string{"", ""})
	if !strings.Contains(ansi.Strip(lines[0]), "main.ex") || !strings.Contains(ansi.Strip(lines[0]), "─") {
		t.Fatalf("horizontal separator should render on blank row: %q", lines[0])
	}
}

func TestSplitSeparatorsNormalizeAgainstHeaderAndFileTree(t *testing.T) {
	model := New(80, 6, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 24, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}},
		generated.OPGuiSplitSeparators: {Splits: protocol.SplitSeparators{
			Verticals:   []protocol.VerticalSeparator{{Col: 24, StartRow: 1, EndRow: 2}},
			Horizontals: []protocol.HorizontalSeparator{{Row: 2, Col: 24, Width: 2}},
		}},
	}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "body-0"}, {Text: "body-1"}, {Text: "body-2"}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View()), "\n")
	if len(lines) < 3 {
		t.Fatalf("unexpected view lines: %+v", lines)
	}
	if got := strings.Index(lines[1], "│"); got != 24 {
		t.Fatalf("vertical separator should land at visible column 24 after normalization, got %d in %q", got, lines[1])
	}
	if got := strings.Index(lines[2], "─"); got != 24 {
		t.Fatalf("horizontal separator should land at visible column 24 after normalization, got %d in %q", got, lines[2])
	}
}

func TestFileTreeWidthRespectsProtocolGeometryAndSafetyClamp(t *testing.T) {
	if got := fileTreeWidth(80, protocol.FileTree{Width: 18}); got != 18 {
		t.Fatalf("file tree width = %d, want narrow protocol width 18", got)
	}
	if got := fileTreeWidth(80, protocol.FileTree{Width: 36}); got != 36 {
		t.Fatalf("file tree width = %d, want protocol width 36", got)
	}
	if got := fileTreeWidth(80, protocol.FileTree{Width: 120}); got != 79 {
		t.Fatalf("file tree width = %d, want terminal clamp 79", got)
	}
}

func TestFileTreeReservesVisibleEmptyState(t *testing.T) {
	model := New(80, 6, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Status: 2, Width: 18, Root: "/repo"}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 18, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View()), "\n")
	if len(lines) < 3 {
		t.Fatalf("visible empty file tree should render reserved sidebar: %+v", lines)
	}
	if !strings.Contains(lines[2], "No files") {
		t.Fatalf("empty file tree should render status row: %q", lines[2])
	}
	if got := strings.Index(lines[1], "pane"); got != 18 {
		t.Fatalf("empty file tree should reserve protocol width, got pane at %d in %q", got, lines[1])
	}
}

func TestSemanticWindowsRespectProtocolFileTreeWidth(t *testing.T) {
	model := New(80, 6, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 36, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 36, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View()), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with file tree width alignment: %+v", lines)
	}
	if got := strings.Index(lines[1], "pane"); got != 36 {
		t.Fatalf("file tree width should follow protocol geometry without a gap, got %d in %q", got, lines[1])
	}
}

func TestApplyWindowDeltaAppliesScrollLeftSetAndCropsRendering(t *testing.T) {
	model := New(20, 6, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeft: 0, Rows: []protocol.WindowRow{{Text: "abcdef"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeftSet: true, ScrollLeft: 2})

	window := model.windows[7]
	if window.ScrollLeft != 2 {
		t.Fatalf("scroll left should update from matching-epoch delta, got %d", window.ScrollLeft)
	}
	rendered := ansi.Strip(model.renderSemanticContentRow(window, 0, 4))
	if !strings.HasPrefix(rendered, "cdef") {
		t.Fatalf("cropped rendering should start at the updated scroll offset, got %q", rendered)
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

func TestSemanticWindowsUsePaneGeometryRects(t *testing.T) {
	model := New(24, 6, nil)
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "left"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 0, Width: 10, Height: 1}}})
	model.putWindow(protocol.WindowContent{ID: 2, Rows: []protocol.WindowRow{{Text: "right"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 12, Width: 10, Height: 1}}})

	lines := ansi.Strip(strings.Join(model.semanticLines(), "\n"))
	first := strings.Split(lines, "\n")[0]
	if !strings.Contains(first, "left") || !strings.Contains(first, "right") {
		t.Fatalf("semantic windows should compose into a body canvas: %q", first)
	}
	if got := strings.Index(first, "right"); got != 12 {
		t.Fatalf("right window should start at column 12, got %d in %q", got, first)
	}
}

func TestSemanticWindowsRespectHeaderRowOffset(t *testing.T) {
	model := New(24, 6, nil)
	model.title = "Header"
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 0, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View()), "\n")
	if len(lines) < 2 || !strings.Contains(lines[1], "pane") {
		t.Fatalf("semantic window should render on first body row after header: %+v", lines)
	}
}

func TestSemanticWindowsRespectFileTreeOffset(t *testing.T) {
	model := New(80, 6, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiFileTree: {Tree: protocol.FileTree{Visible: true, Width: 24, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}}}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 24, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View()), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with file tree offset: %+v", lines)
	}
	if got := strings.Index(lines[1], "pane"); got != 24 {
		t.Fatalf("file tree offset should leave pane at column 24, got %d in %q", got, lines[1])
	}
}

func TestSemanticWindowsRespectSidebarOffset(t *testing.T) {
	model := New(80, 6, nil)
	model.title = "Header"
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiSidebars: {Sidebars: protocol.Sidebars{Visible: true, Items: []protocol.Sidebar{{ID: "files", DisplayName: "Files", SemanticKind: "file_tree", PreferredWidth: 18, Visible: true}}}}}
	model.putWindow(protocol.WindowContent{ID: 1, Rows: []protocol.WindowRow{{Text: "pane"}}, GeometrySet: true, Geometry: protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 1, Col: 18, Width: 8, Height: 1}}})
	model.viewport.SetContent(model.content())

	lines := strings.Split(ansi.Strip(model.View()), "\n")
	if len(lines) < 2 {
		t.Fatalf("semantic window should render with sidebar offset: %+v", lines)
	}
	if got := strings.Index(lines[1], "pane"); got != 18 {
		t.Fatalf("sidebar offset should leave pane at column 18, got %d in %q", got, lines[1])
	}
}

func TestSemanticRowsRespectScrollLeftAndIndentGuides(t *testing.T) {
	model := New(12, 6, nil)
	model.indentGuides[7] = protocol.IndentGuides{WindowID: 7, TabWidth: 2, GuideCols: []uint16{2}}
	window := protocol.WindowContent{ID: 7, ScrollLeft: 2, Rows: []protocol.WindowRow{{Text: "    x"}}}

	rendered := ansi.Strip(model.renderSemanticContentRow(window, 0, 8))
	if !strings.HasPrefix(rendered, "│ ") || !strings.Contains(rendered, "x") {
		t.Fatalf("scroll-left rendering should keep display-column guides aligned: %q", rendered)
	}
}

func TestOverlayDeltaPreservesExistingScrollLeft(t *testing.T) {
	model := New(20, 6, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeft: 4, Rows: []protocol.WindowRow{{Text: "hello"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 9, CursorRow: 1, CursorCol: 2, CursorShape: 1, Cursorline: protocol.Cursorline{Visible: true, Row: 0, BG: 0x123456}})

	window := model.windows[7]
	if window.ScrollLeft != 4 {
		t.Fatalf("overlay delta should preserve scroll left, got %d", window.ScrollLeft)
	}
}

func TestDeltaForMissingWindowIsIgnored(t *testing.T) {
	model := New(20, 6, nil)
	model.applyWindowDelta(protocol.WindowContent{ID: 99, ContentEpoch: 1, CursorRow: 1, CursorCol: 2, CursorShape: 1})

	if len(model.windows) != 0 {
		t.Fatalf("missing window delta should be ignored, got %+v", model.windows)
	}
}

func TestStaleContentEpochDeltaIsIgnored(t *testing.T) {
	model := New(20, 6, nil)
	model.putWindow(protocol.WindowContent{ID: 7, ContentEpoch: 9, ScrollLeft: 4, CursorRow: 3, CursorCol: 4, CursorShape: 1, Rows: []protocol.WindowRow{{Text: "hello"}}})

	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 8, CursorRow: 1, CursorCol: 2, CursorShape: 2, ScrollLeft: 0, Rows: []protocol.WindowRow{{Text: "changed"}}})

	window := model.windows[7]
	if window.ContentEpoch != 9 || window.CursorRow != 3 || window.CursorCol != 4 || window.CursorShape != 1 || window.ScrollLeft != 4 || window.Rows[0].Text != "hello" {
		t.Fatalf("stale delta should be ignored, got %+v", window)
	}
}

func TestSemanticDeltaClearsStaleOverlaysAndCursorline(t *testing.T) {
	model := New(20, 6, nil)
	model.putWindow(protocol.WindowContent{
		ID:             7,
		ContentEpoch:   4,
		Cursorline:     protocol.Cursorline{Visible: true, Row: 0, BG: 0x123456},
		Selection:      protocol.Selection{Type: 1, StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1},
		SearchSet:      true,
		SearchMatches:  []protocol.SearchMatch{{Row: 0, StartCol: 0, EndCol: 1, Current: true}},
		DiagnosticsSet: true,
		Diagnostics:    []protocol.DiagnosticRange{{StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1, Severity: 0}},
		HighlightsSet:  true,
		Highlights:     []protocol.DocumentHighlight{{StartRow: 0, StartCol: 0, EndRow: 0, EndCol: 1, Kind: 2}},
		AnnotationsSet: true,
		Annotations:    []protocol.LineAnnotation{{Row: 0, Kind: 1, Text: "note"}},
		Rows:           []protocol.WindowRow{{Text: "hello"}},
	})

	before := model.applyWindowOverlays(lipgloss.NewStyle(), model.windows[7], 0, 0)
	model.applyWindowDelta(protocol.WindowContent{ID: 7, ContentEpoch: 4, Cursorline: protocol.Cursorline{}, SelectionSet: true, Selection: protocol.Selection{}, SearchSet: true, SearchMatches: []protocol.SearchMatch{}, DiagnosticsSet: true, Diagnostics: []protocol.DiagnosticRange{}, HighlightsSet: true, Highlights: []protocol.DocumentHighlight{}, AnnotationsSet: true, Annotations: []protocol.LineAnnotation{}})
	window := model.windows[7]
	if window.Cursorline.Visible || window.Selection.Type != 0 || len(window.SearchMatches) != 0 || len(window.Diagnostics) != 0 || len(window.Highlights) != 0 || len(window.Annotations) != 0 {
		t.Fatalf("stale overlay state should be cleared by empty deltas: %+v", window)
	}
	if got := strings.TrimSpace(model.renderRowAnnotations(window, 0)); got != "" {
		t.Fatalf("annotations should no longer render after clear: %q", got)
	}
	after := model.applyWindowOverlays(lipgloss.NewStyle(), window, 0, 0)
	if before.GetBackground() == after.GetBackground() {
		t.Fatalf("selection/highlight overlays should stop affecting rendering after clear: before=%v after=%v", before.GetBackground(), after.GetBackground())
	}
}

func TestSemanticMouseRoutesModelineAndFileTreeZones(t *testing.T) {
	model := New(60, 12, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {Status: protocol.StatusBar{Left: []protocol.StatusSegment{{Text: " save ", Command: "save"}}, Right: []protocol.StatusSegment{{Text: " quit", Command: "quit"}}}},
		generated.OPGuiFileTree:  {Tree: protocol.FileTree{Visible: true, Width: 24, Rows: []protocol.FileTreeRow{{ID: "row-0", Name: "row-0"}, {ID: "row-1", Name: "row-1"}}}},
	}
	model.viewport.SetContent(model.content())
	_ = model.View()

	saveZone := waitForZone(t, model, zoneIDModelineCommand("save"))
	cmd, ok := model.semanticMousePacket(tea.MouseMsg{Button: tea.MouseButtonLeft, Action: tea.MouseActionPress, X: saveZone.StartX + 1, Y: saveZone.StartY})
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIExecuteCommand("save")) {
		t.Fatalf("modeline click should route execute command, ok=%v packet=%v", ok, cmd)
	}
	if _, ok := model.semanticMousePacket(tea.MouseMsg{Button: tea.MouseButtonRight, Action: tea.MouseActionPress, X: saveZone.StartX + 1, Y: saveZone.StartY}); ok {
		t.Fatalf("non-left clicks should fall back")
	}

	rowZone := waitForZone(t, model, zoneIDFileTreeRow(0))
	cmd, ok = model.semanticMousePacket(tea.MouseMsg{Button: tea.MouseButtonLeft, Action: tea.MouseActionPress, X: rowZone.StartX + 1, Y: rowZone.StartY})
	if !ok || !bytes.Equal(cmd, protocol.EncodeGUIFileTreeClick(0)) {
		t.Fatalf("file-tree click should route file-tree packet, ok=%v packet=%v", ok, cmd)
	}
	if _, ok := model.semanticMousePacket(tea.MouseMsg{Button: tea.MouseButtonLeft, Action: tea.MouseActionPress, X: rowZone.EndX + 10, Y: rowZone.EndY + 10}); ok {
		t.Fatalf("out-of-bounds clicks should fall back")
	}
}

func waitForZone(t *testing.T, model Model, id string) *zone.ZoneInfo {
	t.Helper()
	for i := 0; i < 1000; i++ {
		if info := model.zones.Get(id); info != nil {
			return info
		}
		runtime.Gosched()
	}
	t.Fatalf("zone %q was not registered", id)
	return nil
}
