package protocol

import (
	"bytes"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// str8/str16/u32be build the wire encodings the BEAM launchpad encoder emits
// (Minga.Frontend.Adapter.GUI.EmptyStateEncoder), so the fixtures below are the
// exact bytes a frontend decodes.
func str8(value string) []byte {
	return append([]byte{byte(len(value))}, value...)
}

func str16(value string) []byte {
	return append([]byte{byte(len(value) >> 8), byte(len(value))}, value...)
}

func u32be(value uint32) []byte {
	return []byte{byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value)}
}

func frameEmptyState(body []byte) []byte {
	out := []byte{generated.OPGuiEmptyState, byte(len(body) >> 8), byte(len(body))}
	return append(out, body...)
}

func homeItem(kind byte, id, label, detail, meta, jump, chord, icon string, color uint32, state string) []byte {
	var item []byte
	item = append(item, kind)
	item = append(item, str8(id)...)
	item = append(item, str16(label)...)
	item = append(item, str16(detail)...)
	item = append(item, str16(meta)...)
	item = append(item, str8(jump)...)
	item = append(item, str8(chord)...)
	item = append(item, str8(icon)...)
	item = append(item, u32be(color)...)
	return append(item, str8(state)...)
}

func TestDecodeEmptyStateRoundTrip(t *testing.T) {
	var body []byte
	body = append(body, 0x02) // payload version 2 (visible)
	body = append(body, str16("minga")...)
	body = append(body, str16("~/code/minga")...)
	body = append(body, str16("main · 11 changed")...)
	body = append(body, str16("")...)
	body = append(body, str8("recent-1")...)
	body = append(body, 0x03) // three sections

	body = append(body, 0x01) // recent files
	body = append(body, str8("Recent in this project")...)
	body = append(body, str16("Nothing opened here yet.")...)
	body = append(body, 0x01)
	body = append(body, homeItem(0x01, "recent-1", "startup.ex", "lib/minga_editor", "2 h ago", "1", "", "e", 0x61AFEF, "")...)

	body = append(body, 0x05) // Minga tasks
	body = append(body, str8("Minga tasks")...)
	body = append(body, str16("")...)
	body = append(body, 0x01)
	body = append(body, homeItem(0x05, "task-3", "Add tests", "Needs you", "", "", "", "", 0, "needs_you")...)

	body = append(body, 0x06) // next actions
	body = append(body, str8("Next")...)
	body = append(body, str16("")...)
	body = append(body, 0x01)
	body = append(body, homeItem(0x02, "action-project_find_file", "Find a file", "", "", "", "SPC SPC", "", 0, "")...)

	frame := frameEmptyState(body)

	cmd, err := DecodeCommand(frame)
	if err != nil {
		t.Fatalf("decode empty_state: %v", err)
	}
	if cmd.Kind != CommandChrome || cmd.Size != len(frame) {
		t.Fatalf("empty_state kind=%v size=%d, want chrome size %d", cmd.Kind, cmd.Size, len(frame))
	}

	state := cmd.Chrome.EmptyState
	if !state.Visible || state.Title != "minga" || state.Path != "~/code/minga" || state.Status != "main · 11 changed" || state.FocusedID != "recent-1" {
		t.Fatalf("header mismatch: %+v", state)
	}
	if len(state.Sections) != 3 {
		t.Fatalf("sections = %d, want 3", len(state.Sections))
	}

	recent := state.Sections[0]
	if recent.ID != 1 || recent.Title != "Recent in this project" || recent.Empty != "Nothing opened here yet." {
		t.Fatalf("recent section mismatch: %+v", recent)
	}
	file := recent.Items[0]
	if file.Kind != 1 || file.ID != "recent-1" || file.Label != "startup.ex" || file.Detail != "lib/minga_editor" || file.Meta != "2 h ago" || file.JumpKey != "1" || file.IconColor != 0x61AFEF {
		t.Fatalf("recent item mismatch: %+v", file)
	}

	task := state.Sections[1].Items[0]
	if task.Kind != 5 || task.ID != "task-3" || task.State != "needs_you" || task.Detail != "Needs you" {
		t.Fatalf("task item mismatch: %+v", task)
	}

	action := state.Sections[2].Items[0]
	if action.Kind != 2 || action.Chord != "SPC SPC" || action.Label != "Find a file" {
		t.Fatalf("action item mismatch: %+v", action)
	}
}

func TestDecodeEmptyStateHidden(t *testing.T) {
	frame := frameEmptyState([]byte{0x00})
	cmd, err := DecodeCommand(frame)
	if err != nil {
		t.Fatalf("decode hidden empty_state: %v", err)
	}
	if cmd.Kind != CommandChrome {
		t.Fatalf("hidden empty_state should decode as chrome, got %v", cmd.Kind)
	}
	if cmd.Size != len(frame) {
		t.Fatalf("hidden empty_state size = %d, want %d", cmd.Size, len(frame))
	}
	if cmd.Chrome.EmptyState.Visible {
		t.Fatalf("hidden frame should decode to invisible state")
	}
}

func TestDecodeEmptyStateTruncatedSectionKeepsHeader(t *testing.T) {
	var body []byte
	body = append(body, 0x02)
	body = append(body, str16("notes")...)
	body = append(body, str16("~/Downloads/notes")...)
	body = append(body, str16("Not a project")...)
	body = append(body, str16("Minga uses this folder as the root for now.")...)
	body = append(body, str8("")...)
	body = append(body, 0x01, 0x01) // one section, id recent, then nothing

	cmd, err := DecodeCommand(frameEmptyState(body))
	if err != nil {
		t.Fatalf("decode truncated empty_state: %v", err)
	}
	state := cmd.Chrome.EmptyState
	if !state.Visible || state.Note != "Minga uses this folder as the root for now." || len(state.Sections) != 0 {
		t.Fatalf("a truncated section should keep the header and drop the section: %+v", state)
	}
}

func TestEncodeGUIEmptyStateActivate(t *testing.T) {
	got := EncodeGUIEmptyStateActivate("recent-2")
	want := []byte{
		generated.OPGuiAction, generated.GUIActionEmptyStateActivate,
		8, 'r', 'e', 'c', 'e', 'n', 't', '-', '2',
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("empty_state_activate packet = %v, want %v", got, want)
	}
}
