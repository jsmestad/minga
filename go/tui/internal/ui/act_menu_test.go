package ui

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/term"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func reviewActMenuFixture() generated.GuiActMenuFields {
	return generated.GuiActMenuFields{
		Visible: 1, OfferID: 0x0102030405060708, Role: 1, Selected: 10,
		AnchorRow: 2, AnchorColumn: 5, Title: "○ Minga's change 1 of 2",
		Lead: []generated.ActMenuRow{
			{ID: 10, Key: "y", Label: "Keep", Detail: "accept 4 lines"},
			{ID: 11, Key: "n", Label: "Reject", Detail: "removes 4, restores 1", Destructive: 1},
		},
		Rows: []generated.ActMenuRow{
			{ID: 12, Key: "=", Label: "Show diff", Hint: "SPC m d", Section: "This change"},
			{ID: 13, Key: "o", Label: "Origin", Section: "This change"},
			{ID: 14, Key: "l", Label: "Copy link", Section: "This file"},
		},
	}
}

func actMenuCommand(menu generated.GuiActMenuFields) protocol.Command {
	return protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiActMenu, ActMenu: menu}}
}

func TestActMenuDecisionAndBackdropUseCommittedTheme(t *testing.T) {
	window := protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
		ID: 7, Rows: []protocol.WindowRow{{Text: "editor stays visible"}},
	}}
	model := applyTo(t, New(80, 24, nil), frame(window)...)
	before := model.View()
	model = applyTo(t, model, beginFrame(2, 1), actMenuCommand(reviewActMenuFixture()), commitFrame(2))
	after := model.View()
	plain := ansi.Strip(after.Content)
	for _, text := range []string{"editor stays visible", "Minga's change 1 of 2", "› filter", "y Keep", "n Reject", "accept 4 lines", "removes 4, restores 1", "This change", "This file", "SPC m d"} {
		if strings.Count(plain, text) != 1 {
			t.Fatalf("want %q exactly once in painted view:\n%s", text, plain)
		}
	}
	canvas := lipgloss.NewCanvas(80, 24).Compose(lipgloss.NewLayer(after.Content))
	old := lipgloss.NewCanvas(80, 24).Compose(lipgloss.NewLayer(before.Content))
	row := model.layout.body.Y
	if previous, dimmed := old.CellAt(0, row), canvas.CellAt(0, row); previous.Content != "e" || dimmed.Content != previous.Content || dimmed.Style.Equal(&previous.Style) {
		t.Fatalf("backdrop lost its editor glyph or did not dim it: before=%+v after=%+v", previous, dimmed)
	}
	x, y := actMenuCell(t, after, "y Keep")
	rejectX, rejectY := actMenuCell(t, after, "n Reject")
	label := canvas.CellAt(x, y)
	reject := canvas.CellAt(rejectX, rejectY)
	if y != rejectY || label.Style.Attrs&uv.AttrReverse == 0 || reject.Style.Attrs&uv.AttrReverse != 0 {
		t.Fatalf("decision bar is not split with only Keep reversed: %+v / %+v", label, reject)
	}
}

func TestActMenuFitsShortTerminalAndRevealsSelectedRow(t *testing.T) {
	model := New(24, 6, nil)
	menu := reviewActMenuFixture()
	menu.Title = strings.Repeat("wide界", 40)
	menu.Query = "re"
	menu.Selected = 14
	model = applyTo(t, model, frame(actMenuCommand(menu))...)
	layer, shown := model.floatingActMenu()
	if layer == nil {
		t.Fatal("short terminal did not render the menu")
	}
	for _, line := range strings.Split(layer.GetContent(), "\n") {
		if width := ansi.StringWidth(line); width != shown.box.Width || width > 24 {
			t.Fatalf("menu row width=%d, popup width=%d: %q", width, shown.box.Width, ansi.Strip(line))
		}
	}
	if shown.box.Y+shown.box.Height > model.height || len(shown.rows) != 3 || shown.rows[0].box.Width != shown.rows[1].box.Width || shown.rows[2].id != 14 {
		t.Fatalf("the short view did not keep equal decisions and reveal the selected action: %+v", shown)
	}
	if screen := ansi.Strip(model.View().Content); !strings.Contains(screen, "› re") || !strings.Contains(screen, "Copy link") {
		t.Fatalf("missing filter text or selected action in short view:\n%s", screen)
	}
}

