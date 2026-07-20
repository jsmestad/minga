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
	model := New(80, 16, nil, nil)
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

func TestOverlayRendersNothingWithoutPlacements(t *testing.T) {
	// The transitional fallback table is deleted (#2281): with no gui_surface_layout
	// emitted, NO overlay is eligible (placed == false for all), so the single
	// active overlay slot is empty. A surface the BEAM did not place simply does
	// not render that frame, rather than footer-appending at a guessed rank.
	model := completionAndBottomPanelModel()
	got := strings.Join(model.overlayLines(), "\n")
	if got != "" {
		t.Fatalf("no overlay should render without placements, got %q", got)
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
	model := New(80, 16, nil, nil)
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
	model := New(80, 16, nil, nil)
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
		{SurfaceID: surfaceIDHoverPopup, Z: 290, HitKind: 8},
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
	model := New(80, 16, nil, nil)
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
	model := New(80, 16, nil, nil)
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
	model := New(80, 16, nil, nil)
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
		{SurfaceID: surfaceIDSignatureHelp, Z: 280, HitKind: 8},
	}

	got := strings.Join(model.overlayLines(), "\n")
	if !strings.Contains(got, "map(enumerable, fun)") {
		t.Fatalf("signature help should win over the open bottom panel, got %q", got)
	}
	if strings.Contains(got, "panel-msg") {
		t.Fatalf("bottom panel must not win over signature help, got %q", got)
	}
}

// Per-surface placement: each promoted footer-band overlay (#2281) renders only
// when the BEAM emits its placement, and the overlayLayer positions it at the
// placement rect (X=Col, Y=Row). One sub-test per surface proves the surface id
// wiring and the position-by-rect path.

func TestPromotedFooterOverlaysRenderAtPlacementRect(t *testing.T) {
	cases := []struct {
		name      string
		surfaceID uint16
		z         uint16
		chrome    map[byte]protocol.ChromePayload
		needle    string
	}{
		{
			name:      "float popup",
			surfaceID: surfaceIDFloatPopup,
			z:         270,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiFloatPopup: {Float: protocol.FloatPopup{Visible: true, Title: "Inspect", Lines: []string{"pid <0.1.0>"}}}},
			needle:    "Inspect",
		},
		{
			name:      "agent context",
			surfaceID: surfaceIDAgentContext,
			z:         260,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiAgentContext: {AgentContext: protocol.AgentContext{Visible: true, Task: "Review diff", Status: 1}}},
			needle:    "Review diff",
		},
		{
			name:      "extension panel",
			surfaceID: surfaceIDExtensionPanel,
			z:         190,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiExtensionPanel: {Extensions: protocol.ExtensionPanel{Panels: []protocol.ExtensionPanelEntry{{Visible: true, Title: "Linter"}}}}},
			needle:    "Linter",
		},
		{
			name:      "observatory",
			surfaceID: surfaceIDObservatory,
			z:         180,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiObservatory: {Observatory: protocol.Observatory{Visible: true, Count: 1, Nodes: []protocol.ObservatoryNode{{PID: "<0.1.0>", Name: "Editor", MessageQueueLen: 0}}}}},
			needle:    "Editor",
		},
		{
			name:      "edit timeline",
			surfaceID: surfaceIDEditTimeline,
			z:         170,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiEditTimeline: {Timeline: protocol.EditTimeline{Visible: true, Entries: []protocol.TimelineEntry{{Index: 0, ToolName: "format", TimestampDelta: 0}}}}},
			needle:    "format",
		},
		{
			name:      "notifications",
			surfaceID: surfaceIDNotifications,
			z:         160,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiNotifications: {Notifications: protocol.Notifications{Visible: true, Items: []protocol.Notification{{Title: "Build done", Source: "build"}}}}},
			needle:    "Build done",
		},
		{
			name:      "extension overlay",
			surfaceID: surfaceIDExtensionOverlay,
			z:         150,
			chrome:    map[byte]protocol.ChromePayload{generated.OPGuiExtensionOverlay: {Overlay: protocol.ExtensionOverlay{Entries: []protocol.ExtensionOverlayEntry{{Extension: "lens", Row: 0, Col: 0, Content: "ref count 3"}}}}},
			needle:    "ref count",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			model := New(80, 24, nil, nil)
			model.chrome = tc.chrome

			// Without a placement the surface does not render (no fallback table).
			if got := strings.Join(model.overlayLines(), "\n"); got != "" {
				t.Fatalf("%s should not render without a placement, got %q", tc.name, got)
			}

			// With its placement, the surface wins the slot and renders.
			model.surfacePlacements = []generated.SurfacePlacement{
				{SurfaceID: tc.surfaceID, Rect: generated.Rect{Row: 16, Col: 0, Width: 80, Height: 8}, Z: tc.z, HitKind: 8},
			}
			if got := strings.Join(model.overlayLines(), "\n"); !strings.Contains(got, tc.needle) {
				t.Fatalf("%s should render with its placement, got %q", tc.name, got)
			}

			// The overlay layer is bottom-aligned inside the placement band (#2281):
			// its bottom edge sits at the rect's bottom edge (Row+Height) so a short
			// overlay hugs the screen bottom instead of rendering at the band top.
			layer := model.overlayLayer()
			if layer == nil {
				t.Fatalf("%s should produce an overlay layer when placed", tc.name)
			}
			rectBottom := 16 + 8
			layerBottom := layer.GetY() + layer.Height()
			if layerBottom != rectBottom {
				t.Fatalf("%s layer bottom edge %d != rect bottom %d (content must hug the band bottom)", tc.name, layerBottom, rectBottom)
			}
			if layer.GetY() < 16 {
				t.Fatalf("%s layer top %d escaped above the band top 16", tc.name, layer.GetY())
			}
		})
	}
}

