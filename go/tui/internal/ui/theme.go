package ui

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
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
	themePopupSelBG     byte = 0x23
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

func (p palette) Base() lipgloss.Color {
	return p.slot(themeModelineBG, "#16181D")
}

func (p palette) Surface() lipgloss.Color {
	return p.slot(themeTabBG, "#20242C")
}

func (p palette) SurfaceAlt() lipgloss.Color {
	return p.slot(themeBreadcrumbBG, "#171B22")
}

func (p palette) Text() lipgloss.Color {
	return p.slot(themeEditorFG, "#D8DEE9")
}

func (p palette) Muted() lipgloss.Color {
	return p.slot(themeModelineFG, "#9AA4B2")
}

func (p palette) Accent() lipgloss.Color {
	return p.slot(themeAccent, "#C7D1FF")
}

func (p palette) Selection() lipgloss.Color {
	return p.slot(themePopupSelBG, "#2D3A4D")
}

func (p palette) Warning() lipgloss.Color {
	return p.slot(themeWarningFG, "#EBCB8B")
}

func (p palette) TreeSurface() lipgloss.Color {
	return p.slot(themeTreeBG, "#151820")
}

func (p palette) TreeText() lipgloss.Color {
	return p.slot(themeTreeFG, "#AEB7C2")
}

func (p palette) TreeSelection() lipgloss.Color {
	return p.slot(themeTreeSelectBG, "#2D3A4D")
}

func (p palette) TreeHeader() lipgloss.Color {
	return p.slot(themeTreeHeaderBG, "#151820")
}

func (p palette) TreeHeaderText() lipgloss.Color {
	return p.slot(themeTreeHeaderFG, "#C7D1FF")
}

func (p palette) TabActive() lipgloss.Color {
	return p.slot(themeTabActiveBG, "#35415A")
}

func (p palette) TabActiveText() lipgloss.Color {
	return p.slot(themeTabActiveFG, "#FFFFFF")
}

func (p palette) TabInactiveText() lipgloss.Color {
	return p.slot(themeTabInactiveFG, "#AEB7C2")
}

func (p palette) TabDirty() lipgloss.Color {
	return p.slot(themeTabModifiedFG, "#EBCB8B")
}

func (p palette) TabAttention() lipgloss.Color {
	return p.slot(themeTabAttentionFG, "#EBCB8B")
}

func (p palette) slot(slot byte, fallback string) lipgloss.Color {
	if p.colors != nil {
		if rgb, ok := p.colors[slot]; ok {
			return lipgloss.Color(fmt.Sprintf("#%06X", rgb))
		}
	}
	return lipgloss.Color(fallback)
}

func (m Model) palette() palette {
	return paletteFrom(m.chrome)
}

func (m Model) panelStyle() lipgloss.Style {
	return lipgloss.NewStyle().Foreground(m.palette().Text()).Background(m.palette().Base()).Width(m.width)
}
