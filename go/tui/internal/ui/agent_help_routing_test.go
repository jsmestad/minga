package ui

import (
	"bytes"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func agentHelpRoutingModel(t *testing.T, width, height int) (Model, chan []byte) {
	t.Helper()
	model, out := newAgentControlModel(t, true)
	updated, _ := model.Update(tea.WindowSizeMsg{Width: width, Height: height})
	model = updated.(Model)
	applyProductionFrame(&model, model.lastCommittedSeq+1, model.lastCommittedSeq, 1,
		agentHelpCommand(t, true, 64),
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
			Opcode: generated.OPGuiSurfaceLayout,
			Placements: []generated.SurfacePlacement{{
				SurfaceID: surfaceIDAgentHelp,
				Rect: generated.Rect{Row: uint16(model.layout.body.Y), Col: uint16(model.layout.body.X),
					Width: uint16(model.layout.body.Width), Height: uint16(model.layout.body.Height - 8)},
				Z: 300, HitKind: 8,
			}},
		}})
	_ = model.View()
	drainOutboundPackets(out)
	return model, out
}

func TestAgentHelpWheelOverDetailsRailScrollsHelpNotTheHiddenTranscript(t *testing.T) {
	t.Parallel()
	model, out := agentHelpRoutingModel(t, 140, 40)
	drainOutboundPackets(out)
	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnd}))
	model = updated.(Model)
	if !strings.Contains(agentControlCanvasText(model), "Binding 63") {
		t.Fatal("final Help page not visible before the wheel gesture")
	}
	drainOutboundPackets(out)
	x, y := model.layout.body.X+model.layout.body.Width-2, model.layout.body.Y+4
	for range 10 {
		updated, _ = model.Update(tea.MouseWheelMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseWheelUp}))
		model = updated.(Model)
	}
	text := agentControlCanvasText(model)
	if strings.Contains(text, "Binding 63") || !strings.Contains(text, "ordinary draft") {
		t.Fatalf("details-rail wheel did not navigate Help while preserving the draft:\n%s", text)
	}
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("Help wheel escaped as hidden transcript input: %x", packets)
	}
}

func TestCapturedTabDragReleaseReachesItsOwnerInsideHelp(t *testing.T) {
	t.Parallel()
	model, out := agentHelpRoutingModel(t, 80, 24)
	model = commitAgentControlTranscript(t, model, protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiTabBar,
		Tabs:   protocol.TabBar{Tabs: []protocol.Tab{{ID: 1, Label: "Agent", Active: true}, {ID: 2, Label: "Other"}}},
	}})
	_ = model.View()
	origin := waitForZone(t, model, zoneIDTab(1))
	target := waitForZone(t, model, zoneIDTab(2))
	updated, _ := model.Update(clickAt(origin))
	model = updated.(Model)
	if model.mouseDrag == nil {
		t.Fatal("tab press did not acquire drag ownership before entering Help")
	}
	drainOutboundPackets(out)
	x, y := model.layout.body.X+2, model.layout.body.Y+3
	updated, _ = model.Update(tea.MouseMotionMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft}))
	model = updated.(Model)
	updated, _ = model.Update(tea.MouseReleaseMsg(tea.Mouse{X: x, Y: y, Button: tea.MouseLeft}))
	model = updated.(Model)
	if model.mouseDrag != nil {
		t.Fatal("Help swallowed the captured tab drag's release")
	}
	updated, _ = model.Update(tea.MouseReleaseMsg(tea.Mouse{X: target.StartX + 1, Y: target.StartY, Button: tea.MouseRight}))
	model = updated.(Model)
	for _, packet := range drainOutboundPackets(out) {
		if bytes.Equal(packet, protocol.EncodeGUITabReorder(1, 1)) {
			t.Fatal("a later right release reordered the already-released tab")
		}
	}
}
