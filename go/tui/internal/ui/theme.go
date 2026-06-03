package ui

import (
	"fmt"
	"image/color"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	themeEditorBG         byte = 0x01
	themeEditorFG         byte = 0x02
	themeTreeBG           byte = 0x03
	themeTreeFG           byte = 0x04
	themeTreeSelectBG     byte = 0x05
	themeTreeHeaderBG     byte = 0x08
	themeTreeHeaderFG     byte = 0x09
	themeTabBG            byte = 0x10
	themeTabActiveBG      byte = 0x11
	themeTabActiveFG      byte = 0x12
	themeTabInactiveFG    byte = 0x13
	themeTabModifiedFG    byte = 0x14
	themeTabAttentionFG   byte = 0x17
	themePopupBG          byte = 0x20
	themePopupFG          byte = 0x21
	themePopupBorder      byte = 0x22
	themePopupSelBG       byte = 0x23
	themePopupSelFG       byte = 0x2A
	themeBreadcrumbBG     byte = 0x27
	themeHighlightReadBG  byte = 0x59
	themeHighlightWriteBG byte = 0x5A
	themeSelectionBG      byte = 0x5B
	themeModelineBG       byte = 0x30
	themeModelineFG       byte = 0x31
	themeAccent           byte = 0x40
	themeGutterFG         byte = 0x50
	themeGutterCurrentFG  byte = 0x51
	themeDiagnosticError  byte = 0x52
	themeWarningFG        byte = 0x53
	themeDiagnosticInfo   byte = 0x54
	themeDiagnosticHint   byte = 0x55
)

type palette struct {
	colors map[byte]uint32
}

func defaultPalette() palette {
	return palette{colors: map[byte]uint32{
		themeEditorBG:         0x282C34,
		themeEditorFG:         0xBBC2CF,
		themeTreeBG:           0x21242B,
		themeTreeFG:           0xBBC2CF,
		themeTreeSelectBG:     0x3E4451,
		themeTreeHeaderBG:     0x282C34,
		themeTreeHeaderFG:     0xBBC2CF,
		themeTabBG:            0x282C34,
		themeTabActiveBG:      0x3E4451,
		themeTabActiveFG:      0xFFFFFF,
		themeTabInactiveFG:    0x5B6268,
		themeTabModifiedFG:    0xFF6C6B,
		themeTabAttentionFG:   0xECBE7B,
		themePopupBG:          0x252A38,
		themePopupFG:          0xD7DDF0,
		themePopupBorder:      0x7A849B,
		themePopupSelBG:       0x2F3650,
		themePopupSelFG:       0xF2F5FF,
		themeBreadcrumbBG:     0x21242B,
		themeModelineBG:       0x22252D,
		themeModelineFG:       0xBBC2CF,
		themeAccent:           0x51AFEF,
		themeGutterFG:         0x5B6268,
		themeGutterCurrentFG:  0xBBC2CF,
		themeDiagnosticError:  0xFF6C6B,
		themeWarningFG:        0xECBE7B,
		themeDiagnosticInfo:   0x51AFEF,
		themeDiagnosticHint:   0x98BE65,
		themeHighlightReadBG:  0x3A3F4B,
		themeHighlightWriteBG: 0x4A3F2B,
		themeSelectionBG:      0x264F78,
	}}
}

func paletteFromTheme(theme protocol.Theme) palette {
	base := defaultPalette()
	for slot, rgb := range theme.Colors {
		base.colors[slot] = rgb
	}
	return base
}

func (p palette) Base() color.Color {
	return p.slot(themeModelineBG)
}

func (p palette) EditorSurface() color.Color {
	return p.slot(themeEditorBG)
}

func (p palette) Surface() color.Color {
	return p.slot(themeTabBG)
}

func (p palette) SurfaceAlt() color.Color {
	return p.slot(themeBreadcrumbBG)
}

func (p palette) Text() color.Color {
	return p.slot(themeEditorFG)
}

func (p palette) Muted() color.Color {
	return p.slot(themeModelineFG)
}

func (p palette) Accent() color.Color {
	return p.slot(themeAccent)
}

func (p palette) Selection() color.Color {
	return p.slot(themeSelectionBG)
}

func (p palette) SelectionText() color.Color {
	return p.slot(themePopupSelFG)
}

func (p palette) SearchMatch(current bool) color.Color {
	if current {
		return p.slot(themeTreeSelectBG)
	}
	return p.slot(themeBreadcrumbBG)
}

func (p palette) DocumentHighlight(kind byte) color.Color {
	switch kind {
	case 3:
		return p.slot(themeHighlightWriteBG)
	case 2:
		return p.slot(themeHighlightReadBG)
	default:
		return p.slot(themeSelectionBG)
	}
}

func (p palette) Diagnostic(severity byte) color.Color {
	switch severity {
	case 0:
		return p.slot(themeDiagnosticError)
	case 1:
		return p.slot(themeWarningFG)
	case 2:
		return p.slot(themeDiagnosticInfo)
	case 3:
		return p.slot(themeDiagnosticHint)
	default:
		return p.slot(themeWarningFG)
	}
}

func (p palette) Warning() color.Color {
	return p.slot(themeWarningFG)
}

func (p palette) GutterText() color.Color {
	return p.slot(themeGutterFG)
}

func (p palette) GutterCurrentText() color.Color {
	return p.slot(themeGutterCurrentFG)
}

func (p palette) TreeSurface() color.Color {
	return p.slot(themeTreeBG)
}

func (p palette) TreeText() color.Color {
	return p.slot(themeTreeFG)
}

func (p palette) TreeSelection() color.Color {
	return p.slot(themeTreeSelectBG)
}

func (p palette) TreeHeader() color.Color {
	return p.slot(themeTreeHeaderBG)
}

func (p palette) TreeHeaderText() color.Color {
	return p.slot(themeTreeHeaderFG)
}

func (p palette) TabActive() color.Color {
	return p.slot(themeTabActiveBG)
}

func (p palette) TabActiveText() color.Color {
	return p.slot(themeTabActiveFG)
}

func (p palette) TabInactiveText() color.Color {
	return p.slot(themeTabInactiveFG)
}

func (p palette) TabDirty() color.Color {
	return p.slot(themeTabModifiedFG)
}

func (p palette) TabAttention() color.Color {
	return p.slot(themeTabAttentionFG)
}

func (p palette) PopupSurface() color.Color {
	return p.slot(themePopupBG)
}

func (p palette) PopupText() color.Color {
	return p.slot(themePopupFG)
}

func (p palette) PopupBorder() color.Color {
	return p.slot(themePopupBorder)
}

func (p palette) PopupSelection() color.Color {
	return p.slot(themePopupSelBG)
}

func (p palette) PopupSelectionText() color.Color {
	return p.slot(themePopupSelFG)
}

func (p palette) PopupChrome() color.Color {
	return lipgloss.Color("#202532")
}

func (p palette) slot(slot byte) color.Color {
	if rgb, ok := p.colors[slot]; ok {
		return lipgloss.Color(fmt.Sprintf("#%06X", rgb))
	}
	return lipgloss.NoColor{}
}

func (m Model) palette() palette {
	return m.activePalette
}

func (m Model) editorBackground() color.Color {
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
