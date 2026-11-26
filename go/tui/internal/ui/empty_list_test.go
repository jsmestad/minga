package ui

import (
	"bytes"
	"fmt"
	"slices"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

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

func TestEmptyPickerFooterDrawsTheHintsTheBEAMSends(t *testing.T) {
	model := New(80, 24, nil)
	picker := protocol.Picker{
		Visible: true,
		Title:   "Switch project",
		Empty:   &generated.EmptyList{Title: "No projects yet."},
		// A user who rebinds the picker's keys sees them here: the frontend draws what it is sent.
		Hints: []generated.KeyHint{{Keys: "n p", Word: "move"}, {Keys: "↩", Word: "run"}, {Keys: "x", Word: "close"}},
	}

	footer := ansi.Strip(model.renderPickerHelp(picker, 60))
	for _, want := range []string{"n p move", "↩ run", "x close"} {
		if !strings.Contains(footer, want) {
			t.Fatalf("the footer must draw the BEAM's hint %q: %q", want, footer)
		}
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

func cleanTree() generated.EmptyList {
	return generated.EmptyList{
		Glyph: "●",
		Title: "Nothing to commit on main.",
		Why:   "2 commits to push.",
		Actions: []generated.EmptyListAction{
			{ID: "git_status_push", Key: "P", Label: "Push to remote"},
			{ID: "git_status_pull", Key: "l", Label: "Pull from remote"},
		},
	}
}

func TestCleanTreeDrawsItsAnatomyBelowThePanelTitleAndRecordsEachStepForClicks(t *testing.T) {
	model := New(80, 24, nil)
	empty := cleanTree()
	git := protocol.GitStatus{PanelID: 9, RepoState: 0, Branch: "main", Ahead: 2, Empty: &empty}
	hits := &gitStatusHits{box: uiRect{Width: 40, Height: 12}}

	text := stripLines(model.renderGitStatusPanel(git, lipgloss.NewStyle(), lipgloss.NewStyle(), 40, 12, hits))
	joined := strings.Join(text, "\n")
	if strings.Contains(text[0], "Clean") {
		t.Fatalf("a clean tree with an empty list does not also print the short Clean title:\n%s", joined)
	}
	for _, want := range []string{"● Nothing to commit on main.", "2 commits to push.", "Push to remote", "Pull from remote"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("clean tree is missing %q:\n%s", want, joined)
		}
	}
	if !slices.Equal(hits.actions, []string{"git_status_push", "git_status_pull"}) {
		t.Fatalf("each next step must be clickable by its command, got %v", hits.actions)
	}
}

func TestEmptyFolderDrawsItsNextStepsInTheTreesOwnKeys(t *testing.T) {
	model := New(80, 24, nil)
	empty := generated.EmptyList{
		Title:   "notes/ is empty.",
		Why:     "Make the first file or folder here.",
		Actions: []generated.EmptyListAction{{ID: "tree_new_file", Key: "a", Label: "New file"}, {ID: "tree_new_folder", Key: "A", Label: "New folder"}},
	}

	text := strings.Join(stripLines(model.renderEmptyFolder(nil, empty, 40, 12)), "\n")
	for _, want := range []string{"notes/ is empty.", "Make the first file or folder here.", "New file", "New folder"} {
		if !strings.Contains(text, want) {
			t.Fatalf("empty folder is missing %q:\n%s", want, text)
		}
	}
}

func TestAnEmptyPickerOnAShortTerminalShowsEveryNextStep(t *testing.T) {
	model := New(80, 24, nil)
	model.layout = model.computeLayout()
	picker := protocol.Picker{
		Visible: true,
		Title:   "Switch project",
		Items: []protocol.PickerItem{
			{ActivationID: 1, Label: "Add a folder", Annotation: "SPC p a"},
			{ActivationID: 2, Label: "Open a file", Annotation: "SPC f f"},
		},
		Empty: &generated.EmptyList{Title: "No projects yet.", Why: "Minga remembers the folders you open."},
		Hints: []generated.KeyHint{{Keys: "↩", Word: "run"}},
	}

	text := strings.Join(stripLines(model.renderPicker(picker, protocol.PickerPreview{})), "\n")
	for _, want := range []string{"No projects yet.", "Add a folder", "Open a file", "↩ run"} {
		if !strings.Contains(text, want) {
			t.Fatalf("an 80x24 empty picker is missing %q:\n%s", want, text)
		}
	}
}

func TestCleanTreeKeepsItsStepsBelowARetryRow(t *testing.T) {
	model := New(80, 24, nil)
	empty := cleanTree()
	git := protocol.GitStatus{PanelID: 9, Branch: "main", Empty: &empty}
	git.Toast.Visible, git.Toast.Action, git.Toast.ID = true, 1, 5
	hits := &gitStatusHits{box: uiRect{Width: 40, Height: 12}}

	text := strings.Join(stripLines(model.renderGitStatusPanel(git, lipgloss.NewStyle(), lipgloss.NewStyle(), 40, 12, hits)), "\n")
	for _, want := range []string{"Pull & Retry (r)", "Nothing to commit on main.", "Push to remote"} {
		if !strings.Contains(text, want) {
			t.Fatalf("a clean tree with a retry toast is missing %q:\n%s", want, text)
		}
	}
}

func TestEmptyListCutTextKeepsItsTrailingInset(t *testing.T) {
	model := New(80, 24, nil)
	empty := generated.EmptyList{
		Title:   "No one's at the table yet.",
		Why:     "Tasks you start, and the conversations you open, wait here while they work.",
		Actions: []generated.EmptyListAction{{ID: "new", Key: "c", Label: "Start a new task that works in the background"}},
	}
	lines := stripLines(emptyListHeader(empty, 40, model.pickerEmptyColors(), model.palette()))
	lines = append(lines, stripLines(emptyListActions(empty, 40, model.pickerEmptyColors()))...)
	for _, line := range lines {
		if strings.Contains(line, "…") && ansi.StringWidth(line) > 40-listRowTrailingInset.cols() {
			t.Fatalf("a cut line keeps at least one column after the ellipsis: %q", line)
		}
	}
	if !strings.Contains(strings.Join(lines, "\n"), "…") {
		t.Fatalf("the fixture must cut a line: %q", lines)
	}
}

func TestAnEmptyPickerListRespectsTheReturnBindingWithALocalPreview(t *testing.T) {
	for _, selects := range []bool{true, false} {
		t.Run(fmt.Sprintf("Enter selects: %v", selects), func(t *testing.T) {
			out := make(chan []byte, 16)
			model := New(80, 24, out)
			payload := protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: protocol.Picker{
				Visible: true, Generation: 5, Selected: 0, SelectedID: 1,
				Items: []protocol.PickerItem{
					{ActivationID: 1, Label: "Add a folder", Annotation: "SPC p a"},
					{ActivationID: 2, Label: "Open a file", Annotation: "SPC f f"},
				},
				Empty:        &generated.EmptyList{Title: "No projects yet."},
				ListKeys:     true,
				EnterSelects: selects,
				MovementKeys: []protocol.PickerMovementKey{
					{Codepoint: 'j', Modifiers: 0, Delta: 1},
					{Codepoint: 'k', Modifiers: 0, Delta: -1},
				},
			}}
			model.chrome[generated.OPGuiPicker] = payload
			model.applyMutation(focusOwnerCommand(0, 8))
			model = settle(model)
			markPickerFitReported(&model)
			drainOutboundPackets(out)

			updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
			model = updated.(Model)
			if got := model.effectivePickerIndex(model.chrome[generated.OPGuiPicker].Picker); got != 1 {
				t.Fatalf("j must preview the next step at once, highlighted %d", got)
			}
			drainOutboundPackets(out)

			model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter}))
			packets := drainOutboundPackets(out)
			if selects {
				want := pickerActivationPacket(5, 2)
				if len(packets) != 1 || !bytes.Equal(packets[0], want) {
					t.Fatalf("Return must activate the highlighted row exactly once: got %x, want %x", packets, want)
				}
			} else if len(packets) != 1 || packets[0][0] != generated.OPKeyPress || codepoint(packets[0]) != 13 {
				t.Fatalf("remapped Return must reach the BEAM as a key, not activate the preview: %x", packets)
			}
		})
	}
}

