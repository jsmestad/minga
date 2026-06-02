package ui

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestKeyPacketPreservesCtrlLetter(t *testing.T) {
	packet, ok := keyPacket(tea.KeyMsg{Type: tea.KeyCtrlC})
	if !ok {
		t.Fatal("ctrl-c should encode a key packet")
	}
	if packet[0] != generated.OPKeyPress || codepoint(packet) != 'c' || packet[5] != protocol.ModCtrl {
		t.Fatalf("ctrl-c packet = %#v", packet)
	}
}

func TestKeyPacketEncodesBracketedPasteAsPasteEvent(t *testing.T) {
	packet, ok := keyPacket(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("hello\nworld"), Paste: true})
	if !ok {
		t.Fatal("paste should encode a paste packet")
	}
	if packet[0] != generated.OPPasteEvent {
		t.Fatalf("opcode = 0x%02X, want paste", packet[0])
	}
	if string(packet[3:]) != "hello\nworld" {
		t.Fatalf("paste body = %q", string(packet[3:]))
	}
}

func TestKeyPacketPreservesNavigationModifiers(t *testing.T) {
	packet, ok := keyPacket(tea.KeyMsg{Type: tea.KeyCtrlShiftRight})
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
