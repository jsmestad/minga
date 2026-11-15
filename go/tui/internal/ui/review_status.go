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
	controlWidth := len(labels[0]) + len(labels[1]) + len(labels[2]) + 2*len(separator)
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
	content := controls
	if state != "" {
		content = style.Render(state) + " " + controls
	}
	// Optional metadata comes strictly after the status and all three controls.
	remaining := m.width - lipgloss.Width(content) - 2
	if remaining > 0 {
		content += style.Render("  " + fit(review.Path, remaining))
	}
	return content
}

func (m Model) reviewStatusMousePacket(msg tea.MouseMsg) ([]byte, bool) {
	status, ok := m.statusBar()
	if !ok || status.Review == nil {
		return nil, false
	}
	review := *status.Review
	for _, intent := range []byte{1, 2} {
		if zone := m.zones.Get(zoneIDReviewControl(review, intent)); zone != nil && zone.InBounds(msg) {
			if review.Generation == 0 || review.ItemID == "" || (intent == 2 && review.Freshness != protocol.ReviewStale) {
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