// TestShortNotificationsHugBandBottom is the position-pinning regression for the
// short-overlay bug (#2281): before the fix every surface used a :max ceiling
// rect and Go composited content at the band TOP, so a 2-line notification
// rendered ~10 rows above the screen bottom and the rows below it phantom-
// swallowed clicks. With the fix the BEAM sizes the notifications rect to its
// content and Go bottom-aligns, so the overlay's bottom edge is the rect's bottom
// edge (directly above the minibuffer) and the layer is exactly its content tall.
func TestShortNotificationsHugBandBottom(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiNotifications: {Notifications: protocol.Notifications{
			Visible: true,
			Items:   []protocol.Notification{{Title: "Build done", Source: "build", Body: "ok"}},
		}},
	}
	// BEAM content-height for 1 notification item: title bar + 2 lines = 3, so the
	// bottom-anchored band is the lowest 3 rows of the screen (rows 21..23).
	const bandRow, bandHeight = 21, 3
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDNotifications, Rect: generated.Rect{Row: bandRow, Col: 0, Width: 80, Height: bandHeight}, Z: 160, HitKind: 8},
	}

	layer := model.overlayLayer()
	if layer == nil {
		t.Fatalf("notifications overlay should render with its placement")
	}
	// The layer must NOT span the old full band (8..12 rows): a 2-3 line overlay is
	// at most bandHeight tall, and its bottom edge is the screen bottom.
	if got := layer.Height(); got > bandHeight {
		t.Fatalf("notifications layer height %d exceeds band height %d (overflowed the rect)", got, bandHeight)
	}
	bottom := layer.GetY() + layer.Height()
	if bottom != bandRow+bandHeight {
		t.Fatalf("notifications bottom edge %d != band bottom %d (must hug the screen bottom)", bottom, bandRow+bandHeight)
	}
	if layer.GetY() < bandRow {
		t.Fatalf("notifications top %d escaped above the band top %d", layer.GetY(), bandRow)
	}
}

// TestWrapDependentOverlayBottomAlignsInMaxBand pins the wrap-dependent bucket
// (#2281): a float popup keeps the :max ceiling band, but Go bottom-aligns its
// short content so the overlay still hugs the screen bottom and the residual
// phantom zone sits ABOVE the content (between the buffer and the overlay).
func TestWrapDependentOverlayBottomAlignsInMaxBand(t *testing.T) {
	model := New(80, 24, nil, nil)
	model.chrome = map[byte]protocol.ChromePayload{
		generated.OPGuiFloatPopup: {Float: protocol.FloatPopup{Visible: true, Title: "Inspect", Lines: []string{"pid <0.1.0>"}}},
	}
	// :max band for a 24-row terminal clamps to 8 rows, bottom-anchored at 16..23.
	const bandRow, bandHeight = 16, 8
	model.surfacePlacements = []generated.SurfacePlacement{
		{SurfaceID: surfaceIDFloatPopup, Rect: generated.Rect{Row: bandRow, Col: 0, Width: 80, Height: bandHeight}, Z: 270, HitKind: 8},
	}

	layer := model.overlayLayer()
	if layer == nil {
		t.Fatalf("float popup overlay should render with its placement")
	}
	// Content is 2 lines (title + 1 line); it must bottom-align, not top-align.
	if got := layer.Height(); got >= bandHeight {
		t.Fatalf("float popup should render its short content (got %d lines), not fill the band", got)
	}
	bottom := layer.GetY() + layer.Height()
	if bottom != bandRow+bandHeight {
		t.Fatalf("float popup bottom edge %d != band bottom %d (must hug the screen bottom)", bottom, bandRow+bandHeight)
	}
	// The phantom zone is above the content: the layer top is strictly below the
	// band top.
	if layer.GetY() <= bandRow {
		t.Fatalf("float popup should bottom-align (top %d) leaving the phantom zone above, band top %d", layer.GetY(), bandRow)
	}
}
