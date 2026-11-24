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

// actionMenuPicker is the buffer switcher with its act menu open on the second action.
func actionMenuPicker() protocol.Picker {
	return protocol.Picker{
		Visible:    true,
		Generation: 21,
		Title:      "Switch buffer",
		Items: []protocol.PickerItem{
			{ActivationID: 1, Label: "main.go"},
			{ActivationID: 2, Label: "render_chrome.go"},
		},
		ActionVisible:       true,
		Actions:             []string{"Open", "Kill"},
		ActionActivationIDs: []uint32{41, 42},
		ActionIndex:         1,
	}
}

func actionMenuModel(out chan []byte, picker protocol.Picker) Model {
	model := New(80, 24, out)
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: picker}
	markPickerFitReported(&model)
	return model
}

func TestPickerActionMenuDrawsItsRowsAboveThePickerWithTheSelectedRowMarked(t *testing.T) {
	model := actionMenuModel(nil, actionMenuPicker())
	screen := ansi.Strip(model.View().Content)

	for _, want := range []string{"Actions", "⌃.", "Open", pickerActionMarker + gap(listRowGlyphToTitle) + "Kill"} {
		if !strings.Contains(screen, want) {
			t.Fatalf("act menu is missing %q:\n%s", want, screen)
		}
	}
	if strings.Contains(screen, pickerActionMarker+gap(listRowGlyphToTitle)+"Open") {
		t.Fatalf("only the selected action is marked:\n%s", screen)
	}
}

func TestPickerActionMenuIsAbsentWhenTheBEAMHasItClosed(t *testing.T) {
	picker := actionMenuPicker()
	picker.ActionVisible = false
	model := actionMenuModel(nil, picker)
	if model.floatingPickerActionMenuLayer() != nil {
		t.Fatal("a closed act menu must not draw")
	}
	if strings.Contains(ansi.Strip(model.View().Content), "Actions") {
		t.Fatal("a closed act menu must not draw its header")
	}
}

func TestPickerActionMenuStaysInsideTheTerminalAndThePopoverBounds(t *testing.T) {
	picker := actionMenuPicker()
	picker.Actions = []string{strings.Repeat("x", 120)}
	picker.ActionActivationIDs = []uint32{9}
	picker.ActionIndex = 0
	for _, width := range []uint16{80, 30} {
		model := New(width, 24, nil)
		model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: picker}
		menu := model.renderPickerActionMenu(picker)
		for _, row := range strings.Split(menu, "\n") {
			if got := ansi.StringWidth(row); got > min(int(width), popoverMaxCols) {
				t.Fatalf("width %d: menu row is %d columns wide: %q", width, got, ansi.Strip(row))
			}
		}
	}
}

func TestPickerActionMenuClicksRunTheirActionAndAbsorbEverythingElse(t *testing.T) {
	out := make(chan []byte, 4)
	model := actionMenuModel(out, actionMenuPicker())
	lines := strings.Split(ansi.Strip(model.View().Content), "\n")
	cell := func(label string) tea.MouseClickMsg {
		t.Helper()
		for y, line := range lines {
			if i := strings.Index(line, label); i >= 0 {
				return tea.MouseClickMsg(tea.Mouse{X: ansi.StringWidth(line[:i]), Y: y, Button: tea.MouseLeft})
			}
		}
		t.Fatalf("act menu did not draw %q", label)
		return tea.MouseClickMsg{}
	}
	click := func(msg tea.MouseClickMsg, want []byte) {
		t.Helper()
		updated, _ := model.Update(msg)
		model = updated.(Model)
		select {
		case got := <-out:
			if !bytes.Equal(got, want) {
				t.Fatalf("click (%d,%d): packet %x, want %x", msg.X, msg.Y, got, want)
			}
		default:
			if want != nil {
				t.Fatalf("click (%d,%d): no packet, want %x", msg.X, msg.Y, want)
			}
		}
	}
	click(cell("Open"), protocol.EncodeGUISemanticItemActivate(byte(presentationPicker), pickerActionIntent, 21, []byte{0, 0, 0, 41}))
	click(cell("Actions"), nil)
	click(tea.MouseClickMsg(tea.Mouse{X: 0, Y: 0, Button: tea.MouseLeft}), nil)
}

func TestPickerActionMenuOwnsTheListKeys(t *testing.T) {
	out := make(chan []byte, 8)
	model := actionMenuModel(out, actionMenuPicker())
	model.applyMutation(focusOwnerCommand(1, 8))
	model.localPresentation.setIdentityPreview(presentationPicker, 21, "1")

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}))
	model = updated.(Model)
	if got := model.effectivePickerIndex(model.chrome[generated.OPGuiPicker].Picker); got != 0 {
		t.Fatalf("↓ must not move the picker row behind an open act menu, moved to %d", got)
	}
	drainOutboundPackets(out)

	updated, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter}))
	model = updated.(Model)
	packets := drainOutboundPackets(out)
	if len(packets) != 1 || !bytes.Equal(packets[0][:5], protocol.EncodeKeyPress(13, 0, 0)[:5]) {
		t.Fatalf("↩ must reach the BEAM as a key so it runs the act menu's action, got %x", packets)
	}
}
