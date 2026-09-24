package ui

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	fileTreeVisibleFlag            byte = 0x01
	fileTreeFocusedFlag            byte = 0x02
	fileTreeLocalNavigationFlag    byte = 0x20
	fileTreeReadyStatus            byte = 3
	fileTreeLocalNavigationDownKey rune = 'j'
	fileTreeLocalNavigationUpKey   rune = 'k'
)

func (m *Model) reconcileFileTree(tree protocol.FileTree) {
	retained := make(map[string]struct{}, len(tree.Rows))
	for _, row := range tree.Rows {
		retained[row.ID] = struct{}{}
	}
	m.localPresentation.reconcileIdentity(presentationFileTree, tree.Generation, tree.Selected, retained, tree.Visible)
}

func (m *Model) reconcileCompletion(completion protocol.Completion) {
	retained := make(map[string]struct{}, len(completion.Items))
	for _, item := range completion.Items {
		retained[item.ID] = struct{}{}
	}
	m.localPresentation.reconcileIdentity(presentationCompletion, completion.Generation, completion.SelectedID, retained, completion.Visible)
}

func (m *Model) reconcilePicker(picker protocol.Picker) {
	retained := make(map[string]struct{}, len(picker.Items))
	for _, item := range picker.Items {
		retained[pickerItemID(item)] = struct{}{}
	}
	committedID := ""
	if picker.SelectedID != 0 {
		committedID = fmt.Sprintf("%d", picker.SelectedID)
	} else if int(picker.Selected) < len(picker.Items) {
		committedID = pickerItemID(picker.Items[picker.Selected])
	}
	m.localPresentation.reconcileIdentity(presentationPicker, picker.Generation, committedID, retained, picker.Visible)
}

func (m *Model) applyFileTreeSelection(selection protocol.FileTreeSelection) {
	payload, ok := m.chrome[generated.OPGuiFileTree]
	if !ok || len(payload.Tree.Rows) == 0 || selection.Generation != payload.Tree.Generation {
		m.localPresentation.discardIdentity(presentationFileTree)
		return
	}
	payload.Tree.Focused = selection.Focused
	payload.Tree.Selected = selection.SelectedID
	for i := range payload.Tree.Rows {
		selected := payload.Tree.Rows[i].ID == selection.SelectedID
		payload.Tree.Rows[i].Selected = selected
		payload.Tree.Rows[i].Focused = selected && selection.Focused
	}
	m.chrome[generated.OPGuiFileTree] = payload
	m.reconcileFileTree(payload.Tree)
}

func (m *Model) applyCompletionSelection(selection protocol.CompletionSelection) {
	payload, ok := m.chrome[generated.OPGuiCompletion]
	if !ok || selection.Generation != payload.Complete.Generation || completionItemIndex(payload.Complete, selection.SelectedID) < 0 {
		m.localPresentation.discardIdentity(presentationCompletion)
		return
	}
	payload.Complete.SelectedID = selection.SelectedID
	payload.Complete.Selected = uint16(completionItemIndex(payload.Complete, selection.SelectedID))
	payload.Complete.Documentation = selection.Documentation
	m.chrome[generated.OPGuiCompletion] = payload
	m.reconcileCompletion(payload.Complete)
}

func (m *Model) applyPickerSelection(selection protocol.PickerSelection) {
	payload, ok := m.chrome[generated.OPGuiPicker]
	if !ok || selection.Generation != payload.Picker.Generation {
		m.localPresentation.discardIdentity(presentationPicker)
		return
	}
	if index := pickerItemIndex(payload.Picker, selection.SelectedID); index >= 0 {
		payload.Picker.Selected = uint16(index)
		payload.Picker.SelectedID = selection.SelectedID
	} else {
		m.localPresentation.discardIdentity(presentationPicker)
	}
	payload.Picker.SelectedActionID = selection.SelectedActionID
	for index, activationID := range payload.Picker.ActionActivationIDs {
		if activationID == selection.SelectedActionID {
			payload.Picker.ActionIndex = byte(index)
			break
		}
	}
	m.chrome[generated.OPGuiPicker] = payload
	m.reconcilePicker(payload.Picker)
}

