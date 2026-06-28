package ui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestKeyPacketPreservesCtrlLetter(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: 'c', Mod: tea.ModCtrl}), 0)
	if !ok {
		t.Fatal("ctrl-c should encode a key packet")
	}
	if packet[0] != generated.OPKeyPress || codepoint(packet) != 'c' || packet[5] != protocol.ModCtrl {
		t.Fatalf("ctrl-c packet = %#v", packet)
	}
}

// TestKeyPacketStampsCorrelationSequence verifies the latency sequence (ticket
// #2215) is appended as a big-endian u32 after the modifiers byte.
func TestKeyPacketStampsCorrelationSequence(t *testing.T) {
	const seq = 0x01020304
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: 'a', Text: "a"}), seq)
	if !ok {
		t.Fatal("printable key should encode a key packet")
	}
	if len(packet) != 10 {
		t.Fatalf("key packet len = %d, want 10 (opcode + codepoint + mods + seq)", len(packet))
	}
	got := uint32(packet[6])<<24 | uint32(packet[7])<<16 | uint32(packet[8])<<8 | uint32(packet[9])
	if got != seq {
		t.Fatalf("stamped seq = %#x, want %#x", got, uint32(seq))
	}
}

func TestKeyPacketEncodesSpace(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeySpace, Text: " "}), 0)
	if !ok {
		t.Fatal("space should encode a key packet")
	}
	if packet[0] != generated.OPKeyPress || codepoint(packet) != ' ' || packet[5] != 0 {
		t.Fatalf("space packet = %#v", packet)
	}
}

func TestKeyPacketEncodesPrintableUppercaseWithoutShiftModifier(t *testing.T) {
	for _, key := range []tea.Key{
		{Code: 'T', Text: "T"},
		{Code: 'T', Text: "T", Mod: tea.ModShift},
	} {
		packet, ok := keyPacket(tea.KeyPressMsg(key), 0)
		if !ok {
			t.Fatal("uppercase printable should encode a key packet")
		}
		if packet[0] != generated.OPKeyPress || codepoint(packet) != 'T' || packet[5] != 0 {
			t.Fatalf("uppercase printable packet = %#v", packet)
		}
	}
}

func TestKeyPacketEncodesLoggedInsertSentence(t *testing.T) {
	for _, ch := range "This is the thing that we're doing" {
		packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: ch, Text: string(ch)}), 0)
		if !ok {
			t.Fatalf("char %q should encode a key packet", ch)
		}
		if packet[0] != generated.OPKeyPress || codepoint(packet) != ch || packet[5] != 0 {
			t.Fatalf("char %q packet = %#v", ch, packet)
		}
	}
}

func TestKeyPacketParsesFragmentedSGRMouseTail(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: "<65;57;23M"}), 0)
	if !ok {
		t.Fatal("SGR mouse tail should encode a mouse packet")
	}
	if packet[0] != generated.OPMouseEvent {
		t.Fatalf("opcode = 0x%02X, want mouse", packet[0])
	}
	if gotRow, gotCol := int16(packet[1])<<8|int16(packet[2]), int16(packet[3])<<8|int16(packet[4]); gotRow != 22 || gotCol != 56 {
		t.Fatalf("mouse coordinates = row %d col %d, want row 22 col 56", gotRow, gotCol)
	}
	if packet[5] != 0x41 || packet[7] != 0 {
		t.Fatalf("mouse button/event = button %#x event %#x, want wheel-down press", packet[5], packet[7])
	}
}

