package ui

import (
	"bytes"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func returningUserEmptyState() protocol.EmptyState {
	return protocol.EmptyState{
		Visible:   true,
		Version:   "v0.9",
		FocusedID: "resume",
		Sections: []protocol.EmptyStateSection{
			{
				ID:    emptyStateSectionSession,
				Title: "Session",
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindResume, ID: "resume", Label: "resume last session", Detail: "4 files", JumpKey: "r"},
				},
			},
			{
				ID:    emptyStateSectionRecent,
				Title: "Recent",
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindRecentFile, ID: "recent-1", Label: "startup.ex", Detail: "lib/minga_editor", JumpKey: "1", Icon: "", IconColor: 0x61AFEF},
					{Kind: emptyStateKindRecentFile, ID: "recent-2", Label: "render_content.go", Detail: "go/tui/internal/ui", JumpKey: "2", Icon: "", IconColor: 0x519ABA},
				},
			},
			{
				ID:    emptyStateSectionStart,
				Title: "Start",
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindAction, ID: "action-find-file", Label: "open file", Chord: "SPC f f", Icon: "", IconColor: 0x61AFEF},
					{Kind: emptyStateKindAction, ID: "action-tutor", Label: "tutorial", Detail: ":Tutor"},
				},
			},
			{
				ID: emptyStateSectionFooter,
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindHint, ID: "hint-write", Label: "write", JumpKey: "i"},
					{Kind: emptyStateKindHint, ID: "hint-quit", Label: "quit", Detail: ":q"},
				},
			},
		},
	}
}

func modelWithEmptyState(width, height uint16, state protocol.EmptyState) Model {
	model := New(width, height, nil, nil)
	model.chrome[generated.OPGuiEmptyState] = protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: state}
	model.layout = model.computeLayout()
	model.viewport.SetWidth(model.layout.body.Width)
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return model
}

func TestRenderEmptyStateShowsLaunchpadContent(t *testing.T) {
	model := modelWithEmptyState(80, 30, returningUserEmptyState())
	view := ansi.Strip(model.content())

	for _, want := range []string{
		"m i n g a", // letter-spaced wordmark
		"v0.9",      // faint version
		"Session",   // session card title in the top border (cards keep case)
		"resume last session",
		"4 files",          // right-aligned detail
		"RECENT",           // section rule label (uppercased at render time)
		"startup.ex",       // recent basename
		"lib/minga_editor", // recent directory (width >= 64 keeps it)
		"START",
		"open file",
		"SPC",   // chord chip token
		"write", // footer verb
		"quit",
		"╭", "╰", "│", // card border
		"▸", // focus marker on the resume card
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("launchpad view missing %q:\n%s", want, view)
		}
	}
}

func TestRenderEmptyStateNeverExceedsBodyHeight(t *testing.T) {
	model := modelWithEmptyState(80, 30, returningUserEmptyState())
	lines := model.renderEmptyState(returningUserEmptyState())
	if len(lines) != model.bodyHeight() {
		t.Fatalf("launchpad rendered %d lines, want bodyHeight %d", len(lines), model.bodyHeight())
	}
}

func TestRenderEmptyStateDegradesAtSmallHeight(t *testing.T) {
	// bodyHeight = height - header(1) - footer(1). At height 15 the body is 13
	// rows: below the 16-row chrome breakpoint, so the wordmark and section rules
	// drop while the hero card stays.
	model := modelWithEmptyState(80, 15, returningUserEmptyState())
	view := ansi.Strip(model.content())

	if strings.Contains(view, "m i n g a") {
		t.Fatalf("wordmark should drop below the 16-row chrome breakpoint:\n%s", view)
	}
	if strings.Contains(view, "─── Recent") {
		t.Fatalf("section rules should drop below the 16-row chrome breakpoint:\n%s", view)
	}
	if !strings.Contains(view, "resume last session") {
		t.Fatalf("hero card should survive height degradation:\n%s", view)
	}
}

