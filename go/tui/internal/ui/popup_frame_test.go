package ui

import (
	"fmt"
	"maps"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

var allSpaceSteps = []space{spacePixel, spaceHairline, spaceXS, spaceSM, spaceMD, spaceLG, spaceXL, spaceXXL, spacePanel, spaceSection}

// TestPopupFrameBudgetFollowsEveryInsetStep raises each inset to every step of the scale and shows that rows fitted to the frame's budget never wrap, so a token change moves the padding and the budget together.
func TestPopupFrameBudgetFollowsEveryInsetStep(t *testing.T) {
	m := New(120, 40, nil)
	for _, corner := range []radius{radiusMD, radiusLG} {
		borderCells := 0
		if _, ok := corner.border(); ok {
			borderCells = 1
		}
		for _, vertical := range allSpaceSteps {
			for _, horizontal := range allSpaceSteps {
				frame := m.popupFrameFor(corner, vertical, horizontal)
				for _, outer := range []int{60, 80, 120} {
					name := fmt.Sprintf("corner %d, insets %d/%d pt, %d columns", corner, vertical, horizontal, outer)
					budget := frame.contentWidth(outer)
					if want := outer - 2*borderCells - 2*horizontal.cols(); budget != want {
						t.Errorf("%s: content width %d, want %d", name, budget, want)
					}
					if got, want := frame.contentHeight(20), 20-2*borderCells-2*vertical.rows(); got != want {
						t.Errorf("%s: content height %d, want %d", name, got, want)
					}
					rows := []string{strings.Repeat("x", budget), strings.Repeat("y", budget-1) + "z", "short"}
					rendered := strings.Split(frame.render(outer, strings.Join(rows, "\n")), "\n")
					if want := len(rows) + 2*borderCells + 2*vertical.rows(); len(rendered) != want {
						t.Errorf("%s: %d rendered rows, want %d (fitted rows wrapped)", name, len(rendered), want)
					}
					for index, line := range rendered {
						if width := lipgloss.Width(line); width != outer {
							t.Errorf("%s: row %d is %d columns, want %d", name, index, width, outer)
						}
					}
				}
			}
		}
	}
}

// TestPopoversFitTheirRowsInsideTheirFrame renders each bordered popover at common terminal widths and checks that the budget is the outer width minus the border and the inset token on each side, and that no fitted row wraps.
func TestPopoversFitTheirRowsInsideTheirFrame(t *testing.T) {
	which := whichKeyFixture()
	notes := protocol.Notifications{Visible: true, Items: []protocol.Notification{{ID: "n1", Title: "Update ready", Body: "Restart to apply", Source: "minga", Dismissable: true, Actions: []protocol.NotificationAction{{ID: "a1", Label: "Restart"}, {ID: "a2", Label: "Later"}}}}}
	picker := modelPickerFixture(0)
	picker.Query = "claude"
	for _, size := range []struct{ width, height uint16 }{{20, 24}, {24, 24}, {60, 24}, {80, 24}, {120, 40}} {
		m := New(size.width, size.height, nil)
		m.layout = m.computeLayout()

		t.Run(fmt.Sprintf("picker_%d", size.width), func(t *testing.T) {
			outer := m.floatingPickerWidth()
			budget := m.popoverFrame().contentWidth(outer)
			if want := outer - 2 - 2*popoverRowInset.cols(); budget != want {
				t.Errorf("picker budget %d, want %d", budget, want)
			}
			content := m
			content.width = budget
			checkFramedPopup(t, m.renderFloatingPicker(picker, protocol.PickerPreview{}), outer, len(content.renderPicker(picker, protocol.PickerPreview{}))+2+2*popoverVerticalPadding.rows())
		})

		t.Run(fmt.Sprintf("which_key_%d", size.width), func(t *testing.T) {
			popup := m.renderFloatingWhichKey(which)
			for _, line := range strings.Split(popup, "\n") {
				if got := lipgloss.Width(line); got != m.width {
					t.Errorf("which-key row is %d wide, want the full %d: %q", got, m.width, ansi.Strip(line))
				}
			}
			model := m
			model.chrome = maps.Clone(m.chrome)
			model.chrome[generated.OPGuiWhichKey] = protocol.ChromePayload{Opcode: generated.OPGuiWhichKey, Which: which}
			layer := model.floatingWhichKeyLayer()
			if layer == nil {
				t.Fatal("which-key layer did not render")
			}
			if right := layer.GetX() + lipgloss.Width(layer.GetContent()); layer.GetX() < 0 || right > m.width {
				t.Errorf("which-key layer spans columns %d to %d in a %d-column terminal", layer.GetX(), right, m.width)
			}
		})

		t.Run(fmt.Sprintf("notifications_%d", size.width), func(t *testing.T) {
			outer := m.width
			frame := m.popoverFrame()
			if want := outer - 2 - 2*popoverRowInset.cols(); frame.contentWidth(outer) != want {
				t.Errorf("notification budget %d, want %d", frame.contentWidth(outer), want)
			}
			// The BEAM band counts a title row, two rows per item, an actions row, and the frame's border rows.
			contentRows := min(1+2*len(notes.Items)+1, frame.contentHeight(m.maxOverlayHeight()))
			checkFramedPopup(t, strings.Join(m.renderNotifications(notes), "\n"), outer, contentRows+2+2*popoverVerticalPadding.rows())
		})
	}
}

func checkFramedPopup(t *testing.T, popup string, outer, wantRows int) {
	t.Helper()
	lines := strings.Split(popup, "\n")
	if len(lines) != wantRows {
		t.Errorf("popup is %d rows, want %d (a fitted row wrapped):\n%s", len(lines), wantRows, popup)
	}
	for index, line := range lines {
		if width := lipgloss.Width(line); width != outer {
			t.Errorf("row %d is %d columns, want %d", index, width, outer)
		}
	}
}
