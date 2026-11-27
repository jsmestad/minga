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

func promptChoiceFixture(generation uint32) protocol.Minibuffer {
	return protocol.Minibuffer{
		Visible: true, Mode: 10, Generation: generation,
		Prompt: "Private input: ", Input: "••••••", CursorPos: 6,
		Items: []protocol.MinibufferCandidate{
			{ID: "Submit", Label: "Submit", Annotation: "Enter"},
			{ID: "Cancel", Label: "Cancel", Annotation: "Escape"},
		},
	}
}

func renderPromptChoiceFixture(model *Model, mini protocol.Minibuffer) string {
	model.chrome[generated.OPGuiMinibuffer] = protocol.ChromePayload{Mini: mini}
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return ansi.Strip(model.View().Content)
}

func TestPromptChoicesUseAuthoredMinibufferRowAtNarrowWidths(t *testing.T) {
	for _, width := range []int{2, 3, 8, 16, 17, 18, 24, 60, 80} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			model := New(uint16(width), 12, nil)
			mini := promptChoiceFixture(71)
			if width == 60 {
				mini.Prompt = "Rename workspace: "
				mini.Input = strings.Repeat("❤️", 20)
				mini.CursorPos = 40
			}
			rendered := renderPromptChoiceFixture(&model, mini)
			if model.layout.footer.Height != 2 {
				t.Fatal("prompt choices changed the BEAM-authored footer allocation")
			}
			if width >= 17 && (!strings.Contains(rendered, "[Submit]") || !strings.Contains(rendered, "[Cancel]")) {
				t.Fatal("prompt actions are not explicitly labeled")
			}
			if width == 80 && !strings.Contains(rendered, "••••••") {
				t.Fatal("already-masked prompt input was lost")
			}
			for _, item := range mini.Items {
				zone := waitForZone(t, model, zoneIDPromptChoice(mini.Generation, item.ID))
				if zone.StartY != model.layout.footer.Y+1 || zone.EndY != zone.StartY || zone.StartX < 0 || zone.EndX >= width || zone.EndX < zone.StartX {
					t.Fatalf("choice hit region escaped the single minibuffer row: %+v", zone)
				}
				for _, x := range []int{zone.StartX, zone.EndX} {
					click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: x, Y: zone.StartY})
					packet, ok := model.semanticMousePacket(click)
					want := protocol.EncodeGUISemanticItemActivate(4, 1, mini.Generation, []byte(item.ID))
					if !ok || !bytes.Equal(packet, want) {
						t.Fatalf("choice failed to echo its exact offered identity: %x, want %x", packet, want)
					}
				}
			}
			if packet, ok := model.promptChoiceMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: width, Y: model.layout.footer.Y + 1})); ok || packet != nil {
				t.Fatal("offscreen click activated a prompt choice")
			}
			if packet, ok := model.promptChoiceMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: 0, Y: model.layout.footer.Y})); ok || packet != nil {
				t.Fatal("status row activated a prompt choice")
			}
		})
	}
}

func TestPromptChoicesFitUnequalLabels(t *testing.T) {
	for _, width := range []int{10, 80} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			model := New(uint16(width), 12, nil)
			mini := protocol.Minibuffer{
				Visible: true, Mode: 10, Generation: 71,
				Prompt: "Reject 3 changes from task plan-limit? Your edits stay.",
				Items: []protocol.MinibufferCandidate{
					{ID: "confirm", Label: "Yes"},
					{ID: "cancel", Label: "No"},
				},
			}
			rendered := renderPromptChoiceFixture(&model, mini)
			if !strings.Contains(rendered, "[Yes] [No]") {
				t.Fatalf("confirmation hid a button label despite having room: %q", rendered)
			}
			for _, item := range mini.Items {
				zone := waitForZone(t, model, zoneIDPromptChoice(mini.Generation, item.ID))
				click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.EndX, Y: zone.StartY})
				packet, ok := model.semanticMousePacket(click)
				want := protocol.EncodeGUISemanticItemActivate(4, 1, mini.Generation, []byte(item.ID))
				if !ok || !bytes.Equal(packet, want) {
					t.Fatalf("last visible cell did not activate %q: %x", item.Label, packet)
				}
			}
		})
	}
}

func TestPromptChoiceZonesCannotRetargetIdenticalReplacementBeforeRedraw(t *testing.T) {
	model := New(80, 12, nil)
	original := promptChoiceFixture(71)
	renderPromptChoiceFixture(&model, original)
	zone := waitForZone(t, model, zoneIDPromptChoice(original.Generation, "Submit"))
	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})

	replacement := promptChoiceFixture(72)
	model.chrome[generated.OPGuiMinibuffer] = protocol.ChromePayload{Mini: replacement}
	if packet, ok := model.semanticMousePacket(click); ok || packet != nil {
		t.Fatal("retained old geometry activated an identical replacement before redraw")
	}
	renderPromptChoiceFixture(&model, replacement)
	packet, ok := model.semanticMousePacket(click)
	want := protocol.EncodeGUISemanticItemActivate(4, 1, 72, []byte("Submit"))
	if !ok || !bytes.Equal(packet, want) {
		t.Fatal("newly displayed prompt did not activate its own exact generation")
	}
}

func TestPromptChoiceRetainedZonesRejectClosedUnofferedAndNonPromptTargets(t *testing.T) {
	for _, kind := range []string{"closed", "unoffered", "command", "zero generation"} {
		t.Run(kind, func(t *testing.T) {
			model := New(80, 12, nil)
			mini := promptChoiceFixture(71)
			renderPromptChoiceFixture(&model, mini)
			zone := waitForZone(t, model, zoneIDPromptChoice(71, "Cancel"))
			click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
			switch kind {
			case "closed":
				mini.Visible = false
			case "unoffered":
				mini.Items = mini.Items[:1]
			case "command":
				mini.Mode = 0
			case "zero generation":
				mini.Generation = 0
			}
			model.chrome[generated.OPGuiMinibuffer] = protocol.ChromePayload{Mini: mini}
			if packet, ok := model.semanticMousePacket(click); ok || packet != nil {
				t.Fatalf("retained choice activated %s target", kind)
			}
		})
	}
}
