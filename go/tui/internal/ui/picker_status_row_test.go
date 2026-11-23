package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const unavailableRemedy = "Run claude login in a terminal, then reopen /model."

func modelPickerFixture(selected uint16) protocol.Picker {
	return protocol.Picker{
		Visible:  true,
		Title:    "Models and connections",
		Selected: selected,
		Items: []protocol.PickerItem{
			{
				ActivationID: 1,
				Label:        "Claude Opus 4",
				Description:  "Claude Max · 5h limit resets 3:59 PM · 1000k ctx · thinking medium · tools, images, streaming",
				Group:        "Claude (subscription)",
				Annotation:   "★ favorite",
				Active:       true,
				Status:       "Ready · 45%",
				StatusTone:   generated.PickerStatusToneReady,
			},
			{
				ActivationID: 2,
				Label:        "Claude Sonnet 4",
				Description:  "Claude Max · 5h limit resets 3:40 PM · 200k ctx · thinking fixed · tools, images, streaming",
				Group:        "Claude (subscription)",
				Status:       "Ready · 82%",
				StatusTone:   generated.PickerStatusToneWarn,
			},
			{
				ActivationID: 3,
				Label:        "Claude Haiku 4",
				Description:  unavailableRemedy + " · 200k ctx",
				Group:        "Claude (subscription)",
				Status:       "Unavailable",
				StatusTone:   generated.PickerStatusToneError,
			},
			{
				ActivationID: 4,
				Label:        "Retry current connection",
				Description:  "Recheck credentials without sending your draft.",
				Group:        "Connection",
			},
		},
	}
}

// pickerRow returns the stripped floating-picker line that shows `label`, without its border.
func pickerRow(t *testing.T, lines []string, label string) string {
	t.Helper()
	for _, line := range lines {
		if strings.Contains(line, label) {
			return strings.TrimRight(strings.Trim(line, "│"), " ")
		}
	}
	t.Fatalf("no picker row shows %q:\n%s", label, strings.Join(lines, "\n"))
	return ""
}

func TestModelPickerRowsKeepChipAndCurrentMarkerAtEveryWidth(t *testing.T) {
	for _, tc := range []struct {
		width       uint16
		description string // "full", "short", or "none" for the active Opus row
	}{
		{width: 60, description: "none"},
		{width: 80, description: "short"},
		{width: 120, description: "short"},
	} {
		model := New(tc.width, 24, nil)
		picker := modelPickerFixture(1)
		lines := strings.Split(ansi.Strip(model.renderFloatingPicker(picker, protocol.PickerPreview{})), "\n")

		opus := pickerRow(t, lines, "Claude Opus 4")
		sonnet := pickerRow(t, lines, "Claude Sonnet 4")
		haiku := pickerRow(t, lines, "Claude Haiku 4")

		// The chip is never truncated, always ends the row, and carries a tone glyph as well as color.
		for _, row := range []struct{ text, chip string }{
			{opus, "✓ Ready · 45%"},
			{sonnet, "! Ready · 82%"},
			{haiku, "✗ Unavailable"},
		} {
			if !strings.HasSuffix(row.text, row.chip) {
				t.Fatalf("width %d: row should end with chip %q: %q", tc.width, row.chip, row.text)
			}
		}
		if !strings.Contains(opus, "● Claude Opus 4") || !strings.Contains(opus, "★") {
			t.Fatalf("width %d: current favorite row should show the dot and the star: %q", tc.width, opus)
		}
		if !strings.Contains(sonnet, "▌   Claude Sonnet 4") {
			t.Fatalf("width %d: inactive siblings should pad by the dot's width: %q", tc.width, sonnet)
		}
		switch tc.description {
		case "none":
			if strings.Contains(opus, "Claude M") {
				t.Fatalf("width %d: a short row should drop the description: %q", tc.width, opus)
			}
		case "short":
			if !strings.Contains(opus, "★ favorite  Claude M") || !strings.Contains(opus, "…") {
				t.Fatalf("width %d: the description should shorten at its end: %q", tc.width, opus)
			}
		}
		if tc.width == 120 && !strings.Contains(opus, "Claude Max · 5h limit resets 3:59 PM") {
			t.Fatalf("width 120 should keep the account and reset time: %q", opus)
		}
	}
}

