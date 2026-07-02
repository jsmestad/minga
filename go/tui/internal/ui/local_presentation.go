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
	// scrollSeq is the scroll-authority sequence the committed frame carried when
	// this local offset was captured (#2671). The reconciler discards the offset
	// when a later frame reports a strictly-newer scroll_seq: an authoritative
	// BEAM jump that raced the local scroll, even one that coincidentally landed
	// on the same anchor key. It mirrors prev.scrollSeq of Swift's
	// GUIScrollPresentation, compared inside shouldResetScrollPresentation.
	scrollSeq uint32
	rowOffset int
	colOffset int
}

func (s presentationScroll) keysMatch(scroll protocol.ScrollPresentation) bool {
	return s.contentEpoch == scroll.ContentEpoch &&
		s.layoutGeneration == scroll.LayoutGeneration &&
		s.anchorTop == scroll.AnchorTop &&
		s.anchorLeft == scroll.AnchorLeft
}

type localPresentation struct {
	scrolls                map[uint16]presentationScroll
	scrollPrefetchSent     map[uint16]uint32
	previewFileTreeIndex   *int
	previewCompletionIndex *int
	previewPickerIndex     *int
}

func newLocalPresentation() localPresentation {
	return localPresentation{
		scrolls:            make(map[uint16]presentationScroll),
		scrollPrefetchSent: make(map[uint16]uint32),
	}
}

// reconcileScroll decides whether an incoming committed frame discards the local
// scroll offset. It follows the documented reconciliation rule (docs/GUI_PROTOCOL.md)
// in the same order Swift's shouldResetScrollPresentation uses:
//
//  1. reset_required (or no scroll payload) always discards;
//  2. a strictly-newer scroll_seq discards, checked AHEAD of the anchor-key
//     check so an authoritative jump that landed on the same top is not mistaken
//     for a routine echo (#2671);
//  3. an anchor-key mismatch (content_epoch / layout_generation / anchor)
//     discards.
//
// Everything else (echo commits: same scroll_seq, same anchor key) keeps the
// offset, so a wheel report the BEAM committed as the same anchor does not
// trigger a re-anchor storm.
func (lp *localPresentation) reconcileScroll(window protocol.WindowContent) {
	if !window.ScrollSet || window.Scroll.ResetRequired {
		delete(lp.scrolls, window.ID)
		delete(lp.scrollPrefetchSent, window.ID)
		return
	}
	scroll, ok := lp.scrolls[window.ID]
	if !ok {
		return
	}
	if window.Scroll.ScrollSeq > scroll.scrollSeq {
		delete(lp.scrolls, window.ID)
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
	delete(lp.scrollPrefetchSent, windowID)
}
