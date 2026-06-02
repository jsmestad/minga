package ui

import (
	"strings"
	"testing"

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
