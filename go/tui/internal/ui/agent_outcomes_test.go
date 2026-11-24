package ui

import (
	"fmt"
	"image/color"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestCommittedToolOutcomesOverrideCompatibilityError(t *testing.T) {
	model := New(120, 30, nil)
	p := model.palette()
	cases := []struct {
		status byte
		label  string
		icon   string
		color  color.Color
	}{
		{0, "running", model.agentSpinner(), p.Warning()},
		{1, "done", "✓", p.Diagnostic(3)},
		{2, "ERROR", "×", p.Diagnostic(0)},
		{3, "Denied", "⊘", p.Warning()},
		{4, "Cancelled", "■", p.Muted()},
		{5, "Expired", "◷", p.Warning()},
	}
	for _, tc := range cases {
		for _, kind := range []byte{agentKindTool, agentKindStyledTool} {
			for _, isError := range []bool{false, true} {
				for _, collapsed := range []bool{false, true} {
					t.Run(fmt.Sprintf("status%d/kind%d/error%t/collapsed%t", tc.status, kind, isError, collapsed), func(t *testing.T) {
						explanation := "Approval expired before execution"
						message := protocol.AgentChatMessage{Kind: kind, Status: tc.status, IsError: isError, Collapsed: collapsed,
							Name: "shell", Summary: "echo example", Result: explanation, DurationMS: 233900, PreviewLines: []string{"echo example"}}
						if kind == agentKindStyledTool {
							message.StyledLines = []protocol.AgentStyledLine{{{Text: explanation, FG: 0xFFFFFF}}}
						}
						icon, statusColor := model.agentToolStatus(message)
						message.Text = "shell echo example"
						wantError := tc.status == 2 || tc.status == 5
						if transcriptSummaryMembership(message)[0] != wantError || transcriptToolCounts(message)[2] != boolInt(wantError) {
							t.Fatal("compatibility boolean overrode the outcome in transcript summaries")
						}
						if icon != tc.icon || statusColor != tc.color {
							t.Fatalf("status icon/color = %q/%v, want %q/%v", icon, statusColor, tc.icon, tc.color)
						}
						rows := model.renderAgentToolMessage(message, 120)
						view := ansi.Strip(strings.Join(rows, "\n"))
						if !strings.Contains(view, tc.label) || (tc.status != 2 && strings.Contains(view, "ERROR")) {
							t.Fatalf("committed badge lost to compatibility boolean: %q", view)
						}
						if !strings.Contains(view, "echo example") {
							t.Fatalf("captured preview lost: %q", view)
						}
						if (!collapsed || tc.status == 2 || tc.status == 5) && !strings.Contains(view, explanation) {
							t.Fatalf("result explanation lost: %q", view)
						}
						if (tc.status == 3 || tc.status == 5) && strings.Contains(view, "233900ms") {
							t.Fatalf("approval wait shown as execution duration: %q", view)
						}
						height, layout := measureAgentMessage(message, 120)
						if height != len(rows) {
							t.Fatalf("row count = %d, rendered %d", height, len(rows))
						}
						ranged := model.renderAgentMessageRows(message, layout, 120, 0, len(rows))
						if strings.Join(ranged, "\n") != strings.Join(rows, "\n") {
							t.Fatal("resident ranged rendering differs from full tool renderer")
						}
					})
				}
			}
		}
	}
}

func TestApprovalWaitingStatusIsStaticAndStoppable(t *testing.T) {
	model := New(100, 30, nil)
	working := generated.StateWorking.Token().Word
	labels := []string{"Idle", working, working, generated.StateFailed.Token().Word, working, generated.StateNeedsYou.Token().Word}
	for status, label := range labels {
		if got := agentChatStatusLabel(byte(status)); got != label {
			t.Fatalf("status %d label = %q, want %q", status, got, label)
		}
		wantActive := status == 1 || status == 2 || status == 5
		if agentHasActiveTurn(byte(status)) != wantActive {
			t.Fatalf("status %d active-turn mismatch", status)
		}
	}
	chat := protocol.AgentChat{Visible: true, Status: 5, Prompt: "unfinished draft", StopTarget: composerTestStopTarget()}
	controls := agentTurnControls(chat, 80)
	if controls[0].enabled || !controls[3].enabled {
		t.Fatal("approval waiting must disable Send and allow Stop")
	}
	if agentComposerTitle(chat) != "Awaiting approval" {
		t.Fatal("approval waiting still claims execution")
	}
	chat.Pending = "shell"
	if agentComposerTitle(chat) != "Awaiting approval" {
		t.Fatal("pending approval replaced the authoritative waiting title")
	}
	// Even retained animated transcript entries must not animate approval waiting as execution.
	model.transcript = testTranscriptWithMessages([]protocol.AgentChatMessage{{ID: 1, Kind: agentKindTool, Status: 0}})
	if model.agentAnimating(chat) {
		t.Fatal("approval waiting animates executing work")
	}
	first := model.renderAgentStatusBadge(5)
	model.agent.animationFrame++
	if second := model.renderAgentStatusBadge(5); second != first || !strings.Contains(ansi.Strip(second), generated.StateNeedsYou.Token().Word) {
		t.Fatalf("approval badge is not static and truthful: %q", ansi.Strip(second))
	}
}

func TestStartingAgentKeepsDraftButDisablesSend(t *testing.T) {
	chat := protocol.AgentChat{Visible: true, Lifecycle: protocol.AgentChatStarting, Prompt: "typed while starting", PromptPresentation: 1}
	if agentTurnControls(chat, 80)[0].enabled {
		t.Fatal("Send must stay disabled while the Agent session starts")
	}
	chat.Lifecycle = protocol.AgentChatConversation
	if !agentTurnControls(chat, 80)[0].enabled {
		t.Fatal("Send must enable once the conversation is live")
	}
}
