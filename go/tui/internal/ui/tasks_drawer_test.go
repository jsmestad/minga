package ui

import (
	"bytes"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func tasksDrawerModel(t *testing.T, focused uint8) Model {
	t.Helper()
	model := New(100, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiTasksDrawer: {TasksDrawer: generated.GuiTasksDrawerFields{
			Visible: 1, Focused: focused, Name: "*minga-tasks*", Title: "Minga Tasks",
			Counts: []generated.TasksDrawerCount{{State: 2, Count: 1}, {State: 1, Count: 2}},
			Hints:  []generated.TasksDrawerHint{{Key: "j/k", Label: "move"}, {Key: "q", Label: "close"}},
			Rows: []generated.TasksDrawerRow{
				{
					ID: "t1", Flags: tasksDrawerRowFlagSelected, State: 2, Title: "Add tests for the classifier",
					Words: "Needs you · wants to change a file", Age: "2m",
					Detail:  []generated.TasksDrawerLine{{Text: "Create test/usage_limit_test.exs +86"}},
					Actions: []generated.TasksDrawerHint{{Key: "y", Label: "Approve once"}, {Key: "n", Label: "Deny"}},
				},
				{ID: "t2", State: 1, Title: "Show the plan limit", Words: "Running edit_file", Age: "4m"},
				{ID: "t2.s1", Depth: 1, Flags: tasksDrawerRowFlagLast, State: 1, Title: "Fact-check", Words: "Working", Age: "now"},
			},
		}},
	}
	model.surfacePlacements = []generated.SurfacePlacement{{
		SurfaceID: surfaceIDTasksDrawer, Rect: generated.Rect{Row: 12, Col: 0, Width: 100, Height: 9}, Z: 175, HitKind: 8,
	}}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	_ = model.View()
	return model
}

func TestTasksDrawerIsARealSplitWithItsHeaderRowsAndHints(t *testing.T) {
	model := tasksDrawerModel(t, 1)
	if model.layout.drawer.Height != 9 || model.layout.body.Y+model.layout.body.Height > model.layout.drawer.Y {
		t.Fatalf("the editor body must end above the drawer: body=%+v drawer=%+v", model.layout.body, model.layout.drawer)
	}
	lines := model.renderTasksDrawer(model.chrome[generated.OPGuiTasksDrawer].TasksDrawer, 100, 9)
	text := ansi.Strip(strings.Join(lines, "\n"))
	for _, want := range []string{"*minga-tasks*", "Minga Tasks", "◉ 1", "◐ 2", "◉", "Add tests for the classifier",
		"Needs you · wants to change a file", "Create test/usage_limit_test.exs +86", "y Approve once", "n Deny",
		"└─", "Fact-check", "j/k move", "q close", "╭", "╰"} {
		if !strings.Contains(text, want) {
			t.Fatalf("drawer is missing %q:\n%s", want, text)
		}
	}
	for _, line := range lines {
		if width := ansi.StringWidth(line); width != 100 {
			t.Fatalf("every drawer line fills the split, got width %d: %q", width, ansi.Strip(line))
		}
	}
}

func TestTasksDrawerClicksNameTheRowTheyHit(t *testing.T) {
	model := tasksDrawerModel(t, 1)
	approve := waitForZone(t, model, zoneIDTasksDrawerAction("t1", "y"))
	if packet, ok := model.semanticMousePacket(clickAt(approve)); !ok || !bytes.Equal(packet, protocol.EncodeGUITasksDrawerAction("t1", "y")) {
		t.Fatalf("an action click names its row and key, ok=%v packet=%v", ok, packet)
	}
	row := waitForZone(t, model, zoneIDTasksDrawerRow("t2.s1"))
	if packet, ok := model.semanticMousePacket(clickAt(row)); !ok || !bytes.Equal(packet, protocol.EncodeGUITasksDrawerAction("t2.s1", "select")) {
		t.Fatalf("a row click selects that row, ok=%v packet=%v", ok, packet)
	}
	closeZone := waitForZone(t, model, tasksDrawerCloseZone)
	if packet, ok := model.semanticMousePacket(clickAt(closeZone)); !ok || !bytes.Equal(packet, protocol.EncodeGUITasksDrawerAction("", "q")) {
		t.Fatalf("the close hint closes the drawer, ok=%v packet=%v", ok, packet)
	}
	drawer := model.layout.drawer
	empty := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: drawer.X + 2, Y: drawer.Y + drawer.Height - 2})
	if packet, ok := model.semanticMousePacket(empty); !ok || !bytes.Equal(packet, protocol.EncodeGUITasksDrawerAction("", "focus")) {
		t.Fatalf("a click on the drawer's empty space gives it the keyboard, ok=%v packet=%v", ok, packet)
	}
}

