package ui

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func keyPacket(msg tea.KeyMsg) ([]byte, bool) {
	switch msg.Type {
	case tea.KeyCtrlC:
		return protocol.EncodeKeyPress('c', protocol.ModCtrl), true
	case tea.KeyEnter:
		return protocol.EncodeKeyPress(13, 0), true
	case tea.KeyBackspace:
		return protocol.EncodeKeyPress(127, 0), true
	case tea.KeyEsc:
		return protocol.EncodeKeyPress(27, 0), true
	case tea.KeyTab:
		return protocol.EncodeKeyPress(9, 0), true
	case tea.KeyUp:
		return protocol.EncodeKeyPress(arrowUp, 0), true
	case tea.KeyDown:
		return protocol.EncodeKeyPress(arrowDown, 0), true
	case tea.KeyLeft:
		return protocol.EncodeKeyPress(arrowLeft, 0), true
	case tea.KeyRight:
		return protocol.EncodeKeyPress(arrowRight, 0), true
	case tea.KeyRunes:
		runes := msg.Runes
		if len(runes) == 1 {
			return protocol.EncodeKeyPress(runes[0], keyModifiers(msg)), true
		}
		if len(runes) > 1 {
			return protocol.EncodePaste(string(runes)), true
		}
	}
	return nil, false
}

func keyModifiers(msg tea.KeyMsg) byte {
	var mods byte
	if msg.Alt {
		mods |= protocol.ModAlt
	}
	return mods
}

func mousePacket(msg tea.MouseMsg) []byte {
	button := byte(3)
	eventType := byte(0)
	switch msg.Button {
	case tea.MouseButtonLeft:
		button = 0
	case tea.MouseButtonMiddle:
		button = 1
	case tea.MouseButtonRight:
		button = 2
	case tea.MouseButtonWheelUp:
		button = 0x40
	case tea.MouseButtonWheelDown:
		button = 0x41
	}
	if msg.Action == tea.MouseActionRelease {
		eventType = 1
	} else if msg.Action == tea.MouseActionMotion {
		eventType = 2
	}
	return protocol.EncodeMouseEvent(int16(msg.Y), int16(msg.X), button, 0, eventType, 1)
}