func TestANarrowSidebarCutsActionLabelsAtAWordBoundary(t *testing.T) {
	for _, tc := range []struct {
		label string
		width int
		want  string
	}{
		{"Pull from remote", 16, "Pull from remote"},
		{"Pull from remote", 14, "Pull from…"},
		{"Pull from remote", 10, "Pull from…"},
		{"Fetch from remote", 14, "Fetch from…"},
		{"Fetch from remote", 7, "Fetch…"},
		{"Synchronise", 6, "Synch…"},
	} {
		if got := truncateAtWord(tc.label, tc.width); got != tc.want {
			t.Fatalf("truncateAtWord(%q, %d) = %q, want %q", tc.label, tc.width, got, tc.want)
		}
	}

	empty := cleanTree()
	empty.Actions = append(empty.Actions, generated.EmptyListAction{ID: "git_status_fetch", Key: "f", Label: "Fetch from remote"})
	lines := stripLines(emptyListActions(empty, 20, emptyListColors{}))
	for _, line := range lines {
		if strings.Contains(line, "remo…") || strings.Contains(line, "rem…") {
			t.Fatalf("an action label was cut inside a word: %q", line)
		}
	}
}

func TestTheCleanTreeGlyphIsDrawnInTheDoneRole(t *testing.T) {
	p := paletteFromTheme(protocol.Theme{Colors: map[byte]uint32{
		byte(generated.ColorRoleDone):    0xA6D189,
		byte(generated.ColorRoleFailure): 0xE78284,
	}})
	text := lipgloss.Color("#123456")
	if got := emptyStateGlyphColor("●", text, p); got != p.Role(generated.ColorRoleDone) {
		t.Fatalf("● should take the done role, got %v", got)
	}
	if got := emptyStateGlyphColor("◆", text, p); got != p.Role(generated.ColorRoleFailure) {
		t.Fatalf("◆ should take the failure role, got %v", got)
	}
	if got := emptyStateGlyphColor("", text, p); got != text {
		t.Fatalf("no glyph keeps the title colour, got %v", got)
	}

	empty := cleanTree()
	joined := strings.Join(emptyListHeader(empty, 40, emptyListColors{text: text}, p), "\n")
	r, g, b, _ := p.Role(generated.ColorRoleDone).RGBA()
	want := fmt.Sprintf("38;2;%d;%d;%d", r>>8, g>>8, b>>8)
	glyph := strings.Index(joined, "●")
	if glyph < 0 {
		t.Fatalf("the clean-tree header omitted ●: %q", joined)
	}
	colorStart := strings.LastIndex(joined[:glyph], "\x1b[")
	if colorStart < 0 || !strings.Contains(joined[colorStart:glyph], want) {
		t.Fatalf("the clean-tree header should draw ● in the done colour %s, got %q", want, joined)
	}
}