func TestMousePacketEncodesHorizontalWheel(t *testing.T) {
	for _, tc := range []struct {
		name string
		msg  tea.MouseMsg
		want byte
	}{
		{name: "wheel right", msg: tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelRight}), want: 0x42},
		{name: "wheel left", msg: tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelLeft}), want: 0x43},
		{name: "shift wheel down", msg: tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelDown, Mod: tea.ModShift}), want: 0x42},
		{name: "shift wheel up", msg: tea.MouseWheelMsg(tea.Mouse{Button: tea.MouseWheelUp, Mod: tea.ModShift}), want: 0x43},
	} {
		t.Run(tc.name, func(t *testing.T) {
			packet, ok := New(80, 24, nil, nil).mousePacket(tc.msg)
			if !ok {
				t.Fatal("wheel should encode a mouse packet")
			}
			if packet[0] != generated.OPMouseEvent || packet[5] != tc.want {
				t.Fatalf("mouse packet opcode/button = %#x/%#x, want mouse/%#x", packet[0], packet[5], tc.want)
			}
		})
	}
}

// A held-button motion is a drag (event_type 0x03) and a free-pointer motion is
// a hover (event_type 0x02). The BEAM only extends a selection on a drag, so the
// distinction is load-bearing for drag selection (ticket #2229, AC2).
func TestMousePacketDistinguishesDragFromMotion(t *testing.T) {
	for _, tc := range []struct {
		name          string
		msg           tea.MouseMsg
		wantEventType byte
		wantButton    byte
	}{
		{
			name:          "left-button held motion is a drag",
			msg:           tea.MouseMotionMsg(tea.Mouse{X: 5, Y: 3, Button: tea.MouseLeft}),
			wantEventType: protocol.MouseDrag,
			wantButton:    0,
		},
		{
			name:          "free pointer motion is a hover",
			msg:           tea.MouseMotionMsg(tea.Mouse{X: 5, Y: 3, Button: tea.MouseNone}),
			wantEventType: protocol.MouseMotion,
			wantButton:    3,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			packet, ok := New(80, 24, nil, nil).mousePacket(tc.msg)
			if !ok {
				t.Fatal("motion should encode a mouse packet")
			}
			if packet[7] != tc.wantEventType {
				t.Fatalf("event type = %#x, want %#x", packet[7], tc.wantEventType)
			}
			if packet[5] != tc.wantButton {
				t.Fatalf("button = %#x, want %#x", packet[5], tc.wantButton)
			}
		})
	}
}

// The SGR-tail decode path (used when the terminal mouse report arrives as
// fragmented key text) must make the same drag/motion distinction.
func TestSGRMouseTailDistinguishesDragFromMotion(t *testing.T) {
	for _, tc := range []struct {
		name          string
		text          string
		wantEventType byte
	}{
		// Button code 32 = left button (0) + motion bit (0x20): a left-drag.
		{name: "left drag", text: "<32;10;5M", wantEventType: protocol.MouseDrag},
		// Button code 35 = none (0x03) + motion bit (0x20): free motion.
		{name: "free motion", text: "<35;10;5M", wantEventType: protocol.MouseMotion},
	} {
		t.Run(tc.name, func(t *testing.T) {
			packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: tc.text}), 0)
			if !ok {
				t.Fatal("SGR motion tail should encode a mouse packet")
			}
			if packet[7] != tc.wantEventType {
				t.Fatalf("event type = %#x, want %#x", packet[7], tc.wantEventType)
			}
		})
	}
}

func TestKeyPacketParsesShiftWheelSGRMouseTailAsHorizontal(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: "<69;57;23M"}), 0)
	if !ok {
		t.Fatal("SGR shift wheel tail should encode a mouse packet")
	}
	if packet[5] != 0x42 {
		t.Fatalf("shift wheel-down should encode wheel-right button, got %#x", packet[5])
	}
}

func TestPastePacketEncodesBracketedPasteAsPasteEvent(t *testing.T) {
	packet := pastePacket(tea.PasteMsg{Content: "hello\nworld"})
	if packet[0] != generated.OPPasteEvent {
		t.Fatalf("opcode = 0x%02X, want paste", packet[0])
	}
	if string(packet[3:]) != "hello\nworld" {
		t.Fatalf("paste body = %q", string(packet[3:]))
	}
}

