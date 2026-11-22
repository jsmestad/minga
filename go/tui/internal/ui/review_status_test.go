package ui

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func reviewStatusCommand(t *testing.T, review *protocol.StatusReview) protocol.Command {
	t.Helper()
	packet := []byte{generated.OPGuiStatusBar, 0}
	if review != nil {
		section := binary.BigEndian.AppendUint16(nil, uint16(len(review.Path)))
		section = append(section, []byte(review.Path)...)
		section = append(section, byte(review.Freshness))
		section = binary.BigEndian.AppendUint32(section, review.Generation)
		section = binary.BigEndian.AppendUint16(section, uint16(len(review.ItemID)))
		section = append(section, []byte(review.ItemID)...)
		packet[1] = 1
		packet = append(packet, 0x10)
		packet = binary.BigEndian.AppendUint16(packet, uint16(len(section)))
		packet = append(packet, section...)
		if review.ConflictIndex != 0 {
			packet[1]++
			packet = binary.BigEndian.AppendUint32(append(packet, 0x11, 0, 4), review.ConflictIndex)
		}
	}
	command, err := protocol.DecodeCommand(packet)
	if err != nil {
		t.Fatal(err)
	}
	return command
}

func reviewFooterModel(t *testing.T, width uint16, freshness protocol.ReviewFreshness) (Model, protocol.StatusReview) {
	t.Helper()
	review := protocol.StatusReview{Path: "/project/optional/path/shared.ex", Freshness: freshness, Generation: 0x1234ABCD, ItemID: "opaque:é/+% item\x00"}
	model := New(width, 12, nil)
	applyProductionFrame(&model, 1, 0, 1, testThemeCommand(), reviewStatusCommand(t, &review), focusOwnerCommand(0, 0))
	model.layout = model.computeLayout()
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return model, review
}

func TestReviewFooterPrioritizesThreeBoundedControlsAndStableDisabledSlot(t *testing.T) {
	for _, width := range []uint16{16, 20, 23, 32, 40, 42, 56, 57, 80, 120} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			model, review := reviewFooterModel(t, width, protocol.ReviewCurrent)
			_ = model.View()
			positions := make([]zoneInfo, 0, 3)
			for _, id := range []string{zoneIDReviewControl(review, 1), zoneIDReviewControl(review, 2), zoneIDReviewHelp} {
				zone := waitForZone(t, model, id)
				if zone.StartX < 0 || zone.EndX >= int(width) || zone.StartY != model.layout.footer.Y || zone.EndY != zone.StartY {
					t.Fatalf("unbounded essential control at width %d: %+v", width, zone)
				}
				positions = append(positions, *zone)
			}
			for i := 1; i < len(positions); i++ {
				if positions[i-1].EndX >= positions[i].StartX {
					t.Fatalf("essential mouse controls overlap: %+v", positions)
				}
			}
			footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
			if !strings.Contains(footer, "current") || (width >= 23 && !strings.Contains(footer, "Read-only")) {
				t.Fatalf("current/read-only status lost: %q", footer)
			}
			if width <= 23 && strings.Contains(footer, "optional") {
				t.Fatalf("optional path displaced controls: %q", footer)
			}
			if width == 120 && !strings.Contains(footer, review.Path) {
				t.Fatalf("wide Review footer omitted optional path: %q", footer)
			}
			refresh := positions[1]
			click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: refresh.StartX, Y: refresh.StartY})
			if packet, handled := model.semanticMousePacket(click); !handled || packet != nil {
				t.Fatalf("current Refresh must stay disabled, packet=%x handled=%v", packet, handled)
			}
			review.Freshness = protocol.ReviewStale
			applyProductionFrame(&model, 2, 1, 1, reviewStatusCommand(t, &review))
			_ = model.View()
			for index, id := range []string{zoneIDReviewControl(review, 1), zoneIDReviewControl(review, 2), zoneIDReviewHelp} {
				zone := waitForZone(t, model, id)
				if *zone != positions[index] {
					t.Fatalf("freshness moved control %d: %+v -> %+v", index, positions[index], zone)
				}
			}
			footer = ansi.Strip(strings.Join(model.footerLines(), "\n"))
			if !strings.Contains(footer, "stale") {
				t.Fatalf("stale status is only conveyed by color: %q", footer)
			}
		})
	}
}

