package ui

import (
	"strings"
	"testing"

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
