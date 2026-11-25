package ui

import (
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// A key held with ⌃, ⌥ or ⌘ carries no text, so the BEAM gets its code and every modifier.
// The keys are written as the Kitty keyboard protocol reports them: the unshifted code and the modifier set.
func TestAChordReachesTheBEAMWithItsCodeAndModifiers(t *testing.T) {
	for name, tc := range map[string]struct {
		key  tea.Key
		code uint32
		mods byte
	}{
		"⌘S":         {tea.Key{Code: 's', Mod: tea.ModSuper}, 's', protocol.ModSuper},
		"⌘Z":         {tea.Key{Code: 'z', Mod: tea.ModSuper}, 'z', protocol.ModSuper},
		"⇧⌘Z":        {tea.Key{Code: 'z', Mod: tea.ModSuper | tea.ModShift}, 'z', protocol.ModSuper | protocol.ModShift},
		"⌘.":         {tea.Key{Code: '.', Mod: tea.ModSuper}, '.', protocol.ModSuper},
		"⌘1":         {tea.Key{Code: '1', Mod: tea.ModSuper}, '1', protocol.ModSuper},
		"⌘[":         {tea.Key{Code: '[', Mod: tea.ModSuper}, '[', protocol.ModSuper},
		"⌘↩":         {tea.Key{Code: tea.KeyEnter, Mod: tea.ModSuper}, 13, protocol.ModSuper},
		"⌥↩":         {tea.Key{Code: tea.KeyEnter, Mod: tea.ModAlt}, 13, protocol.ModAlt},
		"⌥F":         {tea.Key{Code: 'f', Mod: tea.ModAlt}, 'f', protocol.ModAlt},
		"⌃C":         {tea.Key{Code: 'c', Mod: tea.ModCtrl}, 'c', protocol.ModCtrl},
		"⌃.":         {tea.Key{Code: '.', Mod: tea.ModCtrl}, '.', protocol.ModCtrl},
		`⌃\`:         {tea.Key{Code: '\\', Mod: tea.ModCtrl}, '\\', protocol.ModCtrl},
		"⌃I":         {tea.Key{Code: 'i', Mod: tea.ModCtrl}, 'i', protocol.ModCtrl},
		"Tab":        {tea.Key{Code: tea.KeyTab}, 9, 0},
		"⌃M":         {tea.Key{Code: 'm', Mod: tea.ModCtrl}, 'm', protocol.ModCtrl},
		"Enter":      {tea.Key{Code: tea.KeyEnter}, 13, 0},
		"Esc":        {tea.Key{Code: tea.KeyEsc}, 27, 0},
		"⌘ and Tab":  {tea.Key{Code: tea.KeyTab, Mod: tea.ModSuper}, 9, protocol.ModSuper},
		"plain text": {tea.Key{Code: 's', Text: "s"}, 's', 0},
	} {
		t.Run(name, func(t *testing.T) {
			packet, ok := keyPacket(tea.KeyPressMsg(tc.key), 0)
			if !ok {
				t.Fatal("the key must reach the BEAM")
			}
			code, mods, ok := protocol.KeyPressIdentity(packet)
			if !ok || code != tc.code || mods != tc.mods {
				t.Fatalf("code %d (%q), modifiers %#x; want %d, %#x", code, rune(code), mods, tc.code, tc.mods)
			}
		})
	}
}

func TestAModifierPressedAloneOrAKeyWithoutACharacterSendsNothing(t *testing.T) {
	for name, key := range map[string]tea.Key{
		"⌘ alone":         {Code: tea.KeyLeftSuper, Mod: tea.ModSuper},
		"⌥ alone":         {Code: tea.KeyLeftAlt, Mod: tea.ModAlt},
		"⌃ and F5":        {Code: tea.KeyF5, Mod: tea.ModCtrl},
		"a key with none": {Code: tea.KeyF5},
	} {
		t.Run(name, func(t *testing.T) {
			if packet, ok := keyPacket(tea.KeyPressMsg(key), 0); ok {
				t.Fatalf("sent %#v", packet)
			}
		})
	}
}

// The filter is the one place every key from the terminal passes, so the mark the key input puts after a lone ESC
// never reaches the model.
func TestTheInputFilterResolvesTheKeyBoundaryMark(t *testing.T) {
	const mark rune = 0x10FFFD
	filter := NewInputFilter()
	model := New(80, 24, nil)

	// After a pending ESC the decoder reads the mark with Alt: it stands for the Esc key.
	got := filter.Filter(model, tea.KeyPressMsg(tea.Key{Code: mark, Mod: tea.ModAlt}))
	key, ok := got.(tea.KeyPressMsg)
	if !ok || key.Code != tea.KeyEsc || key.Mod != 0 || key.Text != "" {
		t.Fatalf("the mark after a pending ESC = %#v, want the Esc key", got)
	}
	if packet, ok := keyPacket(key, 0); !ok || codepoint(packet) != 27 || packet[5] != 0 {
		t.Fatalf("the Esc key packet = %#v", packet)
	}

	// When the Esc key was already delivered the mark arrives alone and is dropped.
	if got := filter.Filter(model, tea.KeyPressMsg(tea.Key{Code: mark})); got != nil {
		t.Fatalf("the mark after a delivered Esc = %#v, want nothing", got)
	}

	// Every other key passes unchanged, also Alt+Enter, which is ⌥↩.
	for _, key := range []tea.Key{{Code: tea.KeyEnter, Mod: tea.ModAlt}, {Code: tea.KeyEsc}, {Code: 'j', Text: "j"}} {
		if got := filter.Filter(model, tea.KeyPressMsg(key)); got != tea.Msg(tea.KeyPressMsg(key)) {
			t.Fatalf("%+v became %#v", key, got)
		}
	}
}