func TestHiddenTasksDrawerReservesNothing(t *testing.T) {
	model := New(100, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{generated.OPGuiTasksDrawer: {}}
	model.layout = model.computeLayout()
	if model.layout.drawer.Height != 0 || model.tasksDrawerLayer() != nil {
		t.Fatal("a hidden drawer takes no rows and paints nothing")
	}
}

func TestTasksDrawerShowsADiffFromItsOffsetAndAsksItsQuestion(t *testing.T) {
	model := New(100, 24, nil)
	drawer := generated.GuiTasksDrawerFields{
		Visible: 1, Focused: 1, Name: "*minga-tasks*", Title: "Minga Tasks",
		View: tasksDrawerViewDiff, ViewTitle: "Add tests · Create a_test.exs +2", ViewOffset: 1,
		ViewLines: []generated.TasksDrawerLine{{Text: "@@ -0,0 +1,2 @@"}, {Text: "+ defmodule ATest do"}, {Text: "+ end"}},
		Prompt:    "Stop “Plan limit”? y stop · n keep it running",
	}
	text := ansi.Strip(strings.Join(model.renderTasksDrawer(drawer, 100, 8), "\n"))
	for _, want := range []string{"Add tests · Create a_test.exs +2", "+ defmodule ATest do", "+ end", "Stop “Plan limit”?"} {
		if !strings.Contains(text, want) {
			t.Fatalf("diff view is missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "@@ -0,0") {
		t.Fatalf("the view starts at the BEAM's offset:\n%s", text)
	}
}

func TestTasksDrawerKeepsTheSelectedRowOnScreen(t *testing.T) {
	model := New(100, 24, nil)
	rows := []generated.TasksDrawerRow{}
	for _, title := range []string{"one", "two", "three", "four", "five", "six", "seven"} {
		rows = append(rows, generated.TasksDrawerRow{ID: title, State: 1, Title: title, Words: "Working"})
	}
	rows[6].Flags = tasksDrawerRowFlagSelected
	drawer := generated.GuiTasksDrawerFields{Visible: 1, Focused: 1, Name: "*minga-tasks*", Title: "Minga Tasks", Rows: rows}
	text := ansi.Strip(strings.Join(model.renderTasksDrawer(drawer, 100, 6), "\n"))
	if !strings.Contains(text, "seven") || strings.Contains(text, " one ") {
		t.Fatalf("the selected last row must be visible in a short drawer:\n%s", text)
	}
}

func TestTasksDrawerLongWordsNeverRunIntoTheActions(t *testing.T) {
	model := New(100, 24, nil)
	row := generated.TasksDrawerRow{
		ID: "t1", State: 5, Title: "Edit lib/another.ex: add the line at the end of the file", Age: "now",
		Words:   "Failed · did not start: no model is set up (SPC a S m picks one) and more words here",
		Actions: []generated.TasksDrawerHint{{Key: "o", Label: "Output"}},
	}
	line := ansi.Strip(model.tasksDrawerRowLines(row, 100, true)[0])
	if ansi.StringWidth(line) != 100 || !strings.Contains(line, " o Output") {
		t.Fatalf("the action keeps its gap and the row its width: %q", line)
	}
}

func TestEmptyTasksDrawerSaysWhatHappenedAndItsStepsRunTheirCommands(t *testing.T) {
	model := New(100, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiTasksDrawer: {TasksDrawer: generated.GuiTasksDrawerFields{
			Visible: 1, Focused: 1, Name: "*minga-tasks*", Title: "Minga Tasks",
			Hints:    []generated.TasksDrawerHint{{Key: "↩", Label: "run"}, {Key: "q", Label: "close"}},
			HasEmpty: 1,
			Empty: generated.EmptyList{
				Title: "No one's at the table yet.",
				Why:   "Give Minga a task. Each one gets its own conversation, review and place in the modeline.",
				Actions: []generated.EmptyListAction{
					{ID: "agent_new_task", Key: "c", Label: "New task"},
					{ID: "agent_session_history", Key: "SPC a S h", Label: "Resume an earlier session"},
				},
			},
		}},
	}
	model.surfacePlacements = []generated.SurfacePlacement{{
		SurfaceID: surfaceIDTasksDrawer, Rect: generated.Rect{Row: 12, Col: 0, Width: 100, Height: 9}, Z: 175, HitKind: 8,
	}}
	model.layout = model.computeLayout()
	_ = model.View()

	text := ansi.Strip(strings.Join(model.renderTasksDrawer(model.chrome[generated.OPGuiTasksDrawer].TasksDrawer, 100, 9), "\n"))
	for _, want := range []string{"No one's at the table yet.", "Give Minga a task.", "c", "New task", "SPC a S h", "Resume an earlier session"} {
		if !strings.Contains(text, want) {
			t.Fatalf("empty drawer is missing %q:\n%s", want, text)
		}
	}

	step := waitForZone(t, model, zoneIDTasksDrawerEmptyAction(1))
	if packet, ok := model.semanticMousePacket(clickAt(step)); !ok || !bytes.Equal(packet, protocol.EncodeGUIExecuteCommand("agent_session_history")) {
		t.Fatalf("a next step runs its command, ok=%v packet=%v", ok, packet)
	}
}

func TestNarrowTasksDrawerRowsCutWithEllipsisAndKeepTheirGaps(t *testing.T) {
	model := tasksDrawerModel(t, 1)
	row := generated.TasksDrawerRow{
		ID: "t9", State: 3, Title: "Refactor the picker sources so every source owns its own fetch",
		Words: "Waiting · rate limited, retry in 40 s", Age: "now",
		Actions: []generated.TasksDrawerHint{{Key: "r", Label: "Retry now"}},
	}
	line := ansi.Strip(model.tasksDrawerRowLines(row, 60, true)[0])
	if !strings.Contains(line, "…") {
		t.Fatalf("a cut title or state reason ends in an ellipsis: %q", line)
	}
	if strings.Contains(line, "sr Retry") || strings.Contains(line, "0r Retry") {
		t.Fatalf("the state words must not run into the action: %q", line)
	}
	if !strings.Contains(line, "  r Retry now") {
		t.Fatalf("a gap separates the state words from the action: %q", line)
	}

	asking := generated.TasksDrawerRow{
		ID: "t1", Flags: tasksDrawerRowFlagSelected, State: 2, Title: "Add tests",
		Words: "Needs you · wants to change a file", Age: "2m",
		Detail: []generated.TasksDrawerLine{{Text: "Create test/usage_limit_test.exs +86"}},
		Actions: []generated.TasksDrawerHint{
			{Key: "y", Label: "Approve once"}, {Key: "a", Label: "Always for this session"},
			{Key: "t", Label: "This turn"}, {Key: "n", Label: "Deny"}, {Key: "=", Label: "Show diff"},
		},
	}
	lines := model.tasksDrawerRowLines(asking, 50, true)
	answers := make([]string, 0, len(lines))
	for _, line := range lines[2:] {
		answers = append(answers, ansi.Strip(line))
	}
	if len(answers) < 2 {
		t.Fatalf("answers that do not fit wrap onto another line: %q", answers)
	}
	for _, line := range answers {
		if ansi.StringWidth(line) != 50 || !strings.HasSuffix(line, " ") {
			t.Fatalf("every answer line fills the row and keeps its trailing inset: %q", line)
		}
	}
	joined := strings.Join(answers, "\n")
	for _, want := range []string{"y Approve once", "a Always for this session", "t This turn", "n Deny", "= Show diff"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("every answer stays visible and whole, %q is missing: %q", want, answers)
		}
	}
}

func TestNarrowTasksDrawerViewHeadingKeepsItsTrailingInset(t *testing.T) {
	model := New(100, 24, nil)
	drawer := generated.GuiTasksDrawerFields{
		Visible: 1, Focused: 1, Name: "*minga-tasks*", Title: "Minga Tasks", View: tasksDrawerViewDiff,
		ViewTitle: "Add tests for the usage-limit classifier · Create test/minga_agent/usage_limit_test.exs +86",
		ViewLines: []generated.TasksDrawerLine{{Text: "+ defmodule ATest do"}},
	}
	heading := ansi.Strip(model.tasksDrawerViewLines(drawer, 60, 4)[0])
	if ansi.StringWidth(heading) != 60 || !strings.HasSuffix(heading, "… ") {
		t.Fatalf("a cut heading ends in an ellipsis one column before the edge: %q", heading)
	}
}
