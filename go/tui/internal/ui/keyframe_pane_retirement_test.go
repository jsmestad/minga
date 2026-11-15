package ui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestKeyframeRetiresOmittedPaneOnlyAfterSuccessfulValidation(t *testing.T) {
	const retiredID uint16 = 8
	window := func(id uint16, row uint16, text string) protocol.WindowContent {
		return protocol.WindowContent{
			ID: id, ContentEpoch: 1, GeometrySet: true,
			Rows: []protocol.WindowRow{{ID: uint64(id), ContentHash: 1, Text: text}},
			Geometry: protocol.PaneGeometry{
				ContentRect:  protocol.Rect{Row: row, Width: 40, Height: 1},
				TextRect:     protocol.Rect{Row: row, Width: 40, Height: 1},
				ClipRect:     protocol.Rect{Row: row, Width: 40, Height: 1},
				ViewportRows: 1, ViewportCols: 40, TotalLines: 1,
			},
		}
	}
	kept := window(1, 0, "retained_review")
	retired := window(retiredID, 4, "retired_prompt")
	presentation := func(id uint16, token uint64) protocol.Command {
		return protocol.Command{Kind: protocol.CommandTextPresentation, TextPresentation: protocol.TextPresentation{WindowID: id, PresentationID: token}}
	}
	model := applyTo(t, New(40, 12, nil, nil),
		beginFrame(1, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: kept},
		protocol.Command{Kind: protocol.CommandWindowContent, Window: retired},
		presentation(1, 101), presentation(retiredID, 102), commitFrame(1),
	)
	if !strings.Contains(ansi.Strip(model.View().Content), "retired_prompt") {
		t.Fatal("initial committed prompt is not visible")
	}
	x, y := 0, -1
	for row, line := range strings.Split(ansi.Strip(model.View().Content), "\n") {
		if col := strings.Index(line, "retired_prompt"); col >= 0 {
			x, y = col+2, row
			break
		}
	}
	updated, _ := model.Update(tea.MouseClickMsg{X: x, Y: y, Button: tea.MouseLeft})
	model = updated.(Model)
	if model.textDrag == nil || model.textDrag.windowID != retiredID {
		target, available := model.editorTextTargetAt(x, y, 0)
		t.Fatalf("visible pane press did not capture text: point=(%d,%d) target=%+v available=%v drag=%+v", x, y, target, available, model.textDrag)
	}
	model.localPresentation.scrolls[retiredID] = presentationScroll{}
	model.gutters[retiredID] = protocol.Gutter{WindowID: retiredID}
	model.indentGuides[retiredID] = protocol.IndentGuides{WindowID: retiredID}

	// Delta omission retains the complete pane and its input target.
	model = applyTo(t, model, beginFrame(2, 1),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: kept},
		presentation(1, 101), presentation(retiredID, 102), commitFrame(2),
	)
	if !strings.Contains(ansi.Strip(model.View().Content), "retired_prompt") {
		t.Fatal("ordinary delta omission retired the prompt")
	}
	if _, ok := model.editorTextTargetAt(x, y, 0); !ok {
		t.Fatal("ordinary delta omission lost the retained input target")
	}

	// A base-zero delta cannot borrow a pane from the prior committed frame.
	model = applyTo(t, model, beginFrame(3, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: kept},
		protocol.Command{Kind: protocol.CommandWindowDelta, Window: protocol.WindowContent{ID: retiredID, ContentEpoch: 1}},
		presentation(1, 101), commitFrame(3),
	)
	if model.lastCommittedSeq != 2 || !strings.Contains(ansi.Strip(model.View().Content), "retired_prompt") {
		t.Fatal("invalid keyframe changed the last-good pane set")
	}
	if model.textDrag == nil || model.textDrag.windowID != retiredID {
		t.Fatal("rejected keyframe discarded the live drag owner")
	}

	model = applyTo(t, model, beginFrame(3, 0), testThemeCommand(),
		protocol.Command{Kind: protocol.CommandWindowContent, Window: kept},
		presentation(1, 101), commitFrame(3),
	)
	if model.lastCommittedSeq != 3 || !strings.Contains(ansi.Strip(model.View().Content), "retained_review") {
		t.Fatal("valid replacement did not publish the retained review")
	}
	if strings.Contains(ansi.Strip(model.View().Content), "retired_prompt") {
		t.Fatal("retired prompt remains visible after replacement")
	}
	if _, ok := model.editorTextTargetAt(x, y, 0); ok {
		t.Fatal("retired geometry still accepts text input")
	}
	if model.textDrag != nil {
		t.Fatal("retired pane retains pointer ownership")
	}
	if _, ok := model.windows[retiredID]; ok {
		t.Fatal("retired content remains installed")
	}
	if _, ok := model.residentRows[retiredID]; ok {
		t.Fatal("retired resident rows remain installed")
	}
	if _, ok := model.gutters[retiredID]; ok {
		t.Fatal("retired gutter remains installed")
	}
	if _, ok := model.indentGuides[retiredID]; ok {
		t.Fatal("retired guides remain installed")
	}
	if _, ok := model.localPresentation.scrolls[retiredID]; ok {
		t.Fatal("retired local scroll remains installed")
	}
	if _, ok := model.textPresentations[retiredID]; ok {
		t.Fatal("retired presentation remains an input target")
	}
}
