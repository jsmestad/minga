package ui

import (
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestFilteredWheelBurstCompletesWithoutAnotherInput(t *testing.T) {
	for _, test := range []struct {
		name    string
		buttons []tea.MouseButton
		mod     tea.KeyMod
		rows    int
	}{
		{name: "four upward steps", buttons: []tea.MouseButton{tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp}, rows: -4},
		{name: "direction changes retain every step", buttons: []tea.MouseButton{tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelDown, tea.MouseWheelDown}, rows: -4},
		{name: "modified wheel keeps its scroll distance", buttons: []tea.MouseButton{tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp, tea.MouseWheelUp}, mod: tea.ModCtrl | tea.ModAlt, rows: -4},
		{name: "horizontal wheel does not become vertical movement", buttons: []tea.MouseButton{tea.MouseWheelRight, tea.MouseWheelRight, tea.MouseWheelRight, tea.MouseWheelRight}, rows: 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			newModel := func() Model {
				model := residentModel(t, 100)
				payload := model.chrome[generated.OPGuiAgentChat]
				payload.AgentChat.Prompt = "unfinished draft"
				payload.AgentChat.InputFocused = true
				model.chrome[generated.OPGuiAgentChat] = payload
				model.transcript.scrollBy(-8)
				model.viewport.SetContent(model.composeBody())
				return model
			}
			want := newModel()
			want.transcript.scrollBy(test.rows)
			want.viewport.SetContent(want.composeBody())
			wantView := want.View().Content
			model := newModel()
			at := time.Date(2026, 11, 16, 0, 0, 0, 0, time.UTC)
			filter := &InputFilter{now: func() time.Time { return at }}
			for _, button := range test.buttons {
				message := tea.MouseWheelMsg(tea.Mouse{X: model.layout.body.X + 1, Y: model.layout.body.Y + 1, Button: button, Mod: test.mod})
				filtered := filter.Filter(model, message)
				if filtered == nil {
					continue
				}
				updated, _ := model.Update(filtered)
				model = updated.(Model)
			}
			if got := model.View().Content; got != wantView {
				t.Fatalf("finite wheel burst did not render its complete %d-row distance without more input\ngot:\n%s\nwant:\n%s", test.rows, got, wantView)
			}
			chat, ok := model.agentChat()
			if !ok || chat.Prompt != "unfinished draft" || !chat.InputFocused {
				t.Fatalf("wheel burst changed retained draft or composer ownership: %+v", chat)
			}
		})
	}
}
