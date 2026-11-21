package ui

import (
	"bytes"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// The near-limit plan segment is a generic modeline chip: the BEAM decides the
// threshold, text, and color, and the terminal renders it as committed. A click
// opens the model picker, the terminal's "Choose another model" action.
func TestPlanLimitSegmentRendersCommittedTextAndOpensModelPicker(t *testing.T) {
	for _, tc := range []struct {
		name  string
		width uint16
		text  string
	}{
		{"near limit at normal width", 80, " Claude 82% · 5h "},
		{"near limit at narrow width", 60, " Claude 82% · 5h "},
		{"limit reached", 80, " Claude limit · resets 3:40 PM "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model := New(tc.width, 12, nil)
			model.chrome = map[byte]protocol.ChromePayload{
				generated.OPGuiStatusBar: {Status: protocol.StatusBar{
					Left: []protocol.StatusSegment{
						{Name: "mode", Text: " NORMAL ", Attrs: 0x01},
						{Name: "filename", Text: " main.ex ", Command: "buffer_list"},
						{Name: "plan_limit", Text: tc.text, FG: 0xECBE7B, Command: "agent_pick_model"},
					},
					Right: []protocol.StatusSegment{{Name: "position", Text: " 1:1 "}},
				}},
			}
			model.layout = model.computeLayout()
			model.viewport.SetHeight(model.layout.body.Height)
			model.viewport.SetContent(model.content())
			view := model.View()

			if !strings.Contains(ansi.Strip(view.Content), strings.TrimSpace(tc.text)) {
				t.Fatalf("status line should show %q at width %d:\n%s", strings.TrimSpace(tc.text), tc.width, ansi.Strip(view.Content))
			}

			zone := waitForZone(t, model, zoneIDModelineCommand("agent_pick_model"))
			packet, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
			if !ok || !bytes.Equal(packet, protocol.EncodeGUIExecuteCommand("agent_pick_model")) {
				t.Fatalf("clicking the plan segment should open the model picker, ok=%v packet=%v", ok, packet)
			}
		})
	}
}
