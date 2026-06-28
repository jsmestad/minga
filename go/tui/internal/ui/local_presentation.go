package ui

import "github.com/jsmestad/minga/go/tui/internal/protocol"

type transformKind int

const (
	transformOffset transformKind = iota
	transformIdentity
)

type presentationScroll struct {
	anchorTop        uint32
	anchorLeft       uint16
	contentEpoch     uint32
	layoutGeneration uint32
	rowOffset        int
	colOffset        int
}

func (s presentationScroll) keysMatch(scroll protocol.ScrollPresentation) bool {
	return s.contentEpoch == scroll.ContentEpoch &&
		s.layoutGeneration == scroll.LayoutGeneration &&
		s.anchorTop == scroll.AnchorTop &&
		s.anchorLeft == scroll.AnchorLeft
}

type localPresentation struct {
	scrolls                map[uint16]presentationScroll
	previewFileTreeIndex   *int
	previewCompletionIndex *int
	previewPickerIndex     *int
}

func newLocalPresentation() localPresentation {
	return localPresentation{
		scrolls: make(map[uint16]presentationScroll),
	}
}

func (lp *localPresentation) reconcileScroll(window protocol.WindowContent) {
	if !window.ScrollSet || window.Scroll.ResetRequired {
		delete(lp.scrolls, window.ID)
		return
	}
	scroll, ok := lp.scrolls[window.ID]
	if !ok {
		return
	}
	if !scroll.keysMatch(window.Scroll) {
		delete(lp.scrolls, window.ID)
	}
}

func (lp *localPresentation) reconcileFileTree() {
	lp.previewFileTreeIndex = nil
}

func (lp *localPresentation) reconcileCompletion() {
	lp.previewCompletionIndex = nil
}

func (lp *localPresentation) reconcilePicker() {
	lp.previewPickerIndex = nil
}

func (lp *localPresentation) discard(kind transformKind, windowID uint16) {
	switch kind {
	case transformOffset:
		delete(lp.scrolls, windowID)
	case transformIdentity:
		lp.previewFileTreeIndex = nil
		lp.previewCompletionIndex = nil
		lp.previewPickerIndex = nil
	}
}

func (lp *localPresentation) removeWindow(windowID uint16) {
	delete(lp.scrolls, windowID)
}
