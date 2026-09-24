package ui

import "github.com/jsmestad/minga/go/tui/internal/protocol"

type textPresentationRef struct {
	windowID       uint16
	presentationID uint64
}

func stagedTextPresentations(commands []protocol.Command) (map[uint16]uint64, []textPresentationRef) {
	next := make(map[uint16]uint64)
	unused := make([]textPresentationRef, 0)
	for _, command := range commands {
		if command.Kind != protocol.CommandTextPresentation {
			continue
		}
		presentation := command.TextPresentation
		if previous, ok := next[presentation.WindowID]; ok && previous != presentation.PresentationID {
			unused = append(unused, textPresentationRef{windowID: presentation.WindowID, presentationID: previous})
		}
		next[presentation.WindowID] = presentation.PresentationID
	}
	return next, unused
}

func (m *Model) queueCommittedTextPresentations(next map[uint16]uint64, unused []textPresentationRef) {
	previous := m.textPresentations
	if m.pendingTextPresentationCommit {
		previous = m.pendingTextPresentations
	}
	for windowID, presentationID := range previous {
		if next[windowID] != presentationID {
			m.queueTextPresentationDiscard(textPresentationRef{windowID: windowID, presentationID: presentationID})
		}
	}
	for _, presentation := range unused {
		m.queueTextPresentationDiscard(presentation)
	}
	m.pendingTextPresentations = next
	m.pendingTextPresentationCommit = true
}

func (m *Model) publishTextPresentationInputModel() {
	if m.pendingTextPresentationCommit {
		for windowID, presentationID := range m.pendingTextPresentations {
			if m.textPresentations[windowID] != presentationID {
				m.send(protocol.EncodeTextPresentationState(windowID, presentationID, protocol.TextPresentationActive))
			}
		}
		m.textPresentations = m.pendingTextPresentations
		m.pendingTextPresentations = nil
		m.pendingTextPresentationCommit = false
	}
	for presentation := range m.pendingTextPresentationDiscard {
		if m.textPresentations[presentation.windowID] != presentation.presentationID {
			m.send(protocol.EncodeTextPresentationState(presentation.windowID, presentation.presentationID, protocol.TextPresentationDiscarded))
		}
	}
	clear(m.pendingTextPresentationDiscard)
}

func (m *Model) discardStagedTextPresentations() {
	if m.staging == nil {
		return
	}
	next, unused := stagedTextPresentations(m.staging.commands)
	for windowID, presentationID := range next {
		m.queueTextPresentationDiscard(textPresentationRef{windowID: windowID, presentationID: presentationID})
	}
	for _, presentation := range unused {
		m.queueTextPresentationDiscard(presentation)
	}
}

func (m *Model) queueTextPresentationDiscard(presentation textPresentationRef) {
	if m.pendingTextPresentationDiscard == nil {
		m.pendingTextPresentationDiscard = map[textPresentationRef]struct{}{}
	}
	m.pendingTextPresentationDiscard[presentation] = struct{}{}
}
