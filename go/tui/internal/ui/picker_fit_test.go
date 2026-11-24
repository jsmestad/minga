package ui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// fitPicker opens a focused picker with count results in a terminal of the given size.
func fitPicker(t *testing.T, width, height uint16, count int, generation uint32) (Model, chan []byte) {
	t.Helper()
	out := make(chan []byte, 16)
	model := New(width, height, out)
	payload := pickerChrome(count, 0)
	payload.Picker.Generation = generation
	payload.Picker.Title = "Find file"
	model.chrome[generated.OPGuiPicker] = payload
	model.applyMutation(focusOwnerCommand(1, 8))
	return model, out
}

// settle runs one Update that changes nothing, which is when the model reports presentation facts.
func settle(model Model) Model {
	updated, _ := model.Update(struct{}{})
	return updated.(Model)
}

// markPickerFitReported records the open picker's fit as already sent, as it is once the frame that shows a picker has been applied.
// Tests that assert the packets of one input call it so the report is not counted among them.
func markPickerFitReported(model *Model) {
	if fit, ok := model.pickerFit(); ok {
		model.lastPickerFit = fit
	}
}

func pickerFitPackets(packets [][]byte) []protocol.PickerFit {
	var fits []protocol.PickerFit
	for _, packet := range packets {
		if len(packet) == 8 && packet[0] == generated.OPGuiAction && packet[1] == generated.GUIActionPickerFit {
			fits = append(fits, protocol.PickerFit{
				Generation: uint32(packet[2])<<24 | uint32(packet[3])<<16 | uint32(packet[4])<<8 | uint32(packet[5]),
				Rows:       uint16(packet[6])<<8 | uint16(packet[7]),
			})
		}
	}
	return fits
}

// drawnPickerItems counts the result rows the composed view draws.
func drawnPickerItems(model Model) int {
	rows := 0
	for _, line := range strings.Split(ansi.Strip(model.View().Content), "\n") {
		if strings.Contains(line, "item") {
			rows++
		}
	}
	return rows
}

func TestPickerFitWire(t *testing.T) {
	want := []byte{generated.OPGuiAction, 0x70, 1, 2, 3, 4, 0, 9}
	if got := protocol.EncodeGUIPickerFit(protocol.PickerFit{Generation: 0x01020304, Rows: 9}); !bytes.Equal(got, want) {
		t.Fatalf("picker fit = %x, want %x", got, want)
	}
}

func TestPickerReportsTheResultRowsItDraws(t *testing.T) {
	for _, size := range []struct{ width, height uint16 }{{120, 40}, {80, 24}, {150, 38}, {60, 12}} {
		t.Run(fmt.Sprintf("%dx%d", size.width, size.height), func(t *testing.T) {
			model, out := fitPicker(t, size.width, size.height, 65, 7)
			model = settle(model)

			fits := pickerFitPackets(drainOutboundPackets(out))
			if len(fits) != 1 || fits[0].Generation != 7 {
				t.Fatalf("an open picker reports its fit once, got %+v", fits)
			}
			drawn := drawnPickerItems(model)
			if drawn == 0 || int(fits[0].Rows) != drawn {
				t.Fatalf("reported %d rows, the view draws %d", fits[0].Rows, drawn)
			}
		})
	}
}

func TestPickerAt120x40ShowsNineRows(t *testing.T) {
	model, out := fitPicker(t, 120, 40, 65, 7)
	settle(model)

	fits := pickerFitPackets(drainOutboundPackets(out))
	if len(fits) != 1 || fits[0].Rows != 9 {
		t.Fatalf("a 120x40 terminal shows 9 picker rows (issue #4160), got %+v", fits)
	}
}

