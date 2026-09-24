package ui

import (
	"unicode/utf16"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/rivo/uniseg"
)

type editorTextDrag struct {
	windowID uint16
}

type editorTextTarget struct {
	windowID       uint16
	presentationID uint64
	rowIndex       uint32
	rowID          uint64
	utf16Offset    uint32
	scrollX        int8
	scrollY        int8
}

func isEditorTextDragContinuation(msg tea.MouseMsg) bool {
	switch msg.(type) {
	case tea.MouseMotionMsg, tea.MouseReleaseMsg:
		return true
	default:
		return false
	}
}

func (m Model) handleEditorTextMouse(msg tea.MouseMsg) (Model, []byte, bool) {
	mouse := msg.Mouse()
	button, eventType, supported := editorTextMouseParts(msg)
	if !supported || isWheelButton(mouse.Button) {
		return m, nil, false
	}

	capturedWindowID := uint16(0)
	if m.textDrag != nil {
		capturedWindowID = m.textDrag.windowID
	}
	target, ok := m.editorTextTargetAt(mouse.X, mouse.Y, capturedWindowID)

	if _, release := msg.(tea.MouseReleaseMsg); release {
		m.textDrag = nil
		if !ok && capturedWindowID != 0 {
			return m, protocol.EncodeEditorTextEvent(capturedWindowID, 0, 0, 0, 0, button, keyModToProtocol(mouse.Mod), eventType, 1, 0, 0), true
		}
	}
	if !ok {
		if capturedWindowID != 0 {
			// An active text drag keeps direct ownership until release. Never fall
			// back to the legacy coordinate packet when its immutable target is
			// temporarily unavailable.
			return m, nil, true
		}
		return m, nil, false
	}
	if _, press := msg.(tea.MouseClickMsg); press && mouse.Button == tea.MouseLeft {
		m.textDrag = &editorTextDrag{windowID: target.windowID}
	}
	return m, protocol.EncodeEditorTextEvent(target.windowID, target.presentationID, target.rowIndex, target.rowID, target.utf16Offset, button, keyModToProtocol(mouse.Mod), eventType, 1, target.scrollX, target.scrollY), true
}

func editorTextMouseParts(msg tea.MouseMsg) (button byte, eventType byte, supported bool) {
	mouse := msg.Mouse()
	button = 3
	switch mouse.Button {
	case tea.MouseLeft:
		button = 0
	case tea.MouseMiddle:
		button = 1
	case tea.MouseRight:
		button = 2
	case tea.MouseNone:
	default:
		return 0, 0, false
	}
	switch msg.(type) {
	case tea.MouseClickMsg:
		return button, protocol.MousePress, true
	case tea.MouseReleaseMsg:
		return button, protocol.MouseRelease, true
	case tea.MouseMotionMsg:
		if mouse.Button == tea.MouseNone {
			return button, protocol.MouseMotion, true
		}
		return button, protocol.MouseDrag, true
	default:
		return 0, 0, false
	}
}

func (m Model) editorTextTargetAt(screenX, screenY int, capturedWindowID uint16) (editorTextTarget, bool) {
	if capturedWindowID == 0 && m.editorTextOccluded(screenX, screenY) {
		return editorTextTarget{}, false
	}
	bodyX, bodyY := m.layout.body.Translate(screenX, screenY)
	windowID := capturedWindowID
	if windowID == 0 {
		var ok bool
		windowID, ok = m.presentationScrollWindowAtBody(bodyX, bodyY)
		if !ok {
			return editorTextTarget{}, false
		}
	}
	window, ok := m.windows[windowID]
	if !ok {
		return editorTextTarget{}, false
	}
	presentationID, ok := m.textPresentations[windowID]
	if !ok || presentationID == 0 {
		return editorTextTarget{}, false
	}
	placement, ok := m.semanticWindowPlacement(window)
	if !ok {
		return editorTextTarget{}, false
	}
	gutter, hasGutter := m.windowGutter(window.ID)
	width, height := m.windowRenderDimensions(window, hasGutter, gutter)
	if height <= 0 || width <= 0 {
		return editorTextTarget{}, false
	}

	scrollY := edgeDirection(bodyY, placement.row, placement.row+height)
	localRow := clampInt(bodyY-placement.row, 0, height-1)
	rowCount := m.windowRowCount(window)
	if rowCount == 0 {
		return editorTextTarget{}, false
	}
	sourceRowIndex := min(m.presentationSourceStart(window, height)+localRow, rowCount-1)
	row, ok := m.windowRow(window, sourceRowIndex)
	if !ok || row.ID == 0 {
		return editorTextTarget{}, false
	}

	if computeScrollbar(window, height).active {
		width--
	}
	contentRowIndex := sourceRowIndex - m.presentationPayloadStart(window)
	cursorline := window.Cursorline.Visible && contentRowIndex == int(window.Cursorline.Row)
	gutterWidth := 0
	if hasGutter {
		gutterWidth = lipgloss.Width(m.renderGutterEntry(gutter, sourceRowIndex, cursorline, window.Cursorline.BG))
	}
	contentWidth := max(width-gutterWidth, 1)
	textStart := placement.col + gutterWidth
	textEnd := textStart + contentWidth
	scrollX := edgeDirection(bodyX, textStart, textEnd)
	if capturedWindowID == 0 && (bodyX < textStart || bodyX >= textEnd || bodyY < placement.row || bodyY >= placement.row+height) {
		return editorTextTarget{}, false
	}
	textCol := clampInt(bodyX-textStart, 0, contentWidth-1)
	offset := composedUTF16OffsetAtCell(row.Text, m.presentationScrollEffectiveLeft(window), textCol)
	return editorTextTarget{
		windowID: windowID, presentationID: presentationID, rowIndex: uint32(sourceRowIndex), rowID: row.ID,
		utf16Offset: uint32(offset), scrollX: scrollX, scrollY: scrollY,
	}, true
}

func (m Model) editorTextOccluded(screenX, screenY int) bool {
	if chat, ok := m.agentChat(); ok && chat.Visible {
		return true
	}
	if state, ok := m.emptyState(); ok && state.Visible {
		return true
	}
	if m.pickerVisible() || m.whichKeyVisible() {
		return true
	}
	winner, ok := m.overlayWinner()
	if !ok {
		return false
	}
	rect, ok := m.surfacePlacementFor(winner.surfaceID)
	if !ok || rect.Width == 0 || rect.Height == 0 {
		return false
	}
	return screenX >= int(rect.Col) && screenX < int(rect.Col)+int(rect.Width) &&
		screenY >= int(rect.Row) && screenY < int(rect.Row)+int(rect.Height)
}

func edgeDirection(value, start, end int) int8 {
	if value < start {
		return -1
	}
	if value >= end {
		return 1
	}
	return 0
}

func composedUTF16OffsetAtCell(text string, scrollLeft, cell int) int {
	displayCol := 0
	visibleCol := 0
	utf16Offset := 0
	for graphemes := uniseg.NewGraphemes(text); graphemes.Next(); {
		grapheme := graphemes.Str()
		width := max(displayWidth(grapheme), 1)
		units := utf16Units(grapheme)
		if displayCol+width <= scrollLeft {
			displayCol += width
			utf16Offset += units
			continue
		}
		if cell < visibleCol+width {
			return utf16Offset
		}
		displayCol += width
		visibleCol += width
		utf16Offset += units
	}
	return utf16Offset
}

func utf16Units(text string) int {
	units := 0
	for _, r := range text {
		units += utf16.RuneLen(r)
	}
	return units
}
