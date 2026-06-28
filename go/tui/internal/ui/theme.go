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
	themeEditorBG              byte = 0x01
	themeEditorFG              byte = 0x02
	themeTreeBG                byte = 0x03
	themeTreeFG                byte = 0x04
	themeTreeSelectBG          byte = 0x05
	themeTreeDirFG             byte = 0x06
	themeTreeActiveFG          byte = 0x07
	themeTreeHeaderBG          byte = 0x08
	themeTreeHeaderFG          byte = 0x09
	themeTreeSeparatorFG       byte = 0x0A
	themeTreeGitModified       byte = 0x0B
	themeTreeGitStaged         byte = 0x0C
	themeTreeGitUntracked      byte = 0x0D
	themeTreeSelectionFG       byte = 0x0E
	themeTreeGuideFG           byte = 0x0F
	themeTabBG                 byte = 0x10
	themeTabActiveBG           byte = 0x11
	themeTabActiveFG           byte = 0x12
	themeTabInactiveFG         byte = 0x13
	themeTabModifiedFG         byte = 0x14
	themeTabSeparatorFG        byte = 0x15
	themeTabCloseHoverFG       byte = 0x16
	themeTabAttentionFG        byte = 0x17
	themePopupBG               byte = 0x20
	themePopupFG               byte = 0x21
	themePopupBorder           byte = 0x22
	themePopupSelBG            byte = 0x23
	themePopupKeyFG            byte = 0x24
	themePopupGroupFG          byte = 0x25
	themePopupDescFG           byte = 0x26
	themeBreadcrumbBG          byte = 0x27
	themeBreadcrumbFG          byte = 0x28
	themeBreadcrumbSepFG       byte = 0x29
	themePopupSelFG            byte = 0x2A
	themeModelineBG            byte = 0x30
	themeModelineFG            byte = 0x31
	themeModelineInfoBG        byte = 0x32
	themeModelineInfoFG        byte = 0x33
	themeModeNormalBG          byte = 0x34
	themeModeNormalFG          byte = 0x35
	themeModeInsertBG          byte = 0x36
	themeModeInsertFG          byte = 0x37
	themeModeVisualBG          byte = 0x38
	themeModeVisualFG          byte = 0x39
	themeStatusbarAccent       byte = 0x3A
	themeAccent                byte = 0x40
	themeGutterFG              byte = 0x50
	themeGutterCurrentFG       byte = 0x51
	themeDiagnosticError       byte = 0x52
	themeWarningFG             byte = 0x53
	themeDiagnosticInfo        byte = 0x54
	themeDiagnosticHint        byte = 0x55
	themeGitAddedFG            byte = 0x56
	themeGitModifiedFG         byte = 0x57
	themeGitDeletedFG          byte = 0x58
	themeHighlightReadBG       byte = 0x59
	themeHighlightWriteBG      byte = 0x5A
	themeSelectionBG           byte = 0x5B
	themeAgentStatusIdle       byte = 0x5C
	themeAgentStatusWorking    byte = 0x5D
	themeAgentStatusIterating  byte = 0x5E
	themeAgentStatusNeedsYou   byte = 0x5F
	themeAgentStatusDone       byte = 0x60
	themeAgentStatusErrored    byte = 0x61
	themeGutterFoldFG          byte = 0x62
	themeAgentPanelBG          byte = 0xA0
	themeAgentHeaderBG         byte = 0xA1
	themeAgentHeaderFG         byte = 0xA2
	themeAgentUserBorder       byte = 0xA3
	themeAgentUserLabel        byte = 0xA4
	themeAgentAssistantBorder  byte = 0xA5
	themeAgentAssistantLabel   byte = 0xA6
	themeAgentInputBorder      byte = 0xA7
	themeAgentInputBG          byte = 0xA8
	themeAgentInputPlaceholder byte = 0xA9
	themeAgentTextFG           byte = 0xAA
	themeAgentToolBorder       byte = 0xAB
	themeAgentToolHeader       byte = 0xAC
	themeAgentCodeBG           byte = 0xAD
	themeAgentCodeBorder       byte = 0xAE
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
		themeEditorBG:              0x000000,
		themeEditorFG:              0xFFFFFF,
		themeTreeBG:                0x000000,
		themeTreeFG:                0xFFFFFF,
		themeTreeSelectBG:          0x333333,
		themeTreeDirFG:             0xFFFFFF,
		themeTreeActiveFG:          0xFFFFFF,
		themeTreeHeaderBG:          0x000000,
		themeTreeHeaderFG:          0xFFFFFF,
		themeTreeSeparatorFG:       0x666666,
		themeTreeGitModified:       0xE5C07B,
		themeTreeGitStaged:         0x98C379,
		themeTreeGitUntracked:      0x808080,
		themeTreeSelectionFG:       0xFFFFFF,
		themeTreeGuideFG:           0x444444,
		themeTabBG:                 0x000000,
		themeTabActiveBG:           0x333333,
		themeTabActiveFG:           0xFFFFFF,
		themeTabInactiveFG:         0x999999,
		themeTabModifiedFG:         0xFFAA00,
		themeTabSeparatorFG:        0x444444,
		themeTabCloseHoverFG:       0xFF5555,
		themeTabAttentionFG:        0xFFAA00,
		themePopupBG:               0x000000,
		themePopupFG:               0xFFFFFF,
		themePopupBorder:           0x666666,
		themePopupSelBG:            0x333333,
		themePopupKeyFG:            0xFFFFFF,
		themePopupGroupFG:          0xFFFFFF,
		themePopupDescFG:           0xFFFFFF,
		themeBreadcrumbBG:          0x000000,
		themeBreadcrumbFG:          0xCCCCCC,
		themeBreadcrumbSepFG:       0x666666,
		themePopupSelFG:            0xFFFFFF,
		themeModelineBG:            0x000000,
		themeModelineFG:            0xFFFFFF,
		themeModelineInfoBG:        0x222222,
		themeModelineInfoFG:        0xCCCCCC,
		themeModeNormalBG:          0x61AFEF,
		themeModeNormalFG:          0x1E1E1E,
		themeModeInsertBG:          0x98C379,
		themeModeInsertFG:          0x1E1E1E,
		themeModeVisualBG:          0xC678DD,
		themeModeVisualFG:          0x1E1E1E,
		themeStatusbarAccent:       0x61AFEF,
		themeAccent:                0xFFFFFF,
		themeGutterFG:              0x999999,
		themeGutterCurrentFG:       0xFFFFFF,
		themeDiagnosticError:       0xFF0000,
		themeWarningFG:             0xFFAA00,
		themeDiagnosticInfo:        0x00AAFF,
		themeDiagnosticHint:        0x999999,
		themeGitAddedFG:            0x98C379,
		themeGitModifiedFG:         0xE5C07B,
		themeGitDeletedFG:          0xE06C75,
		themeHighlightReadBG:       0x333333,
		themeHighlightWriteBG:      0x333333,
		themeSelectionBG:           0x333333,
		themeAgentStatusIdle:       0x808080,
		themeAgentStatusWorking:    0x61AFEF,
		themeAgentStatusIterating:  0xE5C07B,
		themeAgentStatusNeedsYou:   0xE06C75,
		themeAgentStatusDone:       0x98C379,
		themeAgentStatusErrored:    0xE06C75,
		themeGutterFoldFG:          0x666666,
		themeAgentPanelBG:          0x1E1E1E,
		themeAgentHeaderBG:         0x2D2D2D,
		themeAgentHeaderFG:         0xCCCCCC,
		themeAgentUserBorder:       0x61AFEF,
		themeAgentUserLabel:        0x61AFEF,
		themeAgentAssistantBorder:  0x555555,
		themeAgentAssistantLabel:   0x808080,
		themeAgentInputBorder:      0x61AFEF,
		themeAgentInputBG:          0x1E1E1E,
		themeAgentInputPlaceholder: 0x666666,
		themeAgentTextFG:           0xCCCCCC,
		themeAgentToolBorder:       0x555555,
		themeAgentToolHeader:       0x999999,
		themeAgentCodeBG:           0x2D2D2D,
		themeAgentCodeBorder:       0x444444,
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

