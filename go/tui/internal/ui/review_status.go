package ui

import (
	"fmt"
	"net/url"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const zoneIDReviewHelp = "review:help"

// Embed the entire immutable offer in the zone identity.
// A retained hit region cannot be retargeted by a newer status, selection, or same-basename path.
func zoneIDReviewControl(review protocol.StatusReview, intent byte) string {
	return fmt.Sprintf("review:control:%d:%d:%s", intent, review.Generation, url.QueryEscape(review.ItemID))
}

func (m Model) renderReviewStatus(review protocol.StatusReview) string {
	labels := [3]string{"[Back to chat]", "[Review latest]", "[Help]"}
	state := "Read-only current"
	if review.Freshness == protocol.ReviewStale {
		state = "Read-only stale  "
	}
	separator := " "
	switch {
	case m.width < 16:
		labels = [3]string{"<", "R", "?"}
		separator = ""
		state = "RO current"
		if review.Freshness == protocol.ReviewStale {
			state = "RO stale  "
		}
	case m.width < 23:
		labels = [3]string{"<", "R", "?"}
		state = "RO current"
		if review.Freshness == protocol.ReviewStale {
			state = "RO stale  "
		}
	case m.width < 42:
		labels = [3]string{"<", "R", "?"}
	case m.width < 57:
		labels = [3]string{"[Back]", "[Refresh]", "[Help]"}
	}
	mine, agent := "", ""
	if review.ConflictIndex != 0 {
		state = fmt.Sprintf("Conflict %d", review.ConflictIndex)
		if review.Freshness == protocol.ReviewStale {
			state = fmt.Sprintf("Stale #%d  ", review.ConflictIndex)
		}
		if m.width < 94 {
			labels = [3]string{"[Back]", "[Refresh]", "[Help]"}
		}
		if m.width < 57 {
			labels = [3]string{"<", "R", "?"}
		}
		mine, agent = "[Keep mine (x)]", "[Use Agent version (y)]"
		if m.width < 80 {
			mine, agent = "[Mine x]", "[Agent y]"
		}
		if m.width < 40 {
			mine, agent = "[x]", "[y]"
		}
		if m.width < 25 {
			state = fmt.Sprintf("C%d", review.ConflictIndex)
			if review.Freshness == protocol.ReviewStale {
				state = fmt.Sprintf("S%d", review.ConflictIndex)
			}
		}
	}
	controlWidth := len(labels[0]) + len(labels[1]) + len(labels[2]) + 2*len(separator)
	if review.ConflictIndex != 0 {
		controlWidth += len(mine) + len(agent) + 2*len(separator)
	}
	state = fit(state, min(len(state), max(m.width-controlWidth-1, 0)))
	style := lipgloss.NewStyle().Foreground(m.palette().ChromeText()).Background(m.palette().ChromeSurface())
	back := m.zones.Mark(zoneIDReviewControl(review, 1), style.Render(labels[0]))
	refreshStyle := style
	if review.Freshness != protocol.ReviewStale {
		refreshStyle = refreshStyle.Faint(true)
	}
	refresh := m.zones.Mark(zoneIDReviewControl(review, 2), refreshStyle.Render(labels[1]))
	help := m.zones.Mark(zoneIDReviewHelp, style.Render(labels[2]))
	controls := back + separator + refresh + separator + help
	if review.ConflictIndex != 0 {
		choiceStyle := style
		if review.Freshness != protocol.ReviewCurrent {
			choiceStyle = choiceStyle.Faint(true)
		}
		keep := m.zones.Mark(zoneIDReviewControl(review, 3), choiceStyle.Render(mine))
		use := m.zones.Mark(zoneIDReviewControl(review, 4), choiceStyle.Render(agent))
		controls = keep + separator + use + separator + controls
	}
	content := controls
	if state != "" {
		content = style.Render(state) + " " + controls
	}
	// Optional path comes strictly after the state and all controls.
	remaining := m.width - lipgloss.Width(content) - 2
	if remaining > 0 {
		content += style.Render("  " + fit(review.Path, remaining))
	}
	return content
}

// Conflict decisions use the button cells and target of the View the terminal flushed.
func (m Model) presentedConflictHandler() func(tea.MouseMsg) tea.Cmd {
	status, ok := m.statusBar()
	if !ok || status.Review == nil || status.Review.ConflictIndex == 0 {
		return nil
	}
	review := *status.Review
	var hits [2]zoneInfo
	for i := range hits {
		if hit := m.zones.Get(zoneIDReviewControl(review, byte(3+i))); hit != nil {
			hits[i] = *hit
		} else {
			hits[i].StartX = m.width
		}
	}
	claim := m.presentedClick
	return func(msg tea.MouseMsg) tea.Cmd {
		if click, ok := msg.(tea.MouseClickMsg); ok && click.Button == tea.MouseLeft {
			for i, hit := range hits {
				if hit.StartX <= hit.EndX && hit.InBounds(click) {
					claim.claimed = true
					intent := byte(3 + i)
					if reviewStatusIntentEnabled(review, intent) {
						claim.packet = protocol.EncodeGUISemanticItemActivate(6, intent, review.Generation, []byte(review.ItemID))
					}
					break
				}
			}
		}
		return nil
	}
}

func (m Model) reviewStatusMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	status, ok := m.statusBar()
	if !ok || status.Review == nil {
		return nil, false
	}
	review := *status.Review
	for _, intent := range [...]byte{1, 2, 3, 4} {
		if zone := m.zones.Get(zoneIDReviewControl(review, intent)); zone != nil && zone.InBounds(msg) {
			if intent >= 3 {
				return nil, true // Decisions can only be dispatched by the published View.
			}
			if !reviewStatusIntentEnabled(review, intent) {
				return nil, true
			}
			return protocol.EncodeGUISemanticItemActivate(6, intent, review.Generation, []byte(review.ItemID)), true
		}
	}
	if zone := m.zones.Get(zoneIDReviewHelp); zone != nil && zone.InBounds(msg) {
		return protocol.EncodeGUIExecuteCommand("agent_toggle_help"), true
	}
	return nil, false
}

func reviewStatusIntentEnabled(review protocol.StatusReview, intent byte) bool {
	if review.Generation == 0 || review.ItemID == "" {
		return false
	}
	switch intent {
	case 1:
		return true
	case 2:
		return review.Freshness == protocol.ReviewStale
	case 3, 4:
		return review.ConflictIndex != 0 && review.Freshness == protocol.ReviewCurrent
	default:
		return false
	}
}
