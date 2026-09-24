package ui

import "github.com/jsmestad/minga/go/tui/internal/protocol"

type transformKind int

const (
	transformOffset transformKind = iota
	transformIdentity
)

type presentationSurface byte

const (
	presentationCompletion presentationSurface = 1
	presentationPicker     presentationSurface = 2
	presentationFileTree   presentationSurface = 3
)

type presentationIdentity struct {
	generation uint32
	itemID     string
}

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
	scrolls          map[uint16]presentationScroll
	identityPreviews map[presentationSurface]presentationIdentity
	// previewEmptyStateIndex is the locally-echoed launchpad focus row (#2689):
	// an index into the ordered focusable items. It lets j/k/arrows move the
	// highlight with zero latency; the next gui_empty_state frame's focused_id
	// is authoritative and clears it via reconcileEmptyState.
	previewEmptyStateIndex *int
}

func newLocalPresentation() localPresentation {
	return localPresentation{
		scrolls:          make(map[uint16]presentationScroll),
		identityPreviews: make(map[presentationSurface]presentationIdentity),
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

func (lp *localPresentation) setIdentityPreview(surface presentationSurface, generation uint32, itemID string) {
	if generation == 0 || itemID == "" {
		delete(lp.identityPreviews, surface)
		return
	}
	lp.identityPreviews[surface] = presentationIdentity{generation: generation, itemID: itemID}
}

func (lp localPresentation) identityPreview(surface presentationSurface) (presentationIdentity, bool) {
	identity, ok := lp.identityPreviews[surface]
	return identity, ok
}

func (lp *localPresentation) reconcileIdentity(surface presentationSurface, generation uint32, committedItemID string, retainedItemIDs map[string]struct{}, visible bool) string {
	preview, ok := lp.identityPreviews[surface]
	if !visible || generation == 0 || !ok || preview.generation != generation || preview.itemID == committedItemID {
		delete(lp.identityPreviews, surface)
		return committedItemID
	}
	if _, retained := retainedItemIDs[preview.itemID]; !retained {
		delete(lp.identityPreviews, surface)
		return committedItemID
	}
	return preview.itemID
}

func (lp *localPresentation) discardIdentity(surface presentationSurface) {
	delete(lp.identityPreviews, surface)
}

// reconcileEmptyState drops the locally-echoed launchpad focus when a fresh
// gui_empty_state frame arrives: the frame's focused_id is authoritative
// (#2689), so the local echo must not outlive the reconciliation.
func (lp *localPresentation) reconcileEmptyState() {
	lp.previewEmptyStateIndex = nil
}

func (lp *localPresentation) discard(kind transformKind, windowID uint16) {
	switch kind {
	case transformOffset:
		delete(lp.scrolls, windowID)
	case transformIdentity:
		clear(lp.identityPreviews)
		lp.previewEmptyStateIndex = nil
	}
}

func (lp *localPresentation) removeWindow(windowID uint16) {
	delete(lp.scrolls, windowID)
}
