package ui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestKeyPacketPreservesCtrlLetter(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: 'c', Mod: tea.ModCtrl}))
	if !ok {
		t.Fatal("ctrl-c should encode a key packet")
	}
	if packet[0] != generated.OPKeyPress || codepoint(packet) != 'c' || packet[5] != protocol.ModCtrl {
		t.Fatalf("ctrl-c packet = %#v", packet)
	}
}

func TestKeyPacketEncodesSpace(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeySpace, Text: " "}))
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
		packet, ok := keyPacket(tea.KeyPressMsg(key))
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
		packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: ch, Text: string(ch)}))
		if !ok {
			t.Fatalf("char %q should encode a key packet", ch)
		}
		if packet[0] != generated.OPKeyPress || codepoint(packet) != ch || packet[5] != 0 {
			t.Fatalf("char %q packet = %#v", ch, packet)
		}
	}
}

func TestKeyPacketParsesFragmentedSGRMouseTail(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: "<65;57;23M"}))
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

func TestKeyPacketParsesShiftWheelSGRMouseTailAsHorizontal(t *testing.T) {
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyExtended, Text: "<69;57;23M"}))
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
	packet, ok := keyPacket(tea.KeyPressMsg(tea.Key{Code: tea.KeyRight, Mod: tea.ModCtrl | tea.ModShift}))
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
