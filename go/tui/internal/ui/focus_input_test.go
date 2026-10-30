package ui

import (
	"bytes"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func focusOwnerCommand(responder, surface byte) protocol.Command {
	return protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
		Opcode:     generated.OPGuiFocusOwner,
		FocusOwner: generated.GuiFocusOwnerFields{Responder: responder, Surface: surface, WindowID: 1},
	}}
}

func multipleVisibleFocusSurfaces(owner *protocol.Command) Model {
	model := New(80, 30, nil, nil)
	commands := []protocol.Command{
		testThemeCommand(),
		{Kind: protocol.CommandChrome, Chrome: pickerChrome(3, 0)},
		{Kind: protocol.CommandChrome, Chrome: completionChrome(3, 0)},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiEmptyState, EmptyState: returningUserEmptyState()}},
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiFileTree, Tree: protocol.FileTree{
			Visible: true, Focused: false, Generation: 7, Flags: fileTreeLocalNavigationFlag,
			Status: fileTreeReadyStatus, Selected: "a",
			Rows: []protocol.FileTreeRow{{ID: "a", Name: "a"}, {ID: "b", Name: "b"}},
		}}},
	}
	if owner != nil {
		commands = append(commands, *owner)
	}
	applyProductionFrame(&model, 1, 0, 1, commands...)
	return model
}

func TestCommittedOwnerGatesNavigationWithMultipleVisibleSurfaces(t *testing.T) {
	for _, tc := range []struct {
		name      string
		responder byte
		surface   byte
		missing   bool
		preview   presentationSurface
		empty     bool
	}{
		{name: "file tree", responder: 0, surface: 1, preview: presentationFileTree},
		{name: "picker", responder: 1, surface: 8, preview: presentationPicker},
		{name: "completion", responder: 0, surface: 9, preview: presentationCompletion},
		{name: "launchpad", responder: 0, surface: 13, empty: true},
		{name: "hover above launchpad", responder: 0, surface: 12},
		{name: "native inline edit", responder: 3, surface: 5},
		{name: "mismatched responder", responder: 3, surface: 1},
		{name: "unknown owner", responder: 0, surface: 255},
		{name: "missing owner", missing: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			owner := focusOwnerCommand(tc.responder, tc.surface)
			var initial *protocol.Command
			if !tc.missing {
				initial = &owner
			}
			model := multipleVisibleFocusSurfaces(initial)
			out := make(chan []byte, 8)
			model.out = out
			updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}))
			model = updated.(Model)
			for _, kind := range []presentationSurface{presentationFileTree, presentationPicker, presentationCompletion} {
				_, present := model.localPresentation.identityPreview(kind)
				if present != (kind == tc.preview) {
					t.Fatalf("preview %v present=%v, want owner preview %v", kind, present, tc.preview)
				}
			}
			if (model.localPresentation.previewEmptyStateIndex != nil) != tc.empty {
				t.Fatalf("launchpad preview changed under %s owner", tc.name)
			}
			packets := drainOutboundPackets(out)
			if len(packets) != 1 || packets[0][0] != generated.OPKeyPress {
				t.Fatalf("navigation must still reach BEAM: %v", packets)
			}
		})
	}
}

func TestFocusChangePreventsRetainedPreviewFromStealingEnter(t *testing.T) {
	for _, owner := range []protocol.Command{focusOwnerCommand(0, 12), focusOwnerCommand(3, 5), focusOwnerCommand(3, 1)} {
		initial := focusOwnerCommand(0, 1)
		model := multipleVisibleFocusSurfaces(&initial)
		model.localPresentation.setIdentityPreview(presentationFileTree, 7, "b")
		applyProductionFrame(&model, 2, 1, 1, owner)
		if _, retained := model.localPresentation.identityPreview(presentationFileTree); !retained {
			t.Fatal("test requires a retained file-tree preview across the focus change")
		}
		out := make(chan []byte, 8)
		model.out = out
		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter}))
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		if len(packets) != 1 || packets[0][0] != generated.OPKeyPress || codepoint(packets[0]) != 13 {
			t.Fatalf("retained preview stole Enter from owner %+v: %v", owner.Chrome.FocusOwner, packets)
		}
	}
}

