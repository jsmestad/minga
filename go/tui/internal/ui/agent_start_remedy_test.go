package ui

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func newFailedStartModel(t *testing.T, remedy protocol.AgentStartRemedy, reason string) (Model, chan []byte) {
	t.Helper()
	out := make(chan []byte, 128)
	model := New(80, 24, out)
	chat := protocol.AgentChat{
		Visible: true, Status: agentStatusNeedsYou, Lifecycle: protocol.AgentChatFailed,
		LifecycleReason: reason, LifecycleRemedy: remedy, ModelName: "Not started",
		Prompt: "kept draft", PromptVisibleRows: 1,
	}
	model = commitPrompt(t, model, chat, decodedPromptCommand(t, promptRows(chat.Prompt), 0, 4, 0, 0, protocol.Selection{}), 900)
	drainOutboundPackets(out)
	return model, out
}

func TestFailedStartShowsTheBEAMRemedyAndSendsItOnClick(t *testing.T) {
	for _, fixture := range []struct {
		remedy   protocol.AgentStartRemedy
		headline string
	}{
		{protocol.AgentStartRemedy{Kind: protocol.AgentStartRemedyRetry, Label: "Retry", KeyHint: "r"}, "Agent could not start"},
		{protocol.AgentStartRemedy{Kind: protocol.AgentStartRemedySetUpProvider, Label: "Set up provider", KeyHint: "s"}, "Agent needs setup"},
	} {
		for _, size := range [][2]int{{120, 30}, {80, 24}, {44, 24}} {
			t.Run(fmt.Sprintf("%s/%dx%d", fixture.remedy.Label, size[0], size[1]), func(t *testing.T) {
				model, out := newFailedStartModel(t, fixture.remedy, "The Agent took too long to start.")
				updated, _ := model.Update(tea.WindowSizeMsg{Width: size[0], Height: size[1]})
				model = updated.(Model)

				text := agentControlCanvasText(model)
				for _, want := range []string{fixture.headline, "The Agent took", fixture.remedy.Label, fixture.remedy.KeyHint, "Your draft is saved."} {
					if !strings.Contains(text, want) {
						t.Fatalf("failed-start notice is missing %q:\n%s", want, text)
					}
				}
				if strings.Contains(text, "Error") || strings.Contains(text, "Resolving model") {
					t.Fatalf("failed start still reads as an error:\n%s", text)
				}
				if strings.Contains(text, "Enter send") {
					t.Fatalf("composer hint says Enter sends while Enter runs the remedy:\n%s", text)
				}
				if size[0] == 120 && !strings.Contains(text, "Enter "+strings.ToLower(fixture.remedy.Label)) {
					t.Fatalf("composer hint does not name the remedy Enter runs:\n%s", text)
				}

				_ = model.View()
				zone := waitForZone(t, model, agentStartRemedyZoneID(fixture.remedy.Kind))
				drainOutboundPackets(out)
				model = driveAgentControlSGR(t, model, zone.StartX, zone.StartY, 'M', false)
				want := protocol.EncodeGUIAgentStartRemedy(fixture.remedy.Kind)
				if packets := drainOutboundPackets(out); len(packets) != 1 || !bytes.Equal(packets[0], want) {
					t.Fatalf("clicking %s sent %x, want only %x", fixture.remedy.Label, packets, want)
				}
				if chat, _ := model.agentChat(); chat.Prompt != "kept draft" {
					t.Fatalf("clicking the remedy changed the draft: %+v", chat)
				}
			})
		}
	}
}

func TestNeedsYouStatusIsAmberStaticAndNotAnActiveTurn(t *testing.T) {
	model := New(80, 24, make(chan []byte, 1))
	if agentHasActiveTurn(agentStatusNeedsYou) {
		t.Fatal("a failed start must not offer Stop")
	}
	badge := model.renderAgentStatusBadge(agentStatusNeedsYou)
	if !strings.Contains(ansi.Strip(badge), "Needs you") {
		t.Fatalf("needs-you badge reads %q", ansi.Strip(badge))
	}
	if agentComposerTitle(protocol.AgentChat{Status: agentStatusNeedsYou}) == "Error" {
		t.Fatal("a failed start titles the composer Error")
	}
}
