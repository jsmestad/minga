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

func noticeModel(width uint16) Model {
	model := New(width, 12, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {Status: protocol.StatusBar{
			Left:    []protocol.StatusSegment{{Name: "mode", Text: " NORMAL ", Attrs: 0x01}, {Name: "filename", Text: " main.ex "}},
			Right:   []protocol.StatusSegment{{Name: "position", Text: " 1:1 "}},
			Message: "No code actions at 3:7",
			MessageActions: []generated.EmptyListAction{
				{ID: "inline_ask", Key: "SPC a ?", Label: "ask Minga"},
			},
		}},
	}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return model
}

func TestNoticeNamesItsNextStepAfterTheMessage(t *testing.T) {
	model := noticeModel(120)
	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "No code actions at 3:7 · SPC a ? ask Minga") {
		t.Fatalf("the echo line should name the next step after the message:\n%s", view)
	}
}

func TestANarrowEchoLineKeepsTheMessageWholeAndTheNextStepsKey(t *testing.T) {
	// At 70 columns the step's word gives way; the message and the key stay.
	view := ansi.Strip(noticeModel(70).View().Content)
	if !strings.Contains(view, "No code actions at 3:7 · SPC a ?") || strings.Contains(view, "ask Minga") {
		t.Fatalf("a narrow echo line keeps the message whole and the step's key:\n%s", view)
	}
	// Wide enough, the step keeps its word too.
	if view := ansi.Strip(noticeModel(120).View().Content); !strings.Contains(view, "No code actions at 3:7 · SPC a ? ask Minga") {
		t.Fatalf("a wide echo line shows the whole step:\n%s", view)
	}
}

func TestClickingANoticeNextStepRunsItsCommand(t *testing.T) {
	model := noticeModel(120)
	model.View()
	zone := waitForZone(t, model, zoneIDNoticeAction(0))
	packet, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
	if !ok || !bytes.Equal(packet, protocol.EncodeGUIExecuteCommand("inline_ask")) {
		t.Fatalf("clicking the next step should run inline_ask, ok=%v packet=%v", ok, packet)
	}
}

// At 80 columns, beside the mode and file name, the buffer-search answer keeps its whole message and its step's key; the droppable segments give way first.
func TestAnEightyColumnEchoLineKeepsTheWholeAnswerAndItsKey(t *testing.T) {
	model := New(80, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {Status: protocol.StatusBar{
			Left:    []protocol.StatusSegment{{Name: "mode", Text: "NORMAL", Attrs: 0x01}, {Name: "filename", Text: "storyboard.ex"}},
			Right:   []protocol.StatusSegment{{Name: "filetype", Text: "Elixir", Drop: 2}, {Name: "position", Text: "1:8", Drop: 1}},
			Message: "No matches for “limit_lable” in this buffer",
			MessageActions: []generated.EmptyListAction{
				{ID: "search_project", Key: "SPC s p", Label: "search the project"},
			},
		}},
	}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())

	view := ansi.Strip(model.View().Content)
	if !strings.Contains(view, "No matches for “limit_lable” in this buffer · SPC s p") {
		t.Fatalf("the answer must stay whole with its step's key at 80 columns:\n%s", view)
	}
}

// The longest of the three answers, references without a language server, also keeps its key at 80 columns.
func TestAnEightyColumnEchoLineKeepsTheReferencesAnswerAndItsKey(t *testing.T) {
	model := New(80, 24, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiStatusBar: {Status: protocol.StatusBar{
			Left:    []protocol.StatusSegment{{Name: "mode", Text: "NORMAL", Attrs: 0x01}, {Name: "filename", Text: "storyboard.ex"}},
			Right:   []protocol.StatusSegment{{Name: "filetype", Text: "Elixir", Drop: 2}, {Name: "position", Text: "1:1", Drop: 1}},
			Message: "No references to defmodule (no server)",
			MessageActions: []generated.EmptyListAction{
				{ID: "search_project", Key: "SPC s p", Label: "search the project"},
			},
		}},
	}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())

	if view := ansi.Strip(model.View().Content); !strings.Contains(view, "No references to defmodule (no server) · SPC s p") {
		t.Fatalf("the references answer must stay whole with its step's key at 80 columns:\n%s", view)
	}
}