func TestPickerReportsItsFitOnceUntilTheRowsChange(t *testing.T) {
	model, out := fitPicker(t, 120, 40, 65, 7)
	model = settle(model)
	first := pickerFitPackets(drainOutboundPackets(out))

	model = settle(model)
	if again := pickerFitPackets(drainOutboundPackets(out)); len(again) != 0 {
		t.Fatalf("an unchanged picker must not report again, got %+v", again)
	}

	updated, _ := model.Update(tea.WindowSizeMsg{Width: 80, Height: 24})
	model = updated.(Model)
	resized := pickerFitPackets(drainOutboundPackets(out))
	if len(resized) != 1 || resized[0].Rows == first[0].Rows {
		t.Fatalf("a resize that changes the rows reports the new fit, got %+v after %+v", resized, first)
	}
	if drawn := drawnPickerItems(model); int(resized[0].Rows) != drawn {
		t.Fatalf("after the resize the report says %d rows, the view draws %d", resized[0].Rows, drawn)
	}
}

func TestEachPickerReportsItsOwnFit(t *testing.T) {
	model, out := fitPicker(t, 120, 40, 65, 7)
	model = settle(model)
	first := pickerFitPackets(drainOutboundPackets(out))

	next := pickerChrome(65, 0)
	next.Picker.Generation = 8
	model.chrome[generated.OPGuiPicker] = next
	model = settle(model)

	second := pickerFitPackets(drainOutboundPackets(out))
	if len(second) != 1 || second[0].Generation != 8 || second[0].Rows != first[0].Rows {
		t.Fatalf("a new picker with the same rows still reports, got %+v after %+v", second, first)
	}
}

func TestAClosedPickerForgetsItsFit(t *testing.T) {
	model, out := fitPicker(t, 120, 40, 65, 7)
	model = settle(model)
	drainOutboundPackets(out)

	shown := model.chrome[generated.OPGuiPicker]
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Opcode: generated.OPGuiPicker}
	model = settle(model)
	if fits := pickerFitPackets(drainOutboundPackets(out)); len(fits) != 0 {
		t.Fatalf("a hidden picker reports nothing, got %+v", fits)
	}

	model.chrome[generated.OPGuiPicker] = shown
	settle(model)
	if fits := pickerFitPackets(drainOutboundPackets(out)); len(fits) != 1 {
		t.Fatalf("the same picker shown again reports its fit again, got %+v", fits)
	}
}

func TestPickerFitCountsItemsAndNotSectionHeaders(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(120, 40, out)
	groups := make([]string, 0, 30)
	for i := 0; i < 30; i++ {
		groups = append(groups, fmt.Sprintf("Group %d", i/3))
	}
	picker := protocol.Picker{Visible: true, Generation: 9, Selected: 0, SelectedID: 1, Items: groupedItems(groups...)}
	model.chrome[generated.OPGuiPicker] = protocol.ChromePayload{Opcode: generated.OPGuiPicker, Picker: picker}
	model.applyMutation(focusOwnerCommand(1, 8))
	model = settle(model)

	fits := pickerFitPackets(drainOutboundPackets(out))
	preview, _ := model.pickerPreview()
	budget := model.pickerPopupModel().pickerLayout(preview).itemRowBudget()
	start, end, headers := pickerItemWindow(picker.Items, 0, budget)
	if !headers || end-start >= budget {
		t.Fatalf("the fixture must spend rows on section headers: window [%d,%d) of budget %d", start, end, budget)
	}
	if len(fits) != 1 || int(fits[0].Rows) != end-start {
		t.Fatalf("the fit counts the %d drawn items, not the %d-row budget, got %+v", end-start, budget, fits)
	}
}

func TestPickerFitFollowsThePreviewLayout(t *testing.T) {
	previewLines := []protocol.PreviewLine{{Segments: []protocol.PreviewSegment{{Text: "preview details"}}}}
	for _, width := range []uint16{80, 140} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			model, out := fitPicker(t, width, 40, 65, 7)
			model.chrome[generated.OPGuiPickerPreview] = protocol.ChromePayload{Opcode: generated.OPGuiPickerPreview, Preview: protocol.PickerPreview{Visible: true, Lines: previewLines}}
			model = settle(model)

			fits := pickerFitPackets(drainOutboundPackets(out))
			drawn := drawnPickerItems(model)
			if len(fits) != 1 || drawn == 0 || int(fits[0].Rows) != drawn {
				t.Fatalf("with a preview the report says %+v, the view draws %d", fits, drawn)
			}
		})
	}
}

