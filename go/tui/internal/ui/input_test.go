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
			packet := mousePacket(tc.msg)
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
			packet := mousePacket(tc.msg)
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
