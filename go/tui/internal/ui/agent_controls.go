package ui

import (
	"encoding/hex"
	"fmt"
	"image/color"
	"net/url"
	"strconv"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

const (
	zoneIDAgentModel              = "agent:pick-model"
	zoneIDAgentQueue              = "agent:queue"
	zonePrefixAgentApproval       = "agent:approval:"
	zonePrefixAgentRetainedOutput = "agent:retained-output:"
	// The failed-start action zone retains the remedy it displayed, so a click
	// sends that remedy even if a later frame has changed the notice.
	zonePrefixAgentStartRemedy = "agent:start-remedy:"
)

func agentStartRemedyZoneID(kind protocol.AgentStartRemedyKind) string {
	return zonePrefixAgentStartRemedy + strconv.Itoa(int(kind))
}

func agentStartRemedyZonePacket(id string) []byte {
	kind, err := strconv.ParseUint(strings.TrimPrefix(id, zonePrefixAgentStartRemedy), 10, 8)
	if err != nil {
		return nil
	}
	return protocol.EncodeGUIAgentStartRemedy(protocol.AgentStartRemedyKind(kind))
}

// Approval zones retain their complete displayed target, including in cached
// transcript rows. Neither a resident index nor the current chat can retarget it.
func zoneIDAgentApproval(target protocol.AgentApprovalTarget, decision generated.AgentApprovalDecision) string {
	return fmt.Sprintf("%s%d:%s:%s:%s", zonePrefixAgentApproval, decision,
		url.QueryEscape(target.SessionID), url.QueryEscape(target.RequestID), url.QueryEscape(target.ToolCallID))
}

func agentApprovalZonePacket(id string) []byte {
	parts := strings.Split(strings.TrimPrefix(id, zonePrefixAgentApproval), ":")
	if !strings.HasPrefix(id, zonePrefixAgentApproval) || len(parts) != 4 {
		return nil
	}
	decision, err := strconv.ParseUint(parts[0], 10, 8)
	if err != nil {
		return nil
	}
	var ids [3]string
	for index := range ids {
		ids[index], err = url.QueryUnescape(parts[index+1])
		if err != nil {
			return nil
		}
	}
	return protocol.EncodeGUIAgentToolApproval(protocol.AgentApprovalTarget{
		SessionID: ids[0], RequestID: ids[1], ToolCallID: ids[2],
	}, generated.AgentApprovalDecision(decision))
}

func agentRetainedOutputZonePacket(id string) []byte {
	identity, ok := strings.CutPrefix(id, zonePrefixAgentRetainedOutput)
	if !ok {
		return nil
	}
	messageText, offerText, ok := strings.Cut(identity, ":")
	var offer [16]byte
	if !ok || len(offerText) != hex.EncodedLen(len(offer)) {
		return nil
	}
	messageID, messageErr := strconv.ParseUint(messageText, 10, 32)
	_, offerErr := hex.Decode(offer[:], []byte(offerText))
	if messageErr != nil || offerErr != nil {
		return nil
	}
	return protocol.EncodeGUIAgentReadRetainedOutput(uint32(messageID), offer)
}

func (m Model) agentDisplayedControlPacket(msg tea.MouseMsg) ([]byte, bool) {
	mouse := msg.Mouse()
	if !m.agentChatVisible() || !m.layout.body.Contains(mouse.X, mouse.Y) ||
		mouse.X < 0 || mouse.X >= m.width || mouse.Y < 0 || mouse.Y >= m.height ||
		m.editorTextOccluded(mouse.X, mouse.Y) {
		return nil, false
	}
	for _, control := range [...]struct{ zone, command string }{
		{zoneIDAgentModel, "agent_pick_model"},
		{zoneIDAgentHeaderHelp, "agent_toggle_help"},
		{zoneIDAgentHistory, "agent_retained_history"},
		{zoneIDAgentChecklist, "agent_checklist"},
		{zoneIDAgentQueue, "agent_queued_inputs"},
	} {
		if zone := m.zones.Get(control.zone); zone != nil && zone.InBounds(msg) {
			return protocol.EncodeGUIExecuteCommand(control.command), true
		}
	}
	// Only scanned (actually displayed) zones are eligible. Looking up a current
	// resident message here would silently change the subject of an old control.
	for id, zone := range m.zones.zones {
		if strings.HasPrefix(id, zonePrefixAgentApproval) && zone.InBounds(msg) {
			packet := agentApprovalZonePacket(id)
			return packet, packet != nil
		}
		if strings.HasPrefix(id, zonePrefixAgentRetainedOutput) && zone.InBounds(msg) {
			packet := agentRetainedOutputZonePacket(id)
			return packet, packet != nil
		}
		if strings.HasPrefix(id, zonePrefixAgentStartRemedy) && zone.InBounds(msg) {
			packet := agentStartRemedyZonePacket(id)
			return packet, packet != nil
		}
	}
	return nil, false
}

func (m Model) renderAgentApprovalActions(message protocol.AgentChatMessage, width int, background color.Color) [2]string {
	muted := lipgloss.NewStyle().Foreground(m.palette().Muted()).Background(background)
	if message.Status != 0 {
		return [2]string{muted.Render("Waiting for approval update"), ""}
	}
	if !message.ApprovalTarget.Valid() {
		return [2]string{muted.Render("Approval unavailable"), ""}
	}
	rows := [2][2]struct {
		label, compact string
		decision       generated.AgentApprovalDecision
	}{
		{{"[y] Approve", "[y] Yes", generated.AgentApprovalDecisionApprove}, {"[n] Reject", "[n] No", generated.AgentApprovalDecisionReject}},
		{{"[a] Approve session", "[a] Session", generated.AgentApprovalDecisionApproveSession}, {"[t] Approve turn", "[t] Turn", generated.AgentApprovalDecisionApproveTurn}},
	}
	var lines [2]string
	for rowIndex, row := range rows {
		compact := lipgloss.Width(row[0].label)+spaceXL.cols()+lipgloss.Width(row[1].label) > width
		used := 0
		for index, action := range row {
			if index != 0 {
				lines[rowIndex] += muted.Render(gap(spaceXL))
				used += spaceXL.cols()
			}
			label := action.label
			if compact {
				label = action.compact
			}
			if width < 20 {
				label = label[:3]
			}
			rendered := muted.Render(label)
			// Never leave an invisible or partially clipped action clickable.
			if used+lipgloss.Width(label) <= width {
				rendered = m.zones.markCachedTranscriptControl(zoneIDAgentApproval(message.ApprovalTarget, action.decision), rendered)
			}
			lines[rowIndex] += rendered
			used += lipgloss.Width(label)
		}
	}
	return lines
}