func TestPickerPlainLettersNeverMoveThePreview(t *testing.T) {
	for _, letter := range []rune{'j', 'k'} {
		model, out := fitPicker(t, 120, 40, 5, 7)
		payload := pickerChrome(5, 2)
		model.chrome[generated.OPGuiPicker] = payload

		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: letter, Text: string(letter)}))
		model = updated.(Model)

		if _, ok := model.localPresentation.identityPreview(presentationPicker); ok {
			t.Fatalf("plain %q types into the query on the BEAM and must not move the preview", letter)
		}
		if codepoint, modifiers, ok := protocol.KeyPressIdentity(firstPacket(drainOutboundPackets(out))); !ok || codepoint != uint32(letter) || modifiers != 0 {
			t.Fatalf("plain %q must still reach the BEAM as a key press", letter)
		}
	}
}

func TestPickerPreviewMovesOnlyForTheKeysTheBEAMLists(t *testing.T) {
	ctrlN := protocol.PickerMovementKey{Codepoint: 'n', Modifiers: protocol.ModCtrl, Delta: 1}
	for _, tc := range []struct {
		name  string
		keys  []protocol.PickerMovementKey
		key   tea.KeyPressMsg
		index int
	}{
		{"default ⌃J moves down", defaultPickerMovementKeys(), ctrlKey('j'), 3},
		{"default ⌃K moves up", defaultPickerMovementKeys(), ctrlKey('k'), 1},
		{"default ↓ moves down", defaultPickerMovementKeys(), tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}), 3},
		{"default ↑ moves up", defaultPickerMovementKeys(), tea.KeyPressMsg(tea.Key{Code: tea.KeyUp}), 1},
		{"a rebound ⌃N moves down", []protocol.PickerMovementKey{ctrlN}, ctrlKey('n'), 3},
		{"⌃J the user unbound stays put", []protocol.PickerMovementKey{ctrlN}, ctrlKey('j'), 2},
		{"⇧↓ is another key and stays put", defaultPickerMovementKeys(), tea.KeyPressMsg(tea.Key{Code: tea.KeyDown, Mod: tea.ModShift}), 2},
		{"⌃N the BEAM did not list stays put", defaultPickerMovementKeys(), ctrlKey('n'), 2},
		{"no listed keys previews nothing", nil, tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}), 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model, _ := fitPicker(t, 120, 40, 5, 7)
			payload := pickerChrome(5, 2)
			payload.Picker.MovementKeys = tc.keys
			model.chrome[generated.OPGuiPicker] = payload

			updated, _ := model.Update(tc.key)
			model = updated.(Model)

			if got := model.effectivePickerIndex(model.chrome[generated.OPGuiPicker].Picker); got != tc.index {
				t.Fatalf("highlighted index = %d, want %d", got, tc.index)
			}
		})
	}
}

func TestPickerDecodesTheMovementKeysSection(t *testing.T) {
	header := []byte{1, 0, 0, 0, 0, 0, 0, 0}
	keys := []byte{2, 0, 0, 0, 'j', protocol.ModCtrl, 1, 0, 0, 0xE0, 0x08, 0, 2}
	payload := []byte{generated.OPGuiPicker, 2, 0x01, 0, byte(len(header))}
	payload = append(payload, header...)
	payload = append(payload, 0x07, 0, byte(len(keys)))
	payload = append(payload, keys...)

	command, err := protocol.DecodeCommand(payload)
	if err != nil {
		t.Fatalf("decode = %v", err)
	}
	want := []protocol.PickerMovementKey{{Codepoint: 'j', Modifiers: protocol.ModCtrl, Delta: 1}, {Codepoint: 57352, Modifiers: 0, Delta: -1}}
	got := command.Chrome.Picker.MovementKeys
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("movement keys = %+v, want %+v", got, want)
	}
}