func TestCommittedOwnerGatesAgentShortcutAndTranscriptKeys(t *testing.T) {
	for _, agentOwns := range []bool{false, true} {
		model := residentModel(t, 40)
		model.transcript.apply(protocol.AgentTranscript{Present: true, Mode: 0, Epoch: 2, Messages: []protocol.AgentChatMessage{
			{ID: 44, Kind: agentKindThinking, Text: "thinking"},
		}})
		surface := byte(12)
		if agentOwns {
			surface = 2
		}
		model.applyMutation(focusOwnerCommand(0, surface))
		out := make(chan []byte, 8)
		model.out = out
		updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: 'z', Mod: tea.ModCtrl | tea.ModAlt}))
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		if agentOwns {
			if len(packets) != 1 || !bytes.Equal(packets[0], protocol.EncodeGUIAgentToolToggle(44)) {
				t.Fatalf("agent owner did not activate its thinking block: %v", packets)
			}
		} else if len(packets) != 1 || packets[0][0] != generated.OPKeyPress {
			t.Fatalf("visible agent stole shortcut from committed hover owner: %v", packets)
		}

		model = residentModel(t, 100)
		model.applyMutation(focusOwnerCommand(0, surface))
		updated, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: 'k', Text: "k"}))
		model = updated.(Model)
		if model.transcript.pinned == agentOwns {
			t.Fatalf("transcript key ownership ignored: agentOwns=%v pinned=%v", agentOwns, model.transcript.pinned)
		}
	}
}

func TestCommittedOwnerChoosesOnlyItsOwnRetainedPreviewActivation(t *testing.T) {
	for _, tc := range []struct {
		name      string
		responder byte
		surface   byte
		kind      presentationSurface
		wireID    []byte
	}{
		{"file tree", 0, 1, presentationFileTree, []byte("b")},
		{"picker", 1, 8, presentationPicker, []byte{0, 0, 0, 2}},
		{"completion", 0, 9, presentationCompletion, []byte("completion-1")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			owner := focusOwnerCommand(tc.responder, tc.surface)
			model := multipleVisibleFocusSurfaces(&owner)
			model.localPresentation.setIdentityPreview(presentationFileTree, 7, "b")
			model.localPresentation.setIdentityPreview(presentationPicker, 7, "2")
			model.localPresentation.setIdentityPreview(presentationCompletion, 7, "completion-1")
			out := make(chan []byte, 8)
			model.out = out
			_, _ = model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter}))
			packets := drainOutboundPackets(out)
			want := protocol.EncodeGUISemanticItemActivate(byte(tc.kind), 1, 7, tc.wireID)
			if len(packets) != 1 || !bytes.Equal(packets[0], want) {
				t.Fatalf("owner %s did not activate its exact retained preview: got %v want %v", tc.name, packets, want)
			}
		})
	}
}

func TestLaunchpadLeaderOwnerPreventsNavigationBehindWhichKey(t *testing.T) {
	model := New(80, 30, nil, nil)
	applyProductionFrame(&model, 1, 0, 1,
		testThemeCommand(),
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
			Opcode: generated.OPGuiEmptyState, EmptyState: returningUserEmptyState(),
		}},
		focusOwnerCommand(0, 13),
	)
	applyProductionFrame(&model, 2, 1, 1,
		protocol.Command{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{
			Opcode: generated.OPGuiWhichKey, Which: protocol.WhichKey{Visible: true, Prefix: "SPC"},
		}},
		focusOwnerCommand(0, 0),
	)
	out := make(chan []byte, 8)
	model.out = out
	updated, _ := model.Update(tea.KeyPressMsg(tea.Key{Code: tea.KeyDown}))
	model = updated.(Model)
	if model.localPresentation.previewEmptyStateIndex != nil {
		t.Fatal("Down moved launchpad focus while the committed owner was the leader handler")
	}
	state, visible := model.emptyState()
	if !visible || state.FocusedID != "resume" {
		t.Fatalf("leader navigation changed the retained launchpad: %+v", state)
	}
	packets := drainOutboundPackets(out)
	if len(packets) != 1 || packets[0][0] != generated.OPKeyPress {
		t.Fatalf("leader key must reach BEAM rather than a local action: %v", packets)
	}
}
