package ui

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// A footer band sits directly above the status row and command line, so the
// overlay stack must not paint a drop shadow over those rows (#3786).
func TestFooterBandOverlayLeavesRowsBelowItUnpainted(t *testing.T) {
	context := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode:       generated.OPGuiAgentContext,
		AgentContext: protocol.AgentContext{Visible: true, Task: "Agent activity", Progress: protocol.AgentProgress{ToolCount: 2, FileCount: 1}},
	}}
	placement := protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode: generated.OPGuiSurfaceLayout,
		Placements: []generated.SurfacePlacement{{
			SurfaceID: surfaceIDAgentContext, Rect: generated.Rect{Row: 15, Col: 0, Width: 80, Height: 7}, Z: 260, HitKind: 8,
		}},
	}}

	model := New(80, 24, nil)
	updated, _ := model.Update(port.PacketMsg{Commands: frame(context, placement)})
	model = updated.(Model)

	overlay := model.overlayLayer()
	if overlay == nil {
		t.Fatal("compact Agent context did not render over the editor")
	}
	layers := model.floatingOverlayLayers()
	if len(layers) != 1 {
		t.Fatalf("footer band painted %d layers; a shadow covers the rows below it", len(layers))
	}
	rect, ok := model.surfaceScreenRect(surfaceIDAgentContext)
	if !ok {
		t.Fatal("placed Agent context has no screen rect")
	}
	if bottom := layers[0].GetY() + layers[0].Height(); bottom > rect.Y+rect.Height {
		t.Fatalf("footer band paints row %d below its placement bottom %d", bottom, rect.Y+rect.Height)
	}
}
