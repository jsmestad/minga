package ui

import (
	"regexp"
	"strconv"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

var sgrMouseTailPattern = regexp.MustCompile(`^<?(\d+);(\d+);(\d+)([Mm])$`)

// keyPacket encodes a key press, stamping the latency correlation sequence
// (ticket #2215) into every actual key_press packet so the resulting frame's
// commit_frame can resolve a keystroke-to-write sample. Mouse-tail and paste
// packets use other opcodes and carry no sequence.
func keyPacket(msg tea.KeyPressMsg, seq uint32) ([]byte, bool) {
	if packet, ok := sgrMouseTailPacket(msg); ok {
		return packet, true
	}

	key := msg.Key()
	if key.Mod.Contains(tea.ModCtrl) && key.Code >= 'a' && key.Code <= 'z' {
		return protocol.EncodeKeyPress(key.Code, keyModifiers(key), seq), true
	}

	switch key.Code {
	case tea.KeyEnter, tea.KeyKpEnter:
		return protocol.EncodeKeyPress(13, keyModifiers(key), seq), true
	case tea.KeyBackspace:
		return protocol.EncodeKeyPress(127, keyModifiers(key), seq), true
	case tea.KeyEsc:
		return protocol.EncodeKeyPress(27, keyModifiers(key), seq), true
	case tea.KeyTab:
		return protocol.EncodeKeyPress(9, keyModifiers(key), seq), true
	case tea.KeyUp:
		return protocol.EncodeKeyPress(arrowUp, keyModifiers(key), seq), true
	case tea.KeyDown:
		return protocol.EncodeKeyPress(arrowDown, keyModifiers(key), seq), true
	case tea.KeyLeft:
		return protocol.EncodeKeyPress(arrowLeft, keyModifiers(key), seq), true
	case tea.KeyRight:
		return protocol.EncodeKeyPress(arrowRight, keyModifiers(key), seq), true
	case tea.KeySpace:
		return protocol.EncodeKeyPress(' ', keyModifiers(key), seq), true
	}

	if key.Text != "" {
		runes := []rune(key.Text)
		if len(runes) == 1 {
			return protocol.EncodeKeyPress(runes[0], printableTextModifiers(key), seq), true
		}
		return protocol.EncodePaste(key.Text), true
	}
	return nil, false
}

func pastePacket(msg tea.PasteMsg) []byte {
	return protocol.EncodePaste(msg.String())
}

func sgrMouseTailPacket(msg tea.KeyPressMsg) ([]byte, bool) {
	text := msg.Key().Text
	if len(text) < 5 {
		return nil, false
	}
	matches := sgrMouseTailPattern.FindStringSubmatch(text)
	if len(matches) != 5 {
		return nil, false
	}
	buttonCode, err := strconv.Atoi(matches[1])
	if err != nil {
		return nil, false
	}
	x, err := strconv.Atoi(matches[2])
	if err != nil {
		return nil, false
	}
	y, err := strconv.Atoi(matches[3])
	if err != nil {
		return nil, false
	}
	button, mods, eventType := sgrMouseParts(buttonCode, matches[4] == "m")
	return protocol.EncodeMouseEvent(int16(y-1), int16(x-1), button, mods, eventType, 1), true
}

func sgrMouseParts(code int, release bool) (byte, byte, byte) {
	const (
		shiftBit  = 0x04
		altBit    = 0x08
		ctrlBit   = 0x10
		motionBit = 0x20
		wheelBit  = 0x40
	)
	mods := byte(0)
	if code&shiftBit != 0 {
		mods |= protocol.ModShift
	}
	if code&altBit != 0 {
		mods |= protocol.ModAlt
	}
	if code&ctrlBit != 0 {
		mods |= protocol.ModCtrl
	}
	button := byte(3)
	if code&wheelBit != 0 {
		button = wheelButtonByte(code&0x03, code&shiftBit != 0)
	} else {
		button = byte(code & 0x03)
	}
	eventType := protocol.MousePress
	if release && code&wheelBit == 0 {
		eventType = protocol.MouseRelease
	} else if code&motionBit != 0 && code&wheelBit == 0 {
		// SGR motion: the low two bits carry the held button (0=left, 1=middle,
		// 2=right, 3=none). A held button means a drag; "none" means free
		// pointer motion. The BEAM only extends a selection on a drag, so keep
		// the two distinct (mirrors mousePacket and the macOS frontend).
		if code&0x03 == 0x03 {
			eventType = protocol.MouseMotion
		} else {
			eventType = protocol.MouseDrag
		}
	}
	return button, mods, eventType
}

func wheelButtonByte(bits int, shifted bool) byte {
	if shifted {
		switch bits {
		case 0:
			return 0x43
		case 1:
			return 0x42
		}
	}
	return 0x40 + byte(bits)
}

func printableTextModifiers(key tea.Key) byte {
	mods := keyModifiers(key)
	if key.Mod.Contains(tea.ModShift) && !key.Mod.Contains(tea.ModCtrl) && !key.Mod.Contains(tea.ModAlt) {
		mods &^= protocol.ModShift
	}
	return mods
}

func keyModifiers(key tea.Key) byte {
	var mods byte
	if key.Mod.Contains(tea.ModAlt) {
		mods |= protocol.ModAlt
	}
	if key.Mod.Contains(tea.ModCtrl) {
		mods |= protocol.ModCtrl
	}
	if key.Mod.Contains(tea.ModShift) {
		mods |= protocol.ModShift
	}
	return mods
}

// mousePacket encodes a raw editor-body mouse event for the BEAM, translating
// the terminal row into the editor-relative row the BEAM hit-tests.
//
// Since #2244 collapsed layout to Layout.GUI, the BEAM places the editor at row
// 0, but the Go TUI renders headerLines (tab bar, breadcrumb, ...) above the
// body. The renderer already translates inbound BEAM geometry down by the
// header height (render_content.go semanticContentOffsets); this is the
// symmetric outbound subtraction so a click on the visually-Nth buffer line
// reaches the BEAM as editor row N (ticket #2256). The macOS GUI already sends
// editor-relative coordinates because its chrome lives outside the Metal view.
//
// Header-click policy: chrome (tabs, breadcrumbs, file tree) is zone-routed
// before reaching here, so a raw event whose row lands in the header region is
// an unrouted header pixel, not a buffer click. Forwarding it would become a
// phantom click on editor row 0, so it is suppressed (ok=false). Wheel events
// are forwarded regardless of row: the BEAM treats a wheel as a viewport scroll
// (no buffer hit-test), and dropping a wheel over the header would silently
// swallow scroll input. Only carried-row buffer events (press/release/drag/
// motion) honor the suppression.
func (m Model) mousePacket(msg tea.MouseMsg) ([]byte, bool) {
	mouse := msg.Mouse()
	offset := m.layout.header.Height
	row := mouse.Y - offset
	if !isWheelButton(mouse.Button) && mouse.Y < offset {
		// Header-region policy: a PRESS on an unrouted header pixel must not
		// become a phantom row-0 buffer click, so it is suppressed. Drag,
		// motion, and release events are forwarded clamped to row 0 instead:
		// an upward drag keeps extending at the top visible line, and a
		// release over the header still terminates the BEAM's drag state
		// (suppressing it latched dragging until the next press).
		if _, isPress := msg.(tea.MouseClickMsg); isPress {
			return nil, false
		}
	}
	if row < 0 {
		row = 0
	}
	row, col := m.normalizePresentationMouse(row, mouse.X)
	button := byte(3)
	eventType := byte(0)
	switch mouse.Button {
	case tea.MouseLeft:
		button = 0
	case tea.MouseMiddle:
		button = 1
	case tea.MouseRight:
		button = 2
	case tea.MouseWheelUp:
		if mouse.Mod.Contains(tea.ModShift) {
			button = 0x43
		} else {
			button = 0x40
		}
	case tea.MouseWheelDown:
		if mouse.Mod.Contains(tea.ModShift) {
			button = 0x42
		} else {
			button = 0x41
		}
	case tea.MouseWheelRight:
		button = 0x42
	case tea.MouseWheelLeft:
		button = 0x43
	}
	switch msg.(type) {
	case tea.MouseReleaseMsg:
		eventType = protocol.MouseRelease
	case tea.MouseMotionMsg:
		// MouseModeCellMotion (DECSET 1002) delivers motion only while a button
		// is held (a drag) plus, on some terminals, free motion. Bubble Tea sets
		// Mouse.Button to the held button during a drag and MouseNone for free
		// motion. The BEAM only extends a selection on a drag (event_type
		// :drag), so report a held-button motion as MouseDrag and free motion as
		// MouseMotion, matching the macOS frontend (EditorNSView.swift:1219/1233).
		if mouse.Button == tea.MouseNone {
			eventType = protocol.MouseMotion
		} else {
			eventType = protocol.MouseDrag
		}
	}
	return protocol.EncodeMouseEvent(int16(row), int16(col), button, keyModToProtocol(mouse.Mod), eventType, 1), true
}

func (m Model) normalizePresentationMouse(row int, col int) (int, int) {
	leftChrome := m.leftChromeWidth()
	bodyCol := col - leftChrome
	windowID, ok := m.presentationScrollWindowAtBody(bodyCol, row)
	if !ok {
		return row, col
	}
	window := m.windows[windowID]
	placement, ok := m.semanticWindowPlacement(window)
	if !ok {
		return row, col
	}
	scroll, ok := m.localPresentation.scrolls[windowID]
	if !ok || !scroll.keysMatch(window.Scroll) {
		return row, col
	}
	normalizedRow := clampInt(row+scroll.rowOffset, placement.row, placement.row+placement.height-1)
	normalizedBodyCol := clampInt(bodyCol+scroll.colOffset, placement.col, placement.col+placement.width-1)
	return normalizedRow, normalizedBodyCol + leftChrome
}

func clampInt(value int, low int, high int) int {
	if high < low {
		return low
	}
	return min(max(value, low), high)
}

// isWheelButton reports whether a Bubble Tea mouse button is a scroll-wheel
// button. Wheel events are forwarded as viewport scrolls and bypass the
// header-region suppression that protects buffer hit-test rows (ticket #2256).
func isWheelButton(button tea.MouseButton) bool {
	switch button {
	case tea.MouseWheelUp, tea.MouseWheelDown, tea.MouseWheelLeft, tea.MouseWheelRight:
		return true
	default:
		return false
	}
}

func keyModToProtocol(mod tea.KeyMod) byte {
	var mods byte
	if mod.Contains(tea.ModShift) {
		mods |= protocol.ModShift
	}
	if mod.Contains(tea.ModAlt) {
		mods |= protocol.ModAlt
	}
	if mod.Contains(tea.ModCtrl) {
		mods |= protocol.ModCtrl
	}
	return mods
}
