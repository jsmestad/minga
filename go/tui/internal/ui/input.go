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
// commit_frame can resolve a keystroke-to-write sample. Paste packets carry no sequence.
func keyPacket(msg tea.KeyPressMsg, seq uint32, composer ...uint64) ([]byte, bool) {
	key := msg.Key()
	// ⌃. opens the act menu; terminals report it only with the kitty keyboard protocol.
	if key.Mod.Contains(tea.ModCtrl) && ((key.Code >= 'a' && key.Code <= 'z') || key.Code == '.') {
		return protocol.EncodeKeyPress(key.Code, keyModifiers(key), seq), true
	}

	switch key.Code {
	case tea.KeyEnter, tea.KeyKpEnter:
		if len(composer) > 0 && composer[0] != 0 {
			return protocol.EncodeComposerKeyPress(13, keyModifiers(key), seq, composer[0]), true
		}
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
	case tea.KeyHome:
		return protocol.EncodeKeyPress(homeKeyCode, keyModifiers(key), seq), true
	case tea.KeyEnd:
		return protocol.EncodeKeyPress(endKeyCode, keyModifiers(key), seq), true
	case tea.KeyPgUp:
		return protocol.EncodeKeyPress(pageUp, keyModifiers(key), seq), true
	case tea.KeyPgDown:
		return protocol.EncodeKeyPress(pageDown, keyModifiers(key), seq), true
	case tea.KeySpace:
		return protocol.EncodeKeyPress(' ', keyModifiers(key), seq), true
	}

	if key.Text != "" {
		runes := []rune(key.Text)
		if len(runes) == 1 {
			if len(composer) > 0 && composer[0] != 0 && runes[0] == 'f' {
				return protocol.EncodeComposerKeyPress(runes[0], printableTextModifiers(key), seq, composer[0]), true
			}
			return protocol.EncodeKeyPress(runes[0], printableTextModifiers(key), seq), true
		}
		return protocol.EncodePaste(key.Text), true
	}
	return nil, false
}

func pastePacket(msg tea.PasteMsg) []byte {
	return protocol.EncodePaste(msg.String())
}

// normalizeTerminalInput restores fragmented SGR reports to physical mouse events before filtering or surface dispatch.
func normalizeTerminalInput(msg tea.Msg) tea.Msg {
	key, ok := msg.(tea.KeyPressMsg)
	if !ok {
		return msg
	}
	text := key.Key().Text
	if len(text) < 5 {
		return msg
	}
	matches := sgrMouseTailPattern.FindStringSubmatch(text)
	if len(matches) != 5 {
		return msg
	}
	code, err := strconv.Atoi(matches[1])
	if err != nil {
		return msg
	}
	x, err := strconv.Atoi(matches[2])
	if err != nil {
		return msg
	}
	y, err := strconv.Atoi(matches[3])
	if err != nil {
		return msg
	}
	mouse := tea.Mouse{X: x - 1, Y: y - 1}
	if code&0x04 != 0 {
		mouse.Mod |= tea.ModShift
	}
	if code&0x08 != 0 {
		mouse.Mod |= tea.ModAlt
	}
	if code&0x10 != 0 {
		mouse.Mod |= tea.ModCtrl
	}
	if code&0x40 != 0 {
		mouse.Button = tea.MouseWheelUp + tea.MouseButton(code&0x03)
		return tea.MouseWheelMsg(mouse)
	}
	buttons := [4]tea.MouseButton{tea.MouseLeft, tea.MouseMiddle, tea.MouseRight, tea.MouseNone}
	mouse.Button = buttons[code&0x03]
	if code&0x20 != 0 {
		return tea.MouseMotionMsg(mouse)
	}
	if matches[4] == "m" {
		return tea.MouseReleaseMsg(mouse)
	}
	return tea.MouseClickMsg(mouse)
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

// mousePacket translates the physical pointer row into the primary grid shared
// with the BEAM. Locally rendered header chrome is handled before this route.
func (m Model) mousePacket(msg tea.MouseMsg) ([]byte, bool) {
	mouse := msg.Mouse()
	// Sticky hover (#2629): free pointer motion inside the hover popup's rect is
	// not forwarded, so the BEAM never sees motion over the popup and cannot
	// dismiss it. Wheel, press, and drag still forward (wheel scrolls the popup
	// content via the BEAM; a press focuses it), so only free motion is dropped.
	if _, isMotion := msg.(tea.MouseMotionMsg); isMotion && mouse.Button == tea.MouseNone &&
		m.mouseInHoverPopup(mouse.X, mouse.Y) {
		return nil, false
	}
	_, row := m.layout.grid.Translate(mouse.X, mouse.Y)
	if !isWheelButton(mouse.Button) && row < 0 {
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
	row, col := m.normalizePresentationMouse(max(row, 0), mouse.X)
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
		button = 0x40
	case tea.MouseWheelDown:
		button = 0x41
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
	leftChrome := m.layout.leftPane.Width
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
	normalizedBodyCol := clampInt(bodyCol+m.presentationColumnOffset(scroll.colOffset), placement.col, placement.col+placement.width-1)
	return normalizedRow, normalizedBodyCol + leftChrome
}

func clampInt(value int, low int, high int) int {
	if high < low {
		return low
	}
	return min(max(value, low), high)
}

// wheelScroll normalizes modified and physical wheel events to a single axis
// and signed step, before routing to a scroll target.
func wheelScroll(mouse tea.Mouse) (delta int, horizontal bool) {
	switch mouse.Button {
	case tea.MouseWheelDown:
		return 1, mouse.Mod.Contains(tea.ModShift)
	case tea.MouseWheelUp:
		return -1, mouse.Mod.Contains(tea.ModShift)
	case tea.MouseWheelRight:
		return 1, true
	case tea.MouseWheelLeft:
		return -1, true
	default:
		return 0, false
	}
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