func TestActMenuKeepsBothConsequencesInsideTheWideTerminalWidthCap(t *testing.T) {
	menu := reviewActMenuFixture()
	menu.Title = "Minga’s change · 48 lines · unreviewed"
	menu.Lead[0].Label = "Keep change"
	menu.Lead[0].Detail = "Leaves Minga’s edits in place"
	menu.Lead[1].Label = "Reject change"
	menu.Lead[1].Detail = "Undoes only Minga’s edits"
	menu.Rows[0].Label = strings.Repeat("long action ", 8)
	model := applyTo(t, New(120, 40, nil), frame(actMenuCommand(menu))...)
	layer, shown := model.floatingActMenu()
	if layer == nil || shown.box.Width > 64 {
		t.Fatalf("want a menu no wider than 64 columns, got %+v", shown.box)
	}
	plain := ansi.Strip(layer.GetContent())
	if !strings.Contains(plain, menu.Lead[0].Detail) || !strings.Contains(plain, menu.Lead[1].Detail) {
		t.Fatalf("both decision consequences should fit:\n%s", plain)
	}
}

func TestActMenuClickUsesPublishedOfferUntilAnotherViewIsPainted(t *testing.T) {
	out := make(chan []byte, 64)
	model := New(80, 24, out)
	menu := reviewActMenuFixture()
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), actMenuCommand(menu))
	if view := model.View(); strings.Contains(ansi.Strip(view.Content), "y Keep") {
		t.Fatal("uncommitted menu drew in the terminal")
	}
	model = applyTo(t, model, commitFrame(1))
	view := model.View()
	x, y := actMenuCell(t, view, "removes 4, restores 1")
	clickReject := tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft})
	menu.OfferID++
	model = applyTo(t, model, beginFrame(2, 1), actMenuCommand(menu), commitFrame(2))
	if next := model.View(); view.Content == next.Content {
		t.Fatal("an identity-only change must publish a fresh Bubble Tea view")
	}
	drainOutboundPackets(out)
	updated, _ := updateFromPublishedView(model, view, clickReject)
	model = updated.(Model)
	want := []byte{0x07, 0x78, 1, 2, 3, 4, 5, 6, 7, 8, 0, 11}
	if packets := drainOutboundPackets(out); len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("visible Reject sent %x; want last painted offer/action %x", packets, want)
	}

	x, y = actMenuCell(t, view, "› filter")
	_, _ = updateFromPublishedView(model, view, tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft}))
	wantFilter := []byte{0x07, 0x78, 1, 2, 3, 4, 5, 6, 7, 8, 0xff, 0xff}
	if packets := drainOutboundPackets(out); len(packets) != 1 || !bytes.Equal(packets[0], wantFilter) {
		t.Fatalf("visible filter sent %x; want filter request for last painted offer %x", packets, wantFilter)
	}

	outside := tea.MouseClickMsg(tea.Mouse{Button: tea.MouseRight})
	updated, _ = updateFromPublishedView(model, view, outside)
	model = updated.(Model)
	want[11] = 0
	if packets := drainOutboundPackets(out); len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("outside press sent %x; want dismissal of the last painted offer %x", packets, want)
	}
	model = applyTo(t, model, beginFrame(3, 2), actMenuCommand(generated.GuiActMenuFields{}), commitFrame(3))
	if strings.Contains(ansi.Strip(model.View().Content), "y Keep") {
		t.Fatal("visible=0 did not clear the menu")
	}
}

type actMenuOutputBoundary struct {
	term.File
	onWrite func()
}

func (w actMenuOutputBoundary) Write(p []byte) (int, error) {
	w.onWrite()
	return len(p), nil
}

func TestActMenuClosingWriteCannotRetargetRightPress(t *testing.T) {
	out := make(chan []byte, 64)
	window := protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
		ID: 7, Rows: []protocol.WindowRow{{Text: "editor target behind menu"}},
	}}
	model := applyTo(t, New(80, 24, out), frame(window, actMenuCommand(reviewActMenuFixture()))...)
	shown := model.View()
	x, y := actMenuCell(t, shown, "n Reject")
	press := tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseRight})
	filter := NewInputFilter()
	admitted := filter.Filter(model, press)
	if admitted == nil {
		t.Fatal("a press on a fully published menu must be admitted")
	}
	model = applyTo(t, model, beginFrame(2, 1), actMenuCommand(generated.GuiActMenuFields{}), commitFrame(2))
	writer := filter.TrackOutput(actMenuOutputBoundary{onWrite: func() {
		if filter.Filter(model, press) != nil {
			t.Fatal("a press during the closing write must not target the editor")
		}
	}})
	if _, err := writer.Write([]byte(model.View().Content)); err != nil {
		t.Fatal(err)
	}
	drainOutboundPackets(out)
	_, _ = updateFromPublishedView(model, model.View(), admitted)
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("an admitted press crossing a closing write was retargeted: %x", packets)
	}
}

