package ui

import (
	"strings"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// overlayLines stacking order is data (#2268 AC-2): the precedence chain is
// deleted, so a placement z that inverts the old hand order must change which
// surface occupies the single active overlay slot.

func completionAndBottomPanelModel() Model {
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiCompletion: {
			Opcode:   generated.OPGuiCompletion,
			Complete: protocol.Completion{Visible: true, Items: []protocol.CompletionItem{{Label: "Enum.map"}}},
		},
		generated.OPGuiBottomPanel: {
			Opcode: generated.OPGuiBottomPanel,
			Bottom: protocol.BottomPanel{Visible: true, Tabs: []protocol.PanelTab{{Type: 0x01, Name: "Messages"}}, Messages: []protocol.PanelMessage{{ID: 1, Level: 1, Text: "panel-msg"}}},
		},
	}
	return model
}

func TestOverlayPrecedenceDefaultsToCompletionWhenNoPlacements(t *testing.T) {
	// With no gui_surface_layout emitted (older BEAM), the band-derived fallbacks
	// reproduce the old chain: completion (orderOverlayTop) outranks the bottom
	// panel (orderBottomPanelFallback).
	model := completionAndBottomPanelModel()
	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "Enum.map") {
		t.Fatalf("expected completion to win the overlay slot, got %q", got)
	}
	if strings.Contains(got, "panel-msg") {
		t.Fatalf("bottom panel should not win over completion by default, got %q", got)
	}
}

func TestOverlayPrecedenceFollowsPlacementZ(t *testing.T) {
	// The BEAM places the bottom panel ABOVE completion (higher z). Stacking
	// order is data, so the bottom panel now wins the single active overlay slot,
	// inverting the old hand-coded chain. This is the AC-2 proof that the
	// precedence is sorted placement data, not an if-ladder.
	model := completionAndBottomPanelModel()
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDCompletionMenu, Z: 10, HitKind: 8},
		{SurfaceID: surfaceIDBottomPanel, Z: 20, HitKind: 7},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "panel-msg") {
		t.Fatalf("expected bottom panel to win when placed above completion, got %q", got)
	}
	if strings.Contains(got, "Enum.map") {
		t.Fatalf("completion should not win when the bottom panel is placed above it, got %q", got)
	}
}

func TestOverlayPlacedSurfaceBeatsUnplacedSurface(t *testing.T) {
	// A registry-placed surface (completion, overlay band z=301) outranks an
	// unplaced transitional surface (agent context, order 260), preserving the old
	// chain where completion sat on top. Orders share one band scale now, so the
	// placement z must be in the overlay band to win, as the live registry emits.
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiCompletion:   {Opcode: generated.OPGuiCompletion, Complete: protocol.Completion{Visible: true, Items: []protocol.CompletionItem{{Label: "Enum.map"}}}},
		generated.OPGuiAgentContext: {Opcode: generated.OPGuiAgentContext, AgentContext: protocol.AgentContext{Visible: true, Task: "Review diff", Status: 1}},
	}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDCompletionMenu, Z: 301, HitKind: 8},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "Enum.map") || strings.Contains(got, "Review diff") {
		t.Fatalf("placed completion should beat unplaced agent context, got %q", got)
	}
}

func TestOverlayBottomPanelOpenHoverWins(t *testing.T) {
	// Regression for the stacking inversion (#2268 AC-2): the diagnostics/messages
	// bottom panel and an LSP hover popup are independently visible. The old chain
	// put hover ABOVE the bottom panel, and the band-aligned scale preserves that
	// (orderHover 290 > bottom panel floating band 200). Hover must win the single
	// active overlay slot, even with the bottom panel placed at its registry z.
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiBottomPanel: {
			Opcode: generated.OPGuiBottomPanel,
			Bottom: protocol.BottomPanel{Visible: true, Tabs: []protocol.PanelTab{{Type: 0x01, Name: "Messages"}}, Messages: []protocol.PanelMessage{{ID: 1, Level: 1, Text: "panel-msg"}}},
		},
		generated.OPGuiHoverPopup: {
			Opcode: generated.OPGuiHoverPopup,
			Hover:  protocol.HoverPopup{Visible: true, Lines: []protocol.RichLine{{Segments: []protocol.RichSegment{{Text: "hover-doc"}}}}},
		},
	}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDBottomPanel, Z: 200, HitKind: 7},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "hover-doc") {
		t.Fatalf("hover should win over the open bottom panel, got %q", got)
	}
	if strings.Contains(got, "panel-msg") {
		t.Fatalf("bottom panel must not win over hover, got %q", got)
	}
}