func TestKeyPacketPreservesNavigationModifiers(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyRight, Mod: tea.ModCtrl | tea.ModShift}), 0)
	if !ok {
		t.Fatal("ctrl-shift-right should encode a key packet")
	}
	if codepoint(packet) != arrowRight || packet[5] != protocol.ModCtrl|protocol.ModShift {
		t.Fatalf("ctrl-shift-right packet = %#v", packet)
	}
}

func TestFitUsesTerminalCellWidth(t *testing.T) {
	if got := fit("界a", 2); got != "界" {
		t.Fatalf("fit wide text = %q, want one wide grapheme", got)
	}
}

func codepoint(packet []byte) rune {
	return rune(uint32(packet[1])<<24 | uint32(packet[2])<<16 | uint32(packet[3])<<8 | uint32(packet[4]))
}

func mouseRow(packet []byte) int16 {
	return int16(uint16(packet[1])<<8 | uint16(packet[2]))
}

func mouseCol(packet []byte) int16 {
	return int16(uint16(packet[3])<<8 | uint16(packet[4]))
}

// tabBarModel builds a model whose header renders headerRows rows above the
// editor body and refreshes the cached offset exactly as Update does after
// applyCommands (ticket #2256). The header is always at least two rows (a tab
// bar plus its separator connector), so headerRows must be >= 2; a wide
// breadcrumb adds a third row. The chrome path is the realistic
// source-of-truth check that the cached offset matches the rendered
// headerLines.
func tabBarModel(headerRows int) Model {
	if headerRows < 1 {
		panic("tabBarModel: tab bar is always at least one row")
	}
	model := New(120, 24, nil, nil)
	chrome := map[byte]protocol.ChromePayload{
		generated.OPGuiTabBar: {
			Tabs: protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Icon: "󰈙", Label: "main.ex", Active: true}}},
		},
	}
	if headerRows >= 2 {
		chrome[generated.OPGuiBreadcrumb] = protocol.ChromePayload{
			Breadcrumb: protocol.Breadcrumb{Segments: []string{"lib", "minga", "main.ex"}},
		}
	}
	model.chrome = chrome
	model.layout = model.computeLayout()
	if model.layout.header.Height != headerRows {
		panic("tabBarModel: cached header height does not match requested rows")
	}
	return model
}

// TestMousePacketSubtractsHeaderOffset pins the outbound translation: a click on
// the visually-Nth buffer line (terminal row N+headerHeight) must reach the BEAM
// as editor row N, mirroring the inbound translation. Verified with the header
// hidden (offset 0) and visible (one and two rows) (ticket #2256).
func TestMousePacketSubtractsHeaderOffset(t *testing.T) {
	for _, tc := range []struct {
		name      string
		offset    int
		terminalY int
		wantRow   int16
	}{
		{name: "no header forwards row unchanged", offset: 0, terminalY: 5, wantRow: 5},
		{name: "one header row subtracts one", offset: 1, terminalY: 5, wantRow: 4},
		{name: "two header rows subtract two", offset: 2, terminalY: 5, wantRow: 3},
		{name: "first body row maps to editor row zero", offset: 1, terminalY: 1, wantRow: 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Pin the translation arithmetic directly against the cached offset so
			// the rule is independent of whether headerLines can ever collapse to
			// zero rows (it cannot today: there is always a title fallback).
			model := New(120, 24, nil, nil)
			model.layout.header.Height = tc.offset
			msg := tea.MouseClickMsg(tea.Mouse{X: 7, Y: tc.terminalY, Button: tea.MouseLeft})
			packet, ok := model.mousePacket(msg)
			if !ok {
				t.Fatal("body click should encode a mouse packet")
			}
			if got := mouseRow(packet); got != tc.wantRow {
				t.Fatalf("encoded row = %d, want %d", got, tc.wantRow)
			}
			if gotCol := int16(uint16(packet[3])<<8 | uint16(packet[4])); gotCol != 7 {
				t.Fatalf("encoded col = %d, want 7 (col is never offset)", gotCol)
			}
		})
	}
}

