package ui

import (
	"fmt"
	"image/color"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	// Slot IDs mirror MingaEditor.UI.Theme.Slots. The bootstrap values below are only used before the first BEAM gui_theme command arrives.
	themeEditorBG         byte = 0x01
	themeEditorFG         byte = 0x02
	themeTreeBG           byte = 0x03
	themeTreeFG           byte = 0x04
	themeTreeSelectBG     byte = 0x05
	themeTreeDirFG        byte = 0x06
	themeTreeActiveFG     byte = 0x07
	themeTreeHeaderBG     byte = 0x08
	themeTreeHeaderFG     byte = 0x09
	themeTreeSeparatorFG  byte = 0x0A
	themeTreeSelectionFG  byte = 0x0E
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
	themePopupKeyFG       byte = 0x24
	themePopupGroupFG     byte = 0x25
	themePopupDescFG      byte = 0x26
	themeBreadcrumbBG     byte = 0x27
	themePopupSelFG       byte = 0x2A
	themeModelineBG       byte = 0x30
	themeModelineFG       byte = 0x31
	themeAccent           byte = 0x40
	themeGutterFG         byte = 0x50
	themeGutterCurrentFG  byte = 0x51
	themeDiagnosticError  byte = 0x52
	themeWarningFG        byte = 0x53
	themeDiagnosticInfo   byte = 0x54
	themeDiagnosticHint   byte = 0x55
	themeHighlightReadBG  byte = 0x59
	themeHighlightWriteBG byte = 0x5A
	themeSelectionBG      byte = 0x5B
)

var requiredThemeSlots = []byte{
	0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
	0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
	0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
	0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A,
	0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A,
	0x40,
	0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x5B,
	0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61,
	0x62,
	0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE,
}

type palette struct {
	colors map[byte]uint32
}

func bootstrapPalette() palette {
	return palette{colors: map[byte]uint32{
		themeEditorBG:         0x000000,
		themeEditorFG:         0xFFFFFF,
		themeTreeBG:           0x000000,
		themeTreeFG:           0xFFFFFF,
		themeTreeSelectBG:     0x333333,
		themeTreeDirFG:        0xFFFFFF,
		themeTreeActiveFG:     0xFFFFFF,
		themeTreeHeaderBG:     0x000000,
		themeTreeHeaderFG:     0xFFFFFF,
		themeTreeSeparatorFG:  0x666666,
		themeTreeSelectionFG:  0xFFFFFF,
		themeTabBG:            0x000000,
		themeTabActiveBG:      0x333333,
		themeTabActiveFG:      0xFFFFFF,
		themeTabInactiveFG:    0x999999,
		themeTabModifiedFG:    0xFFAA00,
		themeTabAttentionFG:   0xFFAA00,
		themePopupBG:          0x000000,
		themePopupFG:          0xFFFFFF,
		themePopupBorder:      0x666666,
		themePopupSelBG:       0x333333,
		themePopupKeyFG:       0xFFFFFF,
		themePopupGroupFG:     0xFFFFFF,
		themePopupDescFG:      0xFFFFFF,
		themeBreadcrumbBG:     0x000000,
		themePopupSelFG:       0xFFFFFF,
		themeModelineBG:       0x000000,
		themeModelineFG:       0xFFFFFF,
		themeAccent:           0xFFFFFF,
		themeGutterFG:         0x999999,
		themeGutterCurrentFG:  0xFFFFFF,
		themeDiagnosticError:  0xFF0000,
		themeWarningFG:        0xFFAA00,
		themeDiagnosticInfo:   0x00AAFF,
		themeDiagnosticHint:   0x999999,
		themeHighlightReadBG:  0x333333,
		themeHighlightWriteBG: 0x333333,
		themeSelectionBG:      0x333333,
	}}
}

func paletteFromTheme(theme protocol.Theme) palette {
	colors := make(map[byte]uint32, len(theme.Colors))
	for slot, rgb := range theme.Colors {
		colors[slot] = rgb
	}
	return palette{colors: colors}
}

func missingThemeSlots(theme protocol.Theme) []byte {
	missing := make([]byte, 0, len(requiredThemeSlots))
	for _, slot := range requiredThemeSlots {
		if _, ok := theme.Colors[slot]; !ok {
			missing = append(missing, slot)
		}
	}
	return missing
}

func formatMissingThemeSlots(slots []byte) string {
	if len(slots) == 0 {
		return ""
	}

	parts := make([]string, len(slots))
	for i, slot := range slots {
		parts[i] = fmt.Sprintf("0x%02X", slot)
	}
	return strings.Join(parts, ", ")
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
	return p.slot(themeTabInactiveFG)
}

func (p palette) ChromeText() color.Color {
	return p.slot(themeModelineFG)
}

func (p palette) ChromeMuted() color.Color {
	return p.slot(themeTabInactiveFG)
}

func (p palette) ChromeSurface() color.Color {
	return p.slot(themeModelineBG)
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

func (p palette) TreeMutedText() color.Color {
	return p.slot(themeTabInactiveFG)
}

func (p palette) TreeGuide() color.Color {
	return p.slot(themeTreeSeparatorFG)
}

func (p palette) TreeDirectoryText() color.Color {
	return p.slot(themeTreeDirFG)
}

func (p palette) TreeSelection() color.Color {
	return p.slot(themeTreeSelectBG)
}

func (p palette) TreeSelectionText() color.Color {
	return p.slot(themeTreeSelectionFG)
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
	return p.slot(themeBreadcrumbBG)
}

func (p palette) PopupMutedText() color.Color {
	return p.slot(themePopupDescFG)
}

func (p palette) KeycapSurface() color.Color {
	return p.slot(themePopupSelBG)
}

func (p palette) KeycapText() color.Color {
	return p.slot(themePopupKeyFG)
}

func (p palette) Error() color.Color {
	return p.slot(themeDiagnosticError)
}

func (p palette) Info() color.Color {
	return p.slot(themeDiagnosticInfo)
}

func (p palette) Hint() color.Color {
	return p.slot(themeDiagnosticHint)
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
