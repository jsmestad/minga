package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func stripLines(lines []string) []string {
	text := make([]string, len(lines))
	for i, line := range lines {
		text[i] = strings.TrimRight(ansi.Strip(line), " ")
	}
	return text
}

// column is the display column where substr starts in line.
func column(line, substr string) int {
	return ansi.StringWidth(line[:strings.Index(line, substr)])
}

func TestEmptyPickerShowsWhatHappenedAboveItsNextStepRows(t *testing.T) {
	model := New(80, 24, nil)
	picker := protocol.Picker{
		Visible: true,
		Title:   "Search project",
		Items: []protocol.PickerItem{
			{ActivationID: 1, Label: "Search ignored files too", Annotation: "-- -u"},
			{ActivationID: 2, Label: "Search hidden files too", Annotation: "--hidden"},
		},
		Empty: &generated.EmptyList{Title: "No results for “limit_lable”.", Why: "Ignored and hidden files were skipped."},
	}

	text := stripLines(model.renderPickerList(picker.Title, picker, 12, 60))
	inset := strings.Repeat(" ", emptyStateInset.cols())
	// Title row, separator, the panel inset row, then the title and why lines on the empty state's inset.
	if text[2] != "" || text[3] != inset+"No results for “limit_lable”." || text[4] != inset+"Ignored and hidden files were skipped." {
		t.Fatalf("empty header not drawn in anatomy order:\n%s", strings.Join(text, "\n"))
	}
	// One blank row between the why line and the action rows, then the rows with their keys.
	if text[5] != "" || !strings.Contains(text[6], "Search ignored files too") || !strings.Contains(text[6], "-- -u") {
		t.Fatalf("next-step rows do not follow the header:\n%s", strings.Join(text, "\n"))
	}
	// The title shares its leading edge with the row labels.
	if column(text[3], "No results") != column(text[6], "Search ignored") {
		t.Fatalf("the title and the row labels start at different columns:\n%s", strings.Join(text, "\n"))
	}
}

func TestEmptyPickerHintsNameTheKeysThatMoveAndRunItsRows(t *testing.T) {
	model := New(80, 24, nil)
	picker := protocol.Picker{Visible: true, Title: "Switch project", Empty: &generated.EmptyList{Title: "No projects yet."}}

	prompt := ansi.Strip(model.renderPickerHelp(picker, 60))
	if !strings.Contains(prompt, "⌃J ⌃K move") || !strings.Contains(prompt, "esc close") {
		t.Fatalf("a prompt moves with ⌃J ⌃K: %q", prompt)
	}

	picker.ListKeys = true
	list := ansi.Strip(model.renderPickerHelp(picker, 60))
	if !strings.Contains(list, "j k move") || !strings.Contains(list, "q close") {
		t.Fatalf("a list with nothing to type moves with j k: %q", list)
	}
}

func TestEmptyListActionsDrawAFixedKeyColumnAndTheSelection(t *testing.T) {
	model := New(80, 24, nil)
	empty := generated.EmptyList{
		Title:    "Nothing to commit on main.",
		Selected: 1,
		Actions: []generated.EmptyListAction{
			{ID: "log", Key: "l", Label: "Show log"},
			{ID: "blame", Key: "SPC g B", Label: "Blame this file"},
		},
	}

	text := stripLines(emptyListActions(empty, 40, model.pickerEmptyColors()))
	if len(text) != 2 {
		t.Fatalf("one row per action, got %d:\n%s", len(text), strings.Join(text, "\n"))
	}
	if column(text[0], "Show log") != column(text[1], "Blame this file") {
		t.Fatalf("labels must start at one column after the widest key:\n%s", strings.Join(text, "\n"))
	}
	if got, want := column(text[0], "Show log"), emptyStateInset.cols()+len("SPC g B")+emptyStateKeyColumnGap.cols(); got != want {
		t.Fatalf("label column %d, want %d", got, want)
	}
}