// TestMousePacketOffsetMirrorsRenderedHeader pins AC2: the offset subtracted
// from outbound rows is the same headerLines height the renderer uses for the
// frame on screen, sourced through the cache that Update refreshes after
// applyCommands. With a tab bar and a wide breadcrumb the header is two rows,
// so a click on visual line 4 (terminal row 5) reaches the BEAM as editor
// row 3 (ticket #2256).
func TestMousePacketOffsetMirrorsRenderedHeader(t *testing.T) {
	model := tabBarModel(2)
	if got, want := model.layout.header.Height, len(model.headerLines()); got != want {
		t.Fatalf("cached offset = %d, rendered header height = %d; must match", got, want)
	}
	msg := tea.MouseClickMsg(tea.Mouse{X: 0, Y: 5, Button: tea.MouseLeft})
	packet, ok := model.mousePacket(msg)
	if !ok {
		t.Fatal("body click should encode a mouse packet")
	}
	if got := mouseRow(packet); got != 3 {
		t.Fatalf("encoded row = %d, want 3 (terminal row 5 minus two header rows)", got)
	}
}

// TestMousePacketSuppressesHeaderRegionClick pins the header-click policy: a raw
// buffer event whose row lands in the header region (chrome that was not
// zone-routed) is suppressed instead of becoming a phantom editor row-0 click
// (ticket #2256).
func TestMousePacketSuppressesHeaderRegionClick(t *testing.T) {
	model := tabBarModel(2)
	for _, y := range []int{0, 1} {
		msg := tea.MouseClickMsg(tea.Mouse{X: 3, Y: y, Button: tea.MouseLeft})
		if packet, ok := model.mousePacket(msg); ok {
			t.Fatalf("click at header row %d should be suppressed, got row %d", y, mouseRow(packet))
		}
	}
}

// TestMousePacketClampsHeaderRegionDragAndRelease pins the in-flight-gesture
// half of the header policy: drag motion and release events that cross into
// the header region are forwarded clamped to row 0 (an upward drag keeps
// extending at the top visible line, and the release still terminates the
// BEAM's drag state) rather than suppressed (ticket #2256 review note).
func TestMousePacketClampsHeaderRegionDragAndRelease(t *testing.T) {
	model := tabBarModel(2)
	steps := []struct {
		msg     tea.MouseMsg
		wantRow int16
	}{
		{msg: tea.MouseClickMsg(tea.Mouse{X: 2, Y: 3, Button: tea.MouseLeft}), wantRow: 1},
		{msg: tea.MouseMotionMsg(tea.Mouse{X: 2, Y: 0, Button: tea.MouseLeft}), wantRow: 0},
		{msg: tea.MouseReleaseMsg(tea.Mouse{X: 2, Y: 0, Button: tea.MouseLeft}), wantRow: 0},
	}
	for _, step := range steps {
		packet, ok := model.mousePacket(step.msg)
		if !ok {
			t.Fatalf("gesture step should encode a packet: %#v", step.msg)
		}
		if got := mouseRow(packet); got != step.wantRow {
			t.Fatalf("expected row %d, got %d for %#v", step.wantRow, got, step.msg)
		}
	}
}

// TestMousePacketTranslatesDragSequence pins the #2229 buffer drag-selection
// path: the press anchor and each drag-motion row are translated by the same
// header offset so a selection anchored on the visually-Nth line stays aligned
// (ticket #2256).
func TestMousePacketTranslatesDragSequence(t *testing.T) {
	model := tabBarModel(2)
	steps := []struct {
		msg     tea.MouseMsg
		wantRow int16
	}{
		{msg: tea.MouseClickMsg(tea.Mouse{X: 2, Y: 4, Button: tea.MouseLeft}), wantRow: 2},
		{msg: tea.MouseMotionMsg(tea.Mouse{X: 6, Y: 7, Button: tea.MouseLeft}), wantRow: 5},
		{msg: tea.MouseReleaseMsg(tea.Mouse{X: 6, Y: 7, Button: tea.MouseLeft}), wantRow: 5},
	}
	for _, step := range steps {
		packet, ok := model.mousePacket(step.msg)
		if !ok {
			t.Fatalf("drag step should encode a packet: %#v", step.msg)
		}
		if got := mouseRow(packet); got != step.wantRow {
			t.Fatalf("drag step row = %d, want %d", got, step.wantRow)
		}
	}
}