func (m *Model) previewFileTreeNavigation(msg tea.KeyPressMsg) bool {
	key := msg.Key()
	if key.Mod.Contains(tea.ModShift) || key.Mod.Contains(tea.ModAlt) || key.Mod.Contains(tea.ModCtrl) || key.Mod.Contains(tea.ModSuper) {
		return false
	}

	delta, ok := fileTreeNavigationDelta(key)
	if !ok {
		return false
	}

	payload, ok := m.fileTree()
	if !ok || !payload.Visible || !payload.Focused || payload.Flags&fileTreeLocalNavigationFlag == 0 || payload.Status != fileTreeReadyStatus || len(payload.Rows) == 0 {
		return false
	}

	selectedIndex := m.effectiveFileTreeIndex(payload)
	if selectedIndex < 0 {
		return false
	}

	nextIndex := selectedIndex + delta
	if nextIndex < 0 {
		nextIndex = 0
	} else if nextIndex >= len(payload.Rows) {
		nextIndex = len(payload.Rows) - 1
	}
	if nextIndex == selectedIndex {
		return false
	}

	m.localPresentation.setIdentityPreview(presentationFileTree, payload.Generation, payload.Rows[nextIndex].ID)
	return true
}

func fileTreeNavigationDelta(key tea.Key) (int, bool) {
	switch key.Code {
	case fileTreeLocalNavigationDownKey, tea.KeyDown:
		return 1, true
	case fileTreeLocalNavigationUpKey, tea.KeyUp:
		return -1, true
	default:
		return 0, false
	}
}

func fileTreeSelectedIndex(tree protocol.FileTree) int {
	if tree.Selected != "" {
		for i, row := range tree.Rows {
			if row.ID == tree.Selected {
				return i
			}
		}
	}
	for i, row := range tree.Rows {
		if row.Selected {
			return i
		}
	}
	return -1
}

func fileTreeItemIndex(tree protocol.FileTree, itemID string) int {
	for index, row := range tree.Rows {
		if row.ID == itemID {
			return index
		}
	}
	return -1
}

func (m Model) effectiveFileTreeIndex(tree protocol.FileTree) int {
	if preview, ok := m.localPresentation.identityPreview(presentationFileTree); ok && preview.generation == tree.Generation {
		for index, row := range tree.Rows {
			if row.ID == preview.itemID {
				return index
			}
		}
	}
	return fileTreeSelectedIndex(tree)
}

func (m *Model) previewCompletionNavigation(msg tea.KeyPressMsg) bool {
	key := msg.Key()

	var delta int
	if key.Mod.Contains(tea.ModCtrl) && !key.Mod.Contains(tea.ModShift) && !key.Mod.Contains(tea.ModAlt) && !key.Mod.Contains(tea.ModSuper) {
		switch key.Code {
		case 'n':
			delta = 1
		case 'p':
			delta = -1
		default:
			return false
		}
	} else if !key.Mod.Contains(tea.ModCtrl) && !key.Mod.Contains(tea.ModShift) && !key.Mod.Contains(tea.ModAlt) && !key.Mod.Contains(tea.ModSuper) {
		switch key.Code {
		case tea.KeyDown:
			delta = 1
		case tea.KeyUp:
			delta = -1
		default:
			return false
		}
	} else {
		return false
	}

	payload, ok := m.chrome[generated.OPGuiCompletion]
	if !ok || !payload.Complete.Visible || len(payload.Complete.Items) == 0 {
		return false
	}

	current := m.effectiveCompletionIndex(payload.Complete)

	next := current + delta
	if next < 0 {
		next = 0
	} else if next >= len(payload.Complete.Items) {
		next = len(payload.Complete.Items) - 1
	}
	if next == current {
		return false
	}

	m.localPresentation.setIdentityPreview(presentationCompletion, payload.Complete.Generation, payload.Complete.Items[next].ID)
	return true
}