func TestReviewFooterClicksEchoExactCommittedOfferAndNamedHelp(t *testing.T) {
	model, review := reviewFooterModel(t, 80, protocol.ReviewStale)
	out := make(chan []byte, 32)
	model.out = out
	_ = model.View()
	for _, intent := range []byte{1, 2} {
		zone := waitForZone(t, model, zoneIDReviewControl(review, intent))
		click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
		updated, _ := model.Update(click)
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		want := protocol.EncodeGUISemanticItemActivate(6, intent, review.Generation, []byte(review.ItemID))
		if len(packets) != 1 || !bytes.Equal(packets[0], want) {
			t.Fatalf("Review intent %d retargeted opaque identity: %x, want %x", intent, packets, want)
		}
	}
	zone := waitForZone(t, model, zoneIDReviewHelp)
	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
	packet, ok := model.semanticMousePacket(click)
	if !ok || !bytes.Equal(packet, protocol.EncodeGUIExecuteCommand("agent_toggle_help")) {
		t.Fatalf("Review Help synthesized typing instead of a named command: %x", packet)
	}
	// Padding and path text do not activate any Review control.
	click.X = zone.EndX + 2
	if packet, ok := model.semanticMousePacket(click); ok {
		t.Fatalf("optional footer metadata is actionable: %x", packet)
	}
}

func TestConflictFooterKeepsBothChoicesReachableAndRejectsStaleClicks(t *testing.T) {
	for _, width := range []uint16{60, 100} {
		t.Run(fmt.Sprint(width), func(t *testing.T) {
			model, review := reviewFooterModel(t, width, protocol.ReviewCurrent)
			out := make(chan []byte, 8)
			model.out = out
			review.ConflictIndex = 1
			applyProductionFrame(&model, 2, 1, 1, reviewStatusCommand(t, &review))
			drainOutboundPackets(out) // Frame acknowledgement is not a mouse action.
			view := model.View()
			if footer := ansi.Strip(strings.Join(model.footerLines(), "\n")); !strings.Contains(footer, "Conflict 1") {
				t.Fatalf("width %d clipped the visible conflict status: %q", width, footer)
			}
			for _, intent := range [...]byte{3, 4} {
				zone := waitForZone(t, model, zoneIDReviewControl(review, intent))
				if zone.StartX < 0 || zone.EndX >= int(width) {
					t.Fatalf("conflict control clipped at width %d: %+v", width, zone)
				}
				click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
				next, _ := updateFromPublishedView(model, view, click)
				model = next.(Model)
				packets := drainOutboundPackets(out)
				want := protocol.EncodeGUISemanticItemActivate(6, intent, review.Generation, []byte(review.ItemID))
				if len(packets) != 1 || !bytes.Equal(packets[0], want) {
					t.Fatalf("visible conflict control got %x, want %x", packets, want)
				}
			}
			review.Freshness = protocol.ReviewStale
			applyProductionFrame(&model, 3, 2, 1, reviewStatusCommand(t, &review))
			drainOutboundPackets(out)
			view = model.View()
			if footer := ansi.Strip(strings.Join(model.footerLines(), "\n")); !strings.Contains(footer, "Stale #1") {
				t.Fatalf("width %d clipped the visible stale status: %q", width, footer)
			}
			for _, intent := range [...]byte{3, 4} {
				zone := waitForZone(t, model, zoneIDReviewControl(review, intent))
				click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
				next, _ := updateFromPublishedView(model, view, click)
				model = next.(Model)
				if packets := drainOutboundPackets(out); len(packets) != 0 {
					t.Fatalf("stale conflict activated a choice: %x", packets)
				}
			}
		})
	}
}