// TestMousePacketTranslatesWheelOverBody pins wheel handling: a scroll wheel over
// the body is forwarded with its row translated by the header offset, and a
// wheel over the header is still forwarded (clamped at row 0) rather than
// suppressed, since the BEAM treats a wheel as a viewport scroll with no buffer
// hit-test (ticket #2256).
func TestMousePacketNormalizesPresentationScrollOffset(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		GeometrySet:  true,
		Geometry:     protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 3}},
		ScrollSet:    true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorLeft: 2, LayoutGeneration: 5,
		},
	})
	model.localPresentation.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 2, contentEpoch: 9, layoutGeneration: 5, rowOffset: 1, colOffset: 2}

	packet, ok := model.mousePacket(tea.MouseClickMsg(tea.Mouse{X: 3, Y: model.layout.header.Height, Button: tea.MouseLeft}))
	if !ok {
		t.Fatal("click should encode a mouse packet")
	}
	if got := mouseRow(packet); got != 1 {
		t.Fatalf("presentation-normalized row = %d, want 1", got)
	}
	if got := mouseCol(packet); got != 5 {
		t.Fatalf("presentation-normalized col = %d, want 5", got)
	}
}

func TestMousePacketClampsPresentationScrollOffsetInsideWindow(t *testing.T) {
	model := New(20, 6, nil, nil)
	model.putWindow(protocol.WindowContent{
		ID:           7,
		ContentEpoch: 9,
		GeometrySet:  true,
		Geometry:     protocol.PaneGeometry{ContentRect: protocol.Rect{Row: 0, Col: 0, Width: 10, Height: 3}},
		ScrollSet:    true,
		Scroll: protocol.ScrollPresentation{
			WindowID: 7, ContentEpoch: 9, AnchorTop: 10, AnchorLeft: 2, LayoutGeneration: 5,
		},
	})
	model.localPresentation.scrolls[7] = presentationScroll{anchorTop: 10, anchorLeft: 2, contentEpoch: 9, layoutGeneration: 5, rowOffset: 1, colOffset: 2}

	packet, ok := model.mousePacket(tea.MouseClickMsg(tea.Mouse{X: 9, Y: model.layout.header.Height + 2, Button: tea.MouseLeft}))
	if !ok {
		t.Fatal("click should encode a mouse packet")
	}
	if got := mouseRow(packet); got != 2 {
		t.Fatalf("presentation-normalized row should stay inside window, got %d", got)
	}
	if got := mouseCol(packet); got != 9 {
		t.Fatalf("presentation-normalized col should stay inside window, got %d", got)
	}
}

func TestMousePacketTranslatesWheelOverBody(t *testing.T) {
	model := tabBarModel(2)

	bodyWheel := tea.MouseWheelMsg(tea.Mouse{X: 4, Y: 5, Button: tea.MouseWheelDown})
	packet, ok := model.mousePacket(bodyWheel)
	if !ok {
		t.Fatal("body wheel should encode a packet")
	}
	if got := mouseRow(packet); got != 3 {
		t.Fatalf("body wheel row = %d, want 3 (5 - two header rows)", got)
	}
	if packet[5] != 0x41 {
		t.Fatalf("wheel button = %#x, want wheel-down 0x41", packet[5])
	}

	headerWheel := tea.MouseWheelMsg(tea.Mouse{X: 4, Y: 0, Button: tea.MouseWheelUp})
	packet, ok = model.mousePacket(headerWheel)
	if !ok {
		t.Fatal("header wheel should still be forwarded, not suppressed")
	}
	if got := mouseRow(packet); got != 0 {
		t.Fatalf("header wheel row = %d, want 0 (clamped)", got)
	}
}