func TestRenderEmptyStateDegradesAtNarrowWidth(t *testing.T) {
	// Width 46 is below the 48-column card-border breakpoint (borders drop to a
	// plain row under a rule) and below the 64-column breakpoint (recents lose
	// the directory column).
	model := modelWithEmptyState(46, 30, returningUserEmptyState())
	view := ansi.Strip(model.content())

	if strings.Contains(view, "╭") {
		t.Fatalf("card borders should drop below 48 columns:\n%s", view)
	}
	if strings.Contains(view, "lib/minga_editor") {
		t.Fatalf("recent directory column should drop below 64 columns:\n%s", view)
	}
	if !strings.Contains(view, "resume last session") || !strings.Contains(view, "startup.ex") {
		t.Fatalf("core rows should survive width degradation:\n%s", view)
	}
}

func TestRenderEmptyStateMinimalUnderTwelveRows(t *testing.T) {
	// bodyHeight = 13 - 2 = 11, below the 12-row minimal cutoff.
	model := modelWithEmptyState(80, 13, returningUserEmptyState())
	view := ansi.Strip(model.content())

	if strings.Contains(view, "╭") || strings.Contains(view, "startup.ex") {
		t.Fatalf("minimal fallback should drop cards and recents:\n%s", view)
	}
	if !strings.Contains(view, "minga") {
		t.Fatalf("minimal fallback should still show the wordmark:\n%s", view)
	}
}

func TestEmptyStateLocalFocusEchoOnJ(t *testing.T) {
	out := make(chan []byte, 4)
	model := New(80, 30, out, nil)
	model.chrome[generated.OPGuiEmptyState] = protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: returningUserEmptyState()}

	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'j', Text: "j"}))
	model = updated.(Model)

	if model.localPresentation.previewEmptyStateIndex == nil || *model.localPresentation.previewEmptyStateIndex != 1 {
		t.Fatalf("j should locally advance focus to index 1, got %v", model.localPresentation.previewEmptyStateIndex)
	}
	// Focus movement stays authoritative on the BEAM: the key must still forward.
	packets := drainOutboundPackets(out)
	if len(packets) == 0 {
		t.Fatalf("j should still forward the key packet to the BEAM")
	}
}

func TestEmptyStateLocalFocusEchoClearsOnFrame(t *testing.T) {
	model := New(80, 30, nil, nil)
	model.chrome[generated.OPGuiEmptyState] = protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: returningUserEmptyState()}
	idx := 1
	model.localPresentation.previewEmptyStateIndex = &idx

	next := returningUserEmptyState()
	next.FocusedID = "recent-2"
	updated, _ := model.Update(port.PacketMsg{Commands: frame(protocol.Command{
		Kind:   protocol.CommandChrome,
		Chrome: protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: next},
	})})
	model = updated.(Model)

	if model.localPresentation.previewEmptyStateIndex != nil {
		t.Fatalf("a fresh empty_state frame should clear the local focus echo (focused_id wins)")
	}
}

func TestEmptyStateMouseClickActivatesRow(t *testing.T) {
	model := modelWithEmptyState(80, 30, returningUserEmptyState())
	_ = model.View() // scan zone markers into the zone manager

	zone := waitForZone(t, model, zoneIDEmptyStateItem("recent-1"))
	packet, ok := model.semanticMousePacket(tea.MouseClickMsg(tea.Mouse{Button: tea.MouseLeft, X: zone.StartX + 1, Y: zone.StartY}))
	if !ok || !bytes.Equal(packet, protocol.EncodeGUIEmptyStateActivate("recent-1")) {
		t.Fatalf("recent row click should route empty_state_activate, ok=%v packet=%v", ok, packet)
	}
}

func TestEmptyStateHidesTabBar(t *testing.T) {
	model := modelWithEmptyState(80, 30, returningUserEmptyState())
	if _, ok := model.tabBar(); ok {
		t.Fatalf("no tab chrome should exist in the empty state; tab bar must self-hide")
	}
	// The header collapses to the plain title row (no phantom tab row).
	if got := len(model.headerLines()); got != 1 {
		t.Fatalf("header should be a single title row with no tabs, got %d lines", got)
	}
}