func TestOverlayHoverOrdersByEmittedPlacementZ(t *testing.T) {
	// Hover is registry-placed (#2281): its stacking order is the emitted
	// placement z, not the hardcoded fallback. Place the bottom panel ABOVE hover
	// (higher z than hover's emitted z), and the bottom panel must win the slot,
	// inverting the historical hover>panel order. This is the AC-2 proof that the
	// promoted hover popup orders by placement data.
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiBottomPanel: {
			Opcode: generated.OPGuiBottomPanel,
			Bottom: protocol.BottomPanel{Visible: true, Tabs: []protocol.PanelTab{{Type: 0x01, Name: "Messages"}}, Messages: []protocol.PanelMessage{{ID: 1, Level: 1, Text: "panel-msg"}}},
		},
		generated.OPGuiHoverPopup: {
			Opcode: generated.OPGuiHoverPopup,
			Hover:  protocol.HoverPopup{Visible: true, Lines: []protocol.RichLine{{Segments: []protocol.RichSegment{{Text: "hover-doc"}}}}},
		},
	}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDHoverPopup, Z: 290, HitKind: 8},
		{SurfaceID: surfaceIDBottomPanel, Z: 295, HitKind: 7},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "panel-msg") {
		t.Fatalf("bottom panel placed above hover should win the slot, got %q", got)
	}
	if strings.Contains(got, "hover-doc") {
		t.Fatalf("hover should lose when placed below the bottom panel, got %q", got)
	}
}

func TestOverlaySignatureHelpOrdersByEmittedPlacementZ(t *testing.T) {
	// Signature help is registry-placed (#2281). With its emitted z below the
	// bottom panel's, the panel wins the single active overlay slot, proving the
	// promoted signature-help surface orders by placement data rather than the
	// orderSignatureHelp fallback constant.
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiBottomPanel: {
			Opcode: generated.OPGuiBottomPanel,
			Bottom: protocol.BottomPanel{Visible: true, Tabs: []protocol.PanelTab{{Type: 0x01, Name: "Messages"}}, Messages: []protocol.PanelMessage{{ID: 1, Level: 1, Text: "panel-msg"}}},
		},
		generated.OPGuiSignatureHelp: {
			Opcode:    generated.OPGuiSignatureHelp,
			Signature: protocol.SignatureHelp{Visible: true, Signatures: []protocol.Signature{{Label: "map(enumerable, fun)"}}},
		},
	}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDSignatureHelp, Z: 180, HitKind: 8},
		{SurfaceID: surfaceIDBottomPanel, Z: 200, HitKind: 7},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "panel-msg") {
		t.Fatalf("bottom panel placed above signature help should win the slot, got %q", got)
	}
	if strings.Contains(got, "map(enumerable, fun)") {
		t.Fatalf("signature help should lose when placed below the bottom panel, got %q", got)
	}
}

func TestOverlayBottomPanelOpenSignatureHelpWins(t *testing.T) {
	// Same inversion guard for signature help: it historically sat above the
	// bottom panel (orderSignatureHelp 280 > floating band 200), so with the panel
	// open, triggering signature help must still show the signature popup.
	model := New(80, 16, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiBottomPanel: {
			Opcode: generated.OPGuiBottomPanel,
			Bottom: protocol.BottomPanel{Visible: true, Tabs: []protocol.PanelTab{{Type: 0x01, Name: "Messages"}}, Messages: []protocol.PanelMessage{{ID: 1, Level: 1, Text: "panel-msg"}}},
		},
		generated.OPGuiSignatureHelp: {
			Opcode:    generated.OPGuiSignatureHelp,
			Signature: protocol.SignatureHelp{Visible: true, Signatures: []protocol.Signature{{Label: "map(enumerable, fun)"}}},
		},
	}
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDBottomPanel, Z: 200, HitKind: 7},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "map(enumerable, fun)") {
		t.Fatalf("signature help should win over the open bottom panel, got %q", got)
	}
	if strings.Contains(got, "panel-msg") {
		t.Fatalf("bottom panel must not win over signature help, got %q", got)
	}
}