func (m Model) effectiveCompletionIndex(completion protocol.Completion) int {
	if preview, ok := m.localPresentation.identityPreview(presentationCompletion); ok && preview.generation == completion.Generation {
		if index := completionItemIndex(completion, preview.itemID); index >= 0 {
			return index
		}
	}
	if index := completionItemIndex(completion, completion.SelectedID); index >= 0 {
		return index
	}
	return min(max(int(completion.Selected), 0), max(len(completion.Items)-1, 0))
}

func (m Model) localPreviewActivationPacket(msg tea.KeyPressMsg) ([]byte, bool) {
	key := msg.Key()
	if key.Code != tea.KeyEnter && key.Code != tea.KeyKpEnter {
		return nil, false
	}
	if key.Mod.Contains(tea.ModCtrl) || key.Mod.Contains(tea.ModShift) || key.Mod.Contains(tea.ModAlt) || key.Mod.Contains(tea.ModSuper) {
		return nil, false
	}
	if preview, ok := m.localPresentation.identityPreview(presentationCompletion); ok {
		if completion, present := m.completion(); present && completion.Visible && preview.generation == completion.Generation && completionItemIndex(completion, preview.itemID) >= 0 {
			return protocol.EncodeGUISemanticItemActivate(byte(presentationCompletion), 1, preview.generation, []byte(preview.itemID)), true
		}
	}
	if preview, ok := m.localPresentation.identityPreview(presentationPicker); ok {
		if picker, present := m.picker(); present && picker.Visible && preview.generation == picker.Generation {
			index := pickerItemIndexByID(picker, preview.itemID)
			if index >= 0 {
				activationID := picker.Items[index].ActivationID
				itemID := []byte{byte(activationID >> 24), byte(activationID >> 16), byte(activationID >> 8), byte(activationID)}
				return protocol.EncodeGUISemanticItemActivate(byte(presentationPicker), 1, preview.generation, itemID), true
			}
		}
	}
	if !m.modalOverlayActive() {
		if preview, ok := m.localPresentation.identityPreview(presentationFileTree); ok {
			if tree, present := m.fileTree(); present && tree.Visible && preview.generation == tree.Generation && fileTreeItemIndex(tree, preview.itemID) >= 0 {
				return protocol.EncodeGUISemanticItemActivate(byte(presentationFileTree), 1, preview.generation, []byte(preview.itemID)), true
			}
		}
	}
	return nil, false
}

func (m *Model) previewPickerNavigation(msg tea.KeyPressMsg) bool {
	key := msg.Key()
	if key.Mod.Contains(tea.ModCtrl) || key.Mod.Contains(tea.ModShift) || key.Mod.Contains(tea.ModAlt) || key.Mod.Contains(tea.ModSuper) {
		return false
	}

	delta, ok := pickerNavigationDelta(key)
	if !ok {
		return false
	}

	payload, ok := m.chrome[generated.OPGuiPicker]
	if !ok || !payload.Picker.Visible || len(payload.Picker.Items) == 0 {
		return false
	}

	current := m.effectivePickerIndex(payload.Picker)

	next := current + delta
	if next < 0 {
		next = 0
	} else if next >= len(payload.Picker.Items) {
		next = len(payload.Picker.Items) - 1
	}
	if next == current {
		return false
	}

	m.localPresentation.setIdentityPreview(presentationPicker, payload.Picker.Generation, pickerItemID(payload.Picker.Items[next]))
	return true
}

func pickerNavigationDelta(key tea.Key) (int, bool) {
	switch key.Code {
	case 'j', tea.KeyDown:
		return 1, true
	case 'k', tea.KeyUp:
		return -1, true
	default:
		return 0, false
	}
}