func TestPickerStatusRowGivesWayInPriorityOrder(t *testing.T) {
	item := modelPickerFixture(0).Items[0]
	// Label 13, dot 2, chip "✓ Ready · 45%" 13, separators 2 each.
	for _, tc := range []struct {
		avail      int
		annotation string
		active     bool
		label      string
		chip       string
	}{
		{avail: 44, annotation: "★ favorite", active: true, label: "Claude Opus 4", chip: "✓ Ready · 45%"},
		{avail: 40, annotation: "★", active: true, label: "Claude Opus 4", chip: "✓ Ready · 45%"},
		{avail: 30, annotation: "", active: true, label: "Claude Opus 4", chip: "✓ Ready · 45%"},
		{avail: 28, annotation: "", active: false, label: "Claude Opus 4", chip: "✓ Ready · 45%"},
		{avail: 27, annotation: "", active: false, label: "Claude Opus…", chip: "✓ Ready · 45%"},
		{avail: 20, annotation: "", active: false, label: "Claude Opus…", chip: "✓ Rea…"},
	} {
		layout := layoutPickerStatusRow(item, true, tc.avail)
		if layout.description != "" || layout.annotation != tc.annotation || layout.active != tc.active || layout.label != tc.label || layout.chip != tc.chip {
			t.Fatalf("avail %d: got %+v", tc.avail, layout)
		}
		if width := layout.leftWidth() + layout.gap + displayWidth(layout.chip); width > tc.avail {
			t.Fatalf("avail %d: row is %d columns wide", tc.avail, width)
		}
	}
	if layout := layoutPickerStatusRow(item, true, 70); !strings.HasSuffix(layout.description, "…") || displayWidth(layout.description) < pickerMinDescription {
		t.Fatalf("a wide row should shorten the description's end: %+v", layout)
	}
}

func TestPickerFooterShowsTheSelectedUnavailableRowsRemedy(t *testing.T) {
	model := New(120, 24, nil)

	footer := ansi.Strip(model.renderPickerHelp(modelPickerFixture(2), 108))
	if !strings.Contains(footer, unavailableRemedy) || strings.Contains(footer, "Enter choose") {
		t.Fatalf("an unavailable selection should put its remedy in the footer: %q", footer)
	}

	// A narrow footer keeps the start of the description and shortens its end.
	footer = ansi.Strip(model.renderPickerHelp(modelPickerFixture(2), 68))
	if !strings.Contains(footer, "Run claude login") || !strings.HasSuffix(strings.TrimSpace(footer), "…") {
		t.Fatalf("a narrow footer should shorten the remedy's end: %q", footer)
	}

	footer = ansi.Strip(model.renderPickerHelp(modelPickerFixture(0), 68))
	if !strings.Contains(footer, "Enter choose") || strings.Contains(footer, "Claude Max") {
		t.Fatalf("a ready selection keeps the key hints: %q", footer)
	}
}

func TestPickerRowsWithoutStatusKeepTheirInlineLayout(t *testing.T) {
	model := New(80, 24, nil)
	files := protocol.Picker{Visible: true, Title: "Files", Items: []protocol.PickerItem{
		{Label: "main.ex", Description: "lib/minga"},
		{Label: "editor.ex", Description: "lib/minga_editor"},
	}}
	rows := model.renderPickerList(files.Title, files, 4, 60)
	selected := ansi.Strip(rows[2])
	if !strings.HasPrefix(selected, " ▌ ") || !strings.Contains(selected, "main.ex  lib/minga") || strings.Contains(selected, "●") {
		t.Fatalf("file rows keep marker, label, and inline path with no current-value slot: %q", selected)
	}
	other := ansi.Strip(rows[3])
	if !strings.HasPrefix(other, "   ") || strings.HasPrefix(other, "     ") {
		t.Fatalf("file rows without a current value get no extra padding: %q", other)
	}

	levels := protocol.Picker{Visible: true, Title: "Thinking", Items: []protocol.PickerItem{
		{Label: "low"},
		{Label: "medium", Active: true},
	}}
	rows = model.renderPickerList(levels.Title, levels, 4, 40)
	if low, medium := ansi.Strip(rows[2]), ansi.Strip(rows[3]); !strings.Contains(medium, "● ") || !strings.Contains(low, "▌   ") {
		t.Fatalf("the current value shows a dot and its siblings pad to align: %q / %q", low, medium)
	}
}
