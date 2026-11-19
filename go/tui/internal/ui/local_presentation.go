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
	wrapped          bool
	wrappedResident  bool
	anchorOffset     uint16
	anchorRank       int
	// A zero offset is not an acknowledgement: a reversal can return to the
	// original rank while earlier wheel frames are still in flight.
	predictingWrapped bool
	// scrollSeq is the last reconciled scroll-authority sequence, distinct from
	// the horizontal input acknowledgement.
	scrollSeq     uint32
	rowOffset     int
	colOffset     int
	committedLeft uint16
	pendingPanSeq uint32
}

func (s presentationScroll) keysMatch(scroll protocol.ScrollPresentation) bool {
	return s.basisMatches(scroll) &&
		s.anchorTop == scroll.AnchorTop &&
		s.anchorLeft == scroll.AnchorLeft &&
		(!s.wrapped || s.anchorOffset == scroll.AnchorVisualRowOffset)
}

func (s presentationScroll) basisMatches(scroll protocol.ScrollPresentation) bool {
	return s.contentEpoch == scroll.ContentEpoch &&
		s.layoutGeneration == scroll.LayoutGeneration &&
		s.wrapped == scroll.Wrapped
}

func capturePresentationScroll(window protocol.WindowContent, anchorRank int) presentationScroll {
	scroll := window.Scroll
	return presentationScroll{
		anchorTop: scroll.AnchorTop, anchorLeft: scroll.AnchorLeft,
		contentEpoch: scroll.ContentEpoch, layoutGeneration: scroll.LayoutGeneration,
		scrollSeq: scroll.ScrollSeq, wrapped: scroll.Wrapped,
		wrappedResident: window.WrappedResidentRows, anchorOffset: scroll.AnchorVisualRowOffset,
		anchorRank: anchorRank, committedLeft: window.ScrollLeft,
	}
}

type localPresentation struct {
	scrolls map[uint16]presentationScroll
	// One client sequence across panes avoids reusing an outstanding sequence
	// when a pane's presentation is reset, removed, or replaced.
	horizontalPanSeq uint32

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

// Reconcile authority and layout before rebasing a same-basis echo. Wrapped
// resident rows rebase their visual rank; unwrapped panes rebase their left.
func (lp *localPresentation) reconcileScroll(window protocol.WindowContent, anchorRank int) {
	if window.ScrollSet && window.Scroll.HorizontalPanAck > lp.horizontalPanSeq {
		lp.horizontalPanSeq = window.Scroll.HorizontalPanAck
	}
	if !window.ScrollSet || window.Scroll.ResetRequired {
		delete(lp.scrolls, window.ID)
		return
	}
	scroll, ok := lp.scrolls[window.ID]
	if !ok {
		return
	}
	next := window.Scroll
	// A regressed lineage is not a same-authority echo if the anchor moved.
	if !scroll.basisMatches(next) || scroll.wrappedResident != window.WrappedResidentRows ||
		next.ScrollSeq > scroll.scrollSeq ||
		(next.ScrollSeq < scroll.scrollSeq && !scroll.keysMatch(next)) {
		delete(lp.scrolls, window.ID)
		return
	}
	scroll.scrollSeq = next.ScrollSeq
	if scroll.predictingWrapped {
		// Preserve the predicted absolute rank across same-authority echoes.
		// Applying an old relative offset to the new continuation would scroll
		// twice, and clearing on equal anchors would lose delayed reversals.
		scroll.rowOffset += scroll.anchorRank - anchorRank
		scroll.anchorRank = anchorRank
		scroll.anchorTop = window.Scroll.AnchorTop
		scroll.anchorOffset = window.Scroll.AnchorVisualRowOffset
		scroll.anchorLeft = window.Scroll.AnchorLeft
		lp.scrolls[window.ID] = scroll
		return
	}
	if scroll.anchorTop != window.Scroll.AnchorTop {
		scroll.anchorTop = window.Scroll.AnchorTop
		scroll.anchorOffset = window.Scroll.AnchorVisualRowOffset
		scroll.rowOffset = 0
	}
	if !next.CanPanHorizontally || scroll.pendingPanSeq <= next.HorizontalPanAck {
		scroll.colOffset = 0
		scroll.pendingPanSeq = 0
	} else {
		// Only the last sent sequence retires the prediction. Earlier echoes
		// rebase its absolute left edge, even if one reaches the final column.
		scroll.colOffset += int(scroll.committedLeft) - int(window.ScrollLeft)
	}
	scroll.committedLeft = window.ScrollLeft
	scroll.anchorLeft = window.Scroll.AnchorLeft
	lp.storeUnwrappedScroll(window.ID, scroll)
}

func (lp *localPresentation) storeUnwrappedScroll(windowID uint16, scroll presentationScroll) {
	if scroll.rowOffset == 0 && scroll.pendingPanSeq == 0 {
		delete(lp.scrolls, windowID)
	} else {
		lp.scrolls[windowID] = scroll
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
