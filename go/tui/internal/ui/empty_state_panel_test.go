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
		Title:     "minga",
		Path:      "~/code/minga",
		Status:    "main · 11 changed",
		FocusedID: "recent-1",
		Sections: []protocol.EmptyStateSection{
			{
				ID:    emptyStateSectionRecent,
				Title: "Recent in this project",
				Empty: "Nothing opened here yet.",
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindRecentFile, ID: "recent-1", Label: "startup.ex", Detail: "lib/minga_editor", JumpKey: "1", Icon: "\ue62d", IconColor: 0x61AFEF},
					{Kind: emptyStateKindRecentFile, ID: "recent-2", Label: "render_content.go", Detail: "go/tui/internal/ui", JumpKey: "2", Icon: "\ue627", IconColor: 0x519ABA},
				},
			},
			{
				ID:    emptyStateSectionTasks,
				Title: "Minga tasks",
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindTask, ID: "task-3", Label: "Add tests for the usage-limit classifier", Detail: "Needs you", State: "needs_you"},
				},
			},
			{
				ID:    emptyStateSectionNext,
				Title: "Next",
				Items: []protocol.EmptyStateItem{
					{Kind: emptyStateKindAction, ID: "action-project_find_file", Label: "Find a file", Chord: "SPC SPC"},
					{Kind: emptyStateKindAction, ID: "action-toggle_file_tree", Label: "File tree", Chord: "SPC o p"},
				},
			},
		},
	}
}

func modelWithEmptyState(width, height uint16, state protocol.EmptyState) Model {
	model := New(width, height, nil)
	model.chrome[generated.OPGuiEmptyState] = protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: state}
	model.layout = model.computeLayout()
	model.viewport.SetWidth(model.layout.body.Width)
	model.viewport.SetHeight(model.layout.body.Height)
	model.viewport.SetContent(model.content())
	return model
}

func TestRenderEmptyStateShowsProjectHome(t *testing.T) {
	model := modelWithEmptyState(80, 30, returningUserEmptyState())
	view := ansi.Strip(model.content())

	for _, want := range []string{
		"minga", "~/code/minga", "main · 11 changed",
		"Recent in this project", "startup.ex", "lib/minga_editor",
		"Minga tasks", "◉", "Add tests for the usage-limit classifier", "Needs you",
		"Next", "SPC SPC", "Find a file", "SPC o p", "File tree",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("home view missing %q:\n%s", want, view)
		}
	}
}

func TestRenderEmptyStateLinesUpTheKeyColumn(t *testing.T) {
	model := modelWithEmptyState(80, 30, returningUserEmptyState())
	view := ansi.Strip(model.content())

	find := func(label string) int {
		for _, line := range strings.Split(view, "\n") {
			if i := strings.Index(line, label); i >= 0 {
				return i
			}
		}
		t.Fatalf("missing %q:\n%s", label, view)
		return -1
	}
	if find("Find a file") != find("File tree") {
		t.Fatalf("action labels should share one column:\n%s", view)
	}
}

func TestRenderEmptyStateShowsTheEmptyLine(t *testing.T) {
	state := returningUserEmptyState()
	state.Sections[0].Items = nil
	model := modelWithEmptyState(80, 30, state)
	if view := ansi.Strip(model.content()); !strings.Contains(view, "Nothing opened here yet.") {
		t.Fatalf("an empty section should say so:\n%s", view)
	}
}

func TestRenderEmptyStateNeverExceedsBodyHeight(t *testing.T) {
	for _, height := range []uint16{6, 12, 30} {
		model := modelWithEmptyState(80, height, returningUserEmptyState())
		lines := model.renderEmptyState(returningUserEmptyState())
		if len(lines) != model.bodyHeight() {
			t.Fatalf("height %d: home rendered %d lines, want bodyHeight %d", height, len(lines), model.bodyHeight())
		}
	}
}

func TestRenderEmptyStateFitsNarrowWidth(t *testing.T) {
	model := modelWithEmptyState(30, 30, returningUserEmptyState())
	for _, line := range model.renderEmptyState(returningUserEmptyState()) {
		if w := ansi.StringWidth(line); w != 30 {
			t.Fatalf("every line should be exactly 30 cells, got %d: %q", w, ansi.Strip(line))
		}
	}
}

func TestEmptyStateLocalFocusEchoOnJ(t *testing.T) {
	out := make(chan []byte, 4)
	model := New(80, 30, out)
	model.chrome[generated.OPGuiEmptyState] = protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: returningUserEmptyState()}
	model.applyMutation(focusOwnerCommand(0, 13))

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
	model := New(80, 30, nil)
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
