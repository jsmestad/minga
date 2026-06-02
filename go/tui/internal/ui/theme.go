package ui

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	themeEditorBG       byte = 0x01
	themeEditorFG       byte = 0x02
	themeTreeBG         byte = 0x03
	themeTreeFG         byte = 0x04
	themeTreeSelectBG   byte = 0x05
	themeTreeHeaderBG   byte = 0x08
	themeTreeHeaderFG   byte = 0x09
	themeTabBG          byte = 0x10
	themeTabActiveBG    byte = 0x11
	themeTabActiveFG    byte = 0x12
	themeTabInactiveFG  byte = 0x13
	themeTabModifiedFG  byte = 0x14
	themeTabAttentionFG byte = 0x17
	themePopupBG        byte = 0x20
	themePopupFG        byte = 0x21
	themePopupBorder    byte = 0x22
	themePopupSelBG     byte = 0x23
	themePopupSelFG     byte = 0x2A
	themeBreadcrumbBG   byte = 0x27
	themeModelineBG     byte = 0x30
	themeModelineFG     byte = 0x31
	themeAccent         byte = 0x40
	themeWarningFG      byte = 0x53
)

type palette struct {
	colors map[byte]uint32
}

func paletteFrom(chrome map[byte]protocol.ChromePayload) palette {
	for _, payload := range chrome {
		if payload.Theme.Colors != nil {
			return palette{colors: payload.Theme.Colors}
		}
	}
	return palette{}
}

func (p palette) Base() lipgloss.TerminalColor {
	return p.slot(themeModelineBG)
}

func (p palette) EditorSurface() lipgloss.TerminalColor {
	return p.slot(themeEditorBG)
}

func (p palette) Surface() lipgloss.TerminalColor {
	return p.slot(themeTabBG)
}

func (p palette) SurfaceAlt() lipgloss.TerminalColor {
	return p.slot(themeBreadcrumbBG)
}

func (p palette) Text() lipgloss.TerminalColor {
	return p.slot(themeEditorFG)
}

func (p palette) Muted() lipgloss.TerminalColor {
	return p.slot(themeModelineFG)
}

func (p palette) Accent() lipgloss.TerminalColor {
	return p.slot(themeAccent)
}

func (p palette) Selection() lipgloss.TerminalColor {
	return p.slot(themePopupSelBG)
}

func (p palette) SelectionText() lipgloss.TerminalColor {
	return p.slot(themePopupSelFG)
}

func (p palette) Warning() lipgloss.TerminalColor {
	return p.slot(themeWarningFG)
}

func (p palette) TreeSurface() lipgloss.TerminalColor {
	return p.slot(themeTreeBG)
}

func (p palette) TreeText() lipgloss.TerminalColor {
	return p.slot(themeTreeFG)
}

func (p palette) TreeSelection() lipgloss.TerminalColor {
	return p.slot(themeTreeSelectBG)
}

func (p palette) TreeHeader() lipgloss.TerminalColor {
	return p.slot(themeTreeHeaderBG)
}

func (p palette) TreeHeaderText() lipgloss.TerminalColor {
	return p.slot(themeTreeHeaderFG)
}

func (p palette) TabActive() lipgloss.TerminalColor {
	return p.slot(themeTabActiveBG)
}

func (p palette) TabActiveText() lipgloss.TerminalColor {
	return p.slot(themeTabActiveFG)
}

func (p palette) TabInactiveText() lipgloss.TerminalColor {
	return p.slot(themeTabInactiveFG)
}

func (p palette) TabDirty() lipgloss.TerminalColor {
	return p.slot(themeTabModifiedFG)
}

func (p palette) TabAttention() lipgloss.TerminalColor {
	return p.slot(themeTabAttentionFG)
}

func (p palette) PopupSurface() lipgloss.TerminalColor {
	return p.slot(themePopupBG)
}

func (p palette) PopupText() lipgloss.TerminalColor {
	return p.slot(themePopupFG)
}

func (p palette) PopupBorder() lipgloss.TerminalColor {
	return p.slot(themePopupBorder)
}

func (p palette) slot(slot byte) lipgloss.TerminalColor {
	if p.colors != nil {
		if rgb, ok := p.colors[slot]; ok {
			return lipgloss.Color(fmt.Sprintf("#%06X", rgb))
		}
	}
	return lipgloss.NoColor{}
}

func (m Model) palette() palette {
	return paletteFrom(m.chrome)
}

func (m Model) editorBackground() lipgloss.TerminalColor {
	if m.bg != 0 {
		return lipgloss.Color(fmt.Sprintf("#%06X", m.bg))
	}
	return m.palette().EditorSurface()
}

func (m Model) editorStyle() lipgloss.Style {
	return lipgloss.NewStyle().Foreground(m.palette().Text()).Background(m.editorBackground()).Width(m.width)
}

func (m Model) panelStyle() lipgloss.Style {
	return lipgloss.NewStyle().Foreground(m.palette().Text()).Background(m.palette().Base()).Width(m.width)
}
