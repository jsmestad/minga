package ui

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func keyPacket(msg tea.KeyMsg) ([]byte, bool) {
	if msg.Paste {
		return protocol.EncodePaste(string(msg.Runes)), true
	}
	if msg.Type >= tea.KeyCtrlA && msg.Type <= tea.KeyCtrlZ {
		return protocol.EncodeKeyPress(rune('a'+int(msg.Type-tea.KeyCtrlA)), keyModifiers(msg)), true
	}

	switch msg.Type {
	case tea.KeyEnter:
		return protocol.EncodeKeyPress(13, keyModifiers(msg)), true
	case tea.KeyBackspace:
		return protocol.EncodeKeyPress(127, keyModifiers(msg)), true
	case tea.KeyEsc:
		return protocol.EncodeKeyPress(27, keyModifiers(msg)), true
	case tea.KeyTab:
		return protocol.EncodeKeyPress(9, keyModifiers(msg)), true
	case tea.KeyShiftTab:
		return protocol.EncodeKeyPress(9, keyModifiers(msg)|protocol.ModShift), true
	case tea.KeyUp, tea.KeyCtrlUp, tea.KeyShiftUp, tea.KeyCtrlShiftUp:
		return protocol.EncodeKeyPress(arrowUp, keyModifiers(msg)|navigationModifiers(msg)), true
	case tea.KeyDown, tea.KeyCtrlDown, tea.KeyShiftDown, tea.KeyCtrlShiftDown:
		return protocol.EncodeKeyPress(arrowDown, keyModifiers(msg)|navigationModifiers(msg)), true
	case tea.KeyLeft, tea.KeyCtrlLeft, tea.KeyShiftLeft, tea.KeyCtrlShiftLeft:
		return protocol.EncodeKeyPress(arrowLeft, keyModifiers(msg)|navigationModifiers(msg)), true
	case tea.KeyRight, tea.KeyCtrlRight, tea.KeyShiftRight, tea.KeyCtrlShiftRight:
		return protocol.EncodeKeyPress(arrowRight, keyModifiers(msg)|navigationModifiers(msg)), true
	case tea.KeySpace:
		return protocol.EncodeKeyPress(' ', keyModifiers(msg)), true
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
	if msg.Type >= tea.KeyCtrlA && msg.Type <= tea.KeyCtrlZ {
		mods |= protocol.ModCtrl
	}
	return mods
}

func navigationModifiers(msg tea.KeyMsg) byte {
	switch msg.Type {
	case tea.KeyCtrlUp, tea.KeyCtrlDown, tea.KeyCtrlRight, tea.KeyCtrlLeft:
		return protocol.ModCtrl
	case tea.KeyShiftUp, tea.KeyShiftDown, tea.KeyShiftRight, tea.KeyShiftLeft:
		return protocol.ModShift
	case tea.KeyCtrlShiftUp, tea.KeyCtrlShiftDown, tea.KeyCtrlShiftLeft, tea.KeyCtrlShiftRight:
		return protocol.ModCtrl | protocol.ModShift
	default:
		return 0
	}
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