func (p palette) TreeDirectoryText() color.Color {
	return p.slot(themeTreeDirFG)
}

func (p palette) TreeSeparator() color.Color {
	return p.slot(themeTreeSeparatorFG)
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

func (p palette) slotOr(slot byte, fallback byte) color.Color {
	if _, ok := p.colors[slot]; ok {
		return p.slot(slot)
	}
	return p.slot(fallback)
}

// --- Tree git status ---

func (p palette) TreeGitModified() color.Color {
	return p.slotOr(themeTreeGitModified, themeWarningFG)
}

func (p palette) TreeGitStaged() color.Color {
	return p.slotOr(themeTreeGitStaged, themeAccent)
}

func (p palette) TreeGitUntracked() color.Color {
	return p.slotOr(themeTreeGitUntracked, themeTabInactiveFG)
}

func (p palette) TreeGuide() color.Color {
	return p.slotOr(themeTreeGuideFG, themeTreeSeparatorFG)
}

// --- Tab bar ---

func (p palette) TabSeparator() color.Color {
	return p.slotOr(themeTabSeparatorFG, themeTreeSeparatorFG)
}

func (p palette) TabCloseHover() color.Color {
	return p.slotOr(themeTabCloseHoverFG, themeDiagnosticError)
}

// --- Breadcrumb ---

func (p palette) BreadcrumbText() color.Color {
	return p.slotOr(themeBreadcrumbFG, themeModelineFG)
}

func (p palette) BreadcrumbSeparator() color.Color {
	return p.slotOr(themeBreadcrumbSepFG, themeTabInactiveFG)
}

// --- Modeline / Status ---

func (p palette) ModelineInfo() color.Color {
	return p.slotOr(themeModelineInfoBG, themeModelineBG)
}

func (p palette) ModelineInfoText() color.Color {
	return p.slotOr(themeModelineInfoFG, themeModelineFG)
}

func (p palette) ModeNormal() color.Color {
	return p.slotOr(themeModeNormalBG, themeAccent)
}

func (p palette) ModeNormalText() color.Color {
	return p.slotOr(themeModeNormalFG, themeEditorBG)
}

func (p palette) ModeInsert() color.Color {
	return p.slotOr(themeModeInsertBG, themeAccent)
}

func (p palette) ModeInsertText() color.Color {
	return p.slotOr(themeModeInsertFG, themeEditorBG)
}

func (p palette) ModeVisual() color.Color {
	return p.slotOr(themeModeVisualBG, themeAccent)
}

func (p palette) ModeVisualText() color.Color {
	return p.slotOr(themeModeVisualFG, themeEditorBG)
}

func (p palette) StatusbarAccent() color.Color {
	return p.slotOr(themeStatusbarAccent, themeAccent)
}

// --- Git gutter signs ---

func (p palette) GitAdded() color.Color {
	return p.slotOr(themeGitAddedFG, themeAccent)
}

func (p palette) GitModified() color.Color {
	return p.slotOr(themeGitModifiedFG, themeWarningFG)
}

func (p palette) GitDeleted() color.Color {
	return p.slotOr(themeGitDeletedFG, themeDiagnosticError)
}

// --- Agent status badges ---

func (p palette) AgentStatusIdle() color.Color {
	return p.slotOr(themeAgentStatusIdle, themeTabInactiveFG)
}

func (p palette) AgentStatusWorking() color.Color {
	return p.slotOr(themeAgentStatusWorking, themeAccent)
}

func (p palette) AgentStatusIterating() color.Color {
	return p.slotOr(themeAgentStatusIterating, themeWarningFG)
}

func (p palette) AgentStatusNeedsYou() color.Color {
	return p.slotOr(themeAgentStatusNeedsYou, themeDiagnosticError)
}

func (p palette) AgentStatusDone() color.Color {
	return p.slotOr(themeAgentStatusDone, themeAccent)
}

func (p palette) AgentStatusErrored() color.Color {
	return p.slotOr(themeAgentStatusErrored, themeDiagnosticError)
}

// --- Gutter fold ---

func (p palette) GutterFold() color.Color {
	return p.slotOr(themeGutterFoldFG, themeGutterFG)
}

// --- Agent chat palette ---

func (p palette) AgentPanel() color.Color {
	return p.slotOr(themeAgentPanelBG, themeEditorBG)
}

func (p palette) AgentHeader() color.Color {
	return p.slotOr(themeAgentHeaderBG, themeModelineBG)
}

func (p palette) AgentHeaderText() color.Color {
	return p.slotOr(themeAgentHeaderFG, themeModelineFG)
}

func (p palette) AgentUserBorder() color.Color {
	return p.slotOr(themeAgentUserBorder, themeAccent)
}

func (p palette) AgentUserLabel() color.Color {
	return p.slotOr(themeAgentUserLabel, themeAccent)
}

func (p palette) AgentAssistantBorder() color.Color {
	return p.slotOr(themeAgentAssistantBorder, themeTreeSeparatorFG)
}

func (p palette) AgentAssistantLabel() color.Color {
	return p.slotOr(themeAgentAssistantLabel, themeTabInactiveFG)
}

func (p palette) AgentInputBorder() color.Color {
	return p.slotOr(themeAgentInputBorder, themeAccent)
}

func (p palette) AgentInputSurface() color.Color {
	return p.slotOr(themeAgentInputBG, themeEditorBG)
}

func (p palette) AgentInputPlaceholder() color.Color {
	return p.slotOr(themeAgentInputPlaceholder, themeTabInactiveFG)
}

func (p palette) AgentText() color.Color {
	return p.slotOr(themeAgentTextFG, themeEditorFG)
}

func (p palette) AgentToolBorder() color.Color {
	return p.slotOr(themeAgentToolBorder, themeTreeSeparatorFG)
}

func (p palette) AgentToolHeader() color.Color {
	return p.slotOr(themeAgentToolHeader, themeModelineFG)
}

func (p palette) AgentCodeSurface() color.Color {
	return p.slotOr(themeAgentCodeBG, themePopupBG)
}

func (p palette) AgentCodeBorder() color.Color {
	return p.slotOr(themeAgentCodeBorder, themePopupBorder)
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