// previewEmptyStateNavigation locally echoes launchpad focus movement (#2689):
// j/k/arrows move the highlighted row immediately so there is no perceptible
// latency, while the key still travels to the BEAM (which stays authoritative
// for activation and re-broadcasts focused_id in the next frame). It is scoped
// to focus movement only; it never activates a row. Returns true when it moved
// the local focus.
func (m *Model) previewEmptyStateNavigation(msg tea.KeyPressMsg) bool {
	key := msg.Key()
	if key.Mod.Contains(tea.ModShift) || key.Mod.Contains(tea.ModAlt) || key.Mod.Contains(tea.ModCtrl) || key.Mod.Contains(tea.ModSuper) {
		return false
	}

	delta, ok := emptyStateNavigationDelta(key)
	if !ok {
		return false
	}

	state, ok := m.emptyState()
	if !ok || !state.Visible {
		return false
	}

	items := focusableEmptyStateItems(state)
	if len(items) == 0 {
		return false
	}

	current := emptyStateFocusedIndex(items, state.FocusedID)
	if m.localPresentation.previewEmptyStateIndex != nil {
		current = *m.localPresentation.previewEmptyStateIndex
	}
	if current < 0 {
		current = 0
	}

	next := current + delta
	if next < 0 {
		next = 0
	} else if next >= len(items) {
		next = len(items) - 1
	}
	if next == current {
		return false
	}

	m.localPresentation.previewEmptyStateIndex = &next
	return true
}

func emptyStateNavigationDelta(key tea.Key) (int, bool) {
	switch key.Code {
	case 'j', tea.KeyDown:
		return 1, true
	case 'k', tea.KeyUp:
		return -1, true
	default:
		return 0, false
	}
}

func (m Model) effectivePickerIndex(picker protocol.Picker) int {
	if preview, ok := m.localPresentation.identityPreview(presentationPicker); ok && preview.generation == picker.Generation {
		if index := pickerItemIndexByID(picker, preview.itemID); index >= 0 {
			return index
		}
	}
	if index := pickerItemIndex(picker, picker.SelectedID); index >= 0 {
		return index
	}
	return min(max(int(picker.Selected), 0), max(len(picker.Items)-1, 0))
}

func completionItemIndex(completion protocol.Completion, itemID string) int {
	for index, item := range completion.Items {
		if item.ID == itemID {
			return index
		}
	}
	return -1
}

func pickerItemID(item protocol.PickerItem) string {
	return fmt.Sprintf("%d", item.ActivationID)
}

func pickerItemIndex(picker protocol.Picker, activationID uint32) int {
	for index, item := range picker.Items {
		if item.ActivationID == activationID {
			return index
		}
	}
	return -1
}

func pickerItemIndexByID(picker protocol.Picker, itemID string) int {
	for index, item := range picker.Items {
		if pickerItemID(item) == itemID {
			return index
		}
	}
	return -1
}

func (m Model) applyIndentGuide(window protocol.WindowContent, style lipgloss.Style, rowIndex int, col int, text string) (lipgloss.Style, string) {
	guides, ok := m.indentGuides[window.ID]
	if !ok || text != " " || !guideColumnVisible(guides, col) || !guideEnabledOnRow(guides, rowIndex, col) {
		return style, text
	}
	guideStyle := style.Foreground(m.palette().GutterText())
	if uint16(col) == guides.ActiveGuideCol {
		guideStyle = guideStyle.Foreground(m.palette().GutterCurrentText())
	}
	return guideStyle, "│"
}

func guideColumnVisible(guides protocol.IndentGuides, col int) bool {
	for _, guideCol := range guides.GuideCols {
		if int(guideCol) == col {
			return true
		}
	}
	return false
}

func guideEnabledOnRow(guides protocol.IndentGuides, rowIndex int, col int) bool {
	if len(guides.IndentLevels) == 0 || rowIndex < 0 || rowIndex >= len(guides.IndentLevels) || guides.TabWidth == 0 {
		return true
	}
	return col/int(guides.TabWidth) <= int(guides.IndentLevels[rowIndex])
}

func isWhitespace(value string) bool {
	return strings.TrimSpace(value) == ""
}