func TestActMenuFocusForwardsPickerMovementAndEnterWithoutPreviewing(t *testing.T) {
	model, out := fitPicker(t, 80, 24, 5, 7)
	model = applyTo(t, model, frame(actMenuCommand(reviewActMenuFixture()), focusOwnerCommand(0, 16))...)
	drainOutboundPackets(out)
	updated, _ := model.Update(ctrlKey('j'))
	model = updated.(Model)
	if got := model.effectivePickerIndex(model.chrome[generated.OPGuiPicker].Picker); got != 0 {
		t.Fatalf("menu movement moved the picker highlight to %d", got)
	}
	_, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter}))
	packets := drainOutboundPackets(out)
	if len(packets) != 2 || len(packets[0]) < 6 || len(packets[1]) < 6 ||
		!bytes.Equal(packets[0][:6], protocol.EncodeKeyPress('j', protocol.ModCtrl, 0)[:6]) ||
		!bytes.Equal(packets[1][:6], protocol.EncodeKeyPress(13, 0, 0)[:6]) {
		t.Fatalf("the menu must forward both keys without activation or local movement, got %x", packets)
	}
}

func TestReviewRibbonActUsesPaintedStickyHeadNotItsBody(t *testing.T) {
	const windowID, epoch = 7, 10
	out := make(chan []byte, 64)
	window := residentWindowCommand(windowID, epoch, 6, protocol.CommandWindowContent)
	window.Window.Geometry.ContentRect = protocol.Rect{Row: 1, Col: 5, Width: 22, Height: 3}
	window.Window.AccessibilityGeneration = 9
	window.Window.AccessibilitySet = true
	window.Window.Geometry.ViewportRows = 3
	window.Window.ScrollSet = true
	window.Window.Scroll = protocol.ScrollPresentation{WindowID: windowID, ContentEpoch: epoch, VisibleEndLine: 3, OverscanEndLine: 6, LayoutGeneration: 1}
	gutter := residentGutterCommand(windowID, epoch, 6, false, map[uint32]protocol.GutterEntry{
		1: {BufferLine: 1, DisplayType: 1},
	})
	gutter.Chrome.WindowGutter.ContentHeight = 3
	gutter.Chrome.WindowGutter.AuthorshipUpdate = &protocol.GutterAuthorshipUpdate{
		Kind: protocol.GutterAuthorshipSnapshot, Revision: 0x11223344, Added: []protocol.AuthoredGutterRegion{
			{Role: protocol.AuthoredGutterPending, Unit: 0x1234, FirstLine: 0, FirstColumn: 3, LastLine: 3},
			{Role: protocol.AuthoredGutterDeletion, Unit: 0x5678, FirstLine: 3, FirstColumn: 5, LastLine: 3},
			{Role: protocol.AuthoredGutterKept, FirstLine: 4, LastLine: 4},
			{Role: protocol.AuthoredGutterYou, FirstLine: 5, LastLine: 5},
		},
	}
	model := applyTo(t, New(32, 12, out), beginFrame(1, 0), testThemeCommand(), window, gutter, commitFrame(1))
	model.previewVerticalScroll(model.windows[windowID], 1)
	model = settle(model)
	view := model.View()
	markX := int(window.Window.Geometry.ContentRect.Col) + gutterRenderWidth(gutter.Chrome.WindowGutter) - 1
	topY := model.layout.grid.Y + 1
	canvas := lipgloss.NewCanvas(32, 12).Compose(lipgloss.NewLayer(view.Content))
	for i, glyph := range []string{"▚", "▐", "▚"} {
		if cell := canvas.CellAt(markX, topY+i); cell == nil || cell.Content != glyph {
			t.Fatalf("physical ribbon cell %d,%d = %+v; want %q", markX, topY+i, cell, glyph)
		}
	}

	for _, tc := range []struct {
		row                  int
		button               tea.MouseButton
		kind                 byte
		unit                 uint64
		firstLine, firstByte uint32
	}{
		{0, tea.MouseLeft, 0, 0x1234, 0, 3},
		{0, tea.MouseRight, 0, 0x1234, 0, 3},
		{1, tea.MouseLeft, 0, 0, 0, 0},
		{1, tea.MouseRight, 0, 0, 0, 0},
		{2, tea.MouseRight, 1, 0x5678, 3, 5},
	} {
		drainOutboundPackets(out)
		click := tea.MouseClickMsg(tea.Mouse{X: markX, Y: topY + tc.row, Button: tc.button})
		updated, _ := updateFromPublishedView(model, view, click)
		model = updated.(Model)
		var ribbon []byte
		packets := drainOutboundPackets(out)
		for _, packet := range packets {
			if len(packet) >= 2 && packet[0] == 0x07 && packet[1] == 0x79 {
				if ribbon != nil {
					t.Fatalf("one physical click emitted multiple ribbon targets")
				}
				ribbon = packet
			}
		}
		if tc.unit == 0 {
			if ribbon != nil {
				t.Fatalf("body press button=%v emitted a twist-head target: %x", tc.button, ribbon)
			}
			if tc.button == tea.MouseRight && len(packets) != 0 {
				t.Fatalf("right-click on a split ribbon body reached another input route: %x", packets)
			}
			continue
		}
		want := []byte{0x07, 0x79, 0, windowID, 0, 0, 0, 0, 0x11, 0x22, 0x33, 0x44, tc.kind}
		want = binary.BigEndian.AppendUint64(want, tc.unit)
		want = binary.BigEndian.AppendUint32(want, tc.firstLine)
		want = binary.BigEndian.AppendUint32(want, tc.firstByte)
		want = binary.BigEndian.AppendUint16(want, uint16(1+tc.row))
		want = binary.BigEndian.AppendUint16(want, uint16(markX))
		if !bytes.Equal(ribbon, want) {
			t.Fatalf("physical press at row %d button=%v = %x, want %x", tc.row, tc.button, ribbon, want)
		}
	}
	click := tea.MouseClickMsg(tea.Mouse{X: 5, Y: topY, Button: tea.MouseRight})
	assertActMenuOpeningPacket(t, model, view, out, click, []byte{0x07, 0x7a, 1, 0, windowID, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 1})
}