func TestConflictClickDoesNotUseAnUnflushedReplacementHunk(t *testing.T) {
	model, first := reviewFooterModel(t, 60, protocol.ReviewCurrent)
	out := make(chan []byte, 8)
	model.out = out
	first.ConflictIndex = 1
	applyProductionFrame(&model, 2, 1, 1, reviewStatusCommand(t, &first))
	displayed := model.View()
	hit := *waitForZone(t, model, zoneIDReviewControl(first, 3))

	second := first
	second.ConflictIndex = 2
	second.ItemID = "second-hunk"
	applyProductionFrame(&model, 3, 2, 1, reviewStatusCommand(t, &second))
	unflushed := model.View()
	drainOutboundPackets(out)
	if !strings.Contains(ansi.Strip(displayed.Content), "Conflict 1") ||
		!strings.Contains(ansi.Strip(unflushed.Content), "Conflict 2") {
		t.Fatal("the two frames must visibly identify their different selected conflicts")
	}

	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: hit.StartX, Y: hit.StartY})
	next, _ := updateFromPublishedView(model, displayed, click)
	packets := drainOutboundPackets(out)
	want := protocol.EncodeGUISemanticItemActivate(6, 3, first.Generation, []byte(first.ItemID))
	if len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("click on the first displayed hunk emitted %x, want %x", packets, want)
	}
	currentHit := waitForZone(t, model, zoneIDReviewControl(second, 3))
	next.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: currentHit.StartX, Y: currentHit.StartY}))
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("click without a published hit dispatched current state: %x", packets)
	}
}

func TestPickerBackdropOwnsClicksOverConflictDecisions(t *testing.T) {
	model, review := reviewFooterModel(t, 60, protocol.ReviewCurrent)
	out := make(chan []byte, 8)
	model.out = out
	review.ConflictIndex = 1
	applyProductionFrame(&model, 2, 1, 1, reviewStatusCommand(t, &review))
	picker := pickerChrome(1, 0)
	model.chrome[generated.OPGuiPicker] = picker
	view := model.View()
	if !strings.Contains(ansi.Strip(view.Content), "item0") {
		t.Fatal("expected the modal picker to be visible over Review")
	}
	drainOutboundPackets(out)

	decision := waitForZone(t, model, zoneIDReviewControl(review, 4))
	click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: decision.StartX, Y: decision.StartY})
	updateFromPublishedView(model, view, click)

	packets := drainOutboundPackets(out)
	want := protocol.EncodeGUISemanticItemActivate(byte(presentationPicker), 3, picker.Picker.Generation, nil)
	if len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("picker backdrop over Use Agent sent %x, want only dismissal %x", packets, want)
	}
}

func TestReviewFooterNeverRetargetsRetainedZonesAndAbsenceResets(t *testing.T) {
	for _, change := range []string{"generation", "identity", "reset"} {
		t.Run(change, func(t *testing.T) {
			model, review := reviewFooterModel(t, 80, protocol.ReviewStale)
			_ = model.View()
			zone := waitForZone(t, model, zoneIDReviewControl(review, 2))
			next := review
			switch change {
			case "generation":
				next.Generation++
			case "identity":
				next.ItemID = "opaque:other"
			case "reset":
				applyProductionFrame(&model, 2, 1, 1, reviewStatusCommand(t, nil))
			}
			if change != "reset" {
				applyProductionFrame(&model, 2, 1, 1, reviewStatusCommand(t, &next))
			}
			click := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY})
			if packet, ok := model.semanticMousePacket(click); ok {
				t.Fatalf("old rendered offer retargeted after %s: %x", change, packet)
			}
			if change == "reset" {
				_ = model.View()
				if status, ok := model.statusBar(); ok && status.Review != nil {
					t.Fatal("ordinary status retained its Review child")
				}
				if strings.Contains(ansi.Strip(model.View().Content), "Read-only") {
					t.Fatal("ordinary status retained Review chrome")
				}
			}
		})
	}
}

func TestReviewCurrentRefreshDoesNotEmitPointerOrTypingFallback(t *testing.T) {
	model, review := reviewFooterModel(t, 32, protocol.ReviewCurrent)
	out := make(chan []byte, 16)
	model.out = out
	_ = model.View()
	zone := waitForZone(t, model, zoneIDReviewControl(review, 2))
	_, _ = model.Update(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX, Y: zone.StartY}))
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("disabled Refresh emitted input: %x", packets)
	}
}