func TestActMenuRightClickUsesDisplayedPickerFileTreeAndApprovalTargets(t *testing.T) {
	t.Run("picker", func(t *testing.T) {
		model, out := fitPicker(t, 80, 24, 5, 21)
		markPickerFitReported(&model)
		view := model.View()
		zone := model.zones.Get(pickerPointerZone(0))
		picker := model.chrome[generated.OPGuiPicker].Picker
		want := binary.BigEndian.AppendUint32([]byte{0x07, 0x7a, 0, 0, 0, 0, 21}, picker.Items[0].ActivationID)
		assertActMenuOpeningPacket(t, model, view, out, actMenuRightClickAt(t, zone), want)
	})

	t.Run("file tree", func(t *testing.T) {
		out := make(chan []byte, 64)
		tree := protocol.FileTree{Visible: true, Generation: 22, Width: 20, Rows: []protocol.FileTreeRow{{ID: "opaque-row", Name: "main.go"}}}
		command := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiFileTree, Tree: tree}}
		model := applyTo(t, New(80, 24, out), frame(command)...)
		view := model.View()
		zone := model.zones.Get(zoneIDFileTreeRow(0))
		want := append([]byte{0x07, 0x7a, 2, 0, 0, 0, 0, 0, 0, 0, 22, 0, 10}, "opaque-row"...)
		assertActMenuOpeningPacket(t, model, view, out, actMenuRightClickAt(t, zone), want)
	})

	t.Run("agent approval", func(t *testing.T) {
		model, out := newAgentControlModel(t, true)
		view := model.View()
		x, y := actMenuCell(t, view, "[a] Approve session")
		click := tea.MouseClickMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseRight})
		target := approvalControlTarget("A")
		want := []byte{0x07, 0x7a, 3}
		for _, field := range []string{target.SessionID, target.RequestID, target.ToolCallID} {
			want = binary.BigEndian.AppendUint16(want, uint16(len(field)))
			want = append(want, field...)
		}
		assertActMenuOpeningPacket(t, model, view, out, click, want)
	})

	t.Run("Tasks approval", func(t *testing.T) {
		out := make(chan []byte, 64)
		model := tasksDrawerModel(t, 1)
		model.out = out
		view := model.View()
		zone := model.zones.Get(zoneIDTasksDrawerAction("t1", "n"))
		assertActMenuOpeningPacket(t, model, view, out, actMenuRightClickAt(t, zone), []byte{0x07, 0x7a, 4, 0, 2, 't', '1'})
	})
}

func actMenuRightClickAt(t *testing.T, zone *zoneInfo) tea.MouseClickMsg {
	t.Helper()
	if zone == nil {
		t.Fatal("context target did not render")
	}
	return tea.MouseClickMsg(tea.Mouse{X: zone.StartX, Y: zone.StartY, Button: tea.MouseRight})
}

func assertActMenuOpeningPacket(t *testing.T, model Model, view tea.View, out chan []byte, press tea.MouseClickMsg, want []byte) {
	t.Helper()
	drainOutboundPackets(out)
	updateFromPublishedView(model, view, press)
	if packets := drainOutboundPackets(out); len(packets) != 1 || !bytes.Equal(packets[0], want) {
		t.Fatalf("physical click (%d,%d) sent %x; want only %x", press.X, press.Y, packets, want)
	}
}

func actMenuCell(t *testing.T, view tea.View, text string) (int, int) {
	t.Helper()
	for y, line := range strings.Split(ansi.Strip(view.Content), "\n") {
		if index := strings.Index(line, text); index >= 0 {
			return ansi.StringWidth(line[:index]), y
		}
	}
	t.Fatalf("text %q is not on the published terminal grid", text)
	return 0, 0
}
