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

func TestDecodeEmptyStateRoundTrip(t *testing.T) {
	var body []byte
	body = append(body, 0x01, 0x00) // visible=1, flags=0 (not crashed)
	body = append(body, str8("v0.9")...)
	body = append(body, str8("resume")...)
	body = append(body, 0x03) // three sections

	// session
	body = append(body, 0x00)               // section id: session
	body = append(body, str8("Session")...) // title
	body = append(body, 0x01)               // one item
	body = append(body, 0x00)               // kind: resume
	body = append(body, str8("resume")...)  // id
	body = append(body, str16("resume last session")...)
	body = append(body, str16("4 files")...) // detail
	body = append(body, str8("r")...)        // jump_key
	body = append(body, str8("")...)         // chord
	body = append(body, str8("")...)         // icon
	body = append(body, u32be(0)...)         // icon_color

	// recent
	body = append(body, 0x01)                         // section id: recent
	body = append(body, str8("Recent")...)            // title
	body = append(body, 0x01)                         // one item
	body = append(body, 0x01)                         // kind: recent_file
	body = append(body, str8("recent-1")...)          // id
	body = append(body, str16("startup.ex")...)       // label
	body = append(body, str16("lib/minga_editor")...) // detail
	body = append(body, str8("1")...)                 // jump_key
	body = append(body, str8("")...)                  // chord
	body = append(body, str8("")...)                 // icon glyph
	body = append(body, u32be(0x61AFEF)...)           // icon_color

	// start
	body = append(body, 0x02)             // section id: start
	body = append(body, str8("Start")...) // title
	body = append(body, 0x01)             // one item
	body = append(body, 0x02)             // kind: action
	body = append(body, str8("action-find-file")...)
	body = append(body, str16("open file")...) // label
	body = append(body, str16("")...)          // detail
	body = append(body, str8("")...)           // jump_key
	body = append(body, str8("SPC f f")...)    // chord
	body = append(body, str8("4")...)         // icon glyph
	body = append(body, u32be(0x61AFEF)...)    // icon_color

	frame := frameEmptyState(body)

	cmd, err := DecodeCommand(frame)
	if err != nil {
		t.Fatalf("decode empty_state: %v", err)
	}
	if cmd.Kind != CommandChrome {
		t.Fatalf("empty_state should decode as chrome, got kind %v", cmd.Kind)
	}
	if cmd.Size != len(frame) {
		t.Fatalf("empty_state size = %d, want %d", cmd.Size, len(frame))
	}

	state := cmd.Chrome.EmptyState
	if !state.Visible || state.Crashed {
		t.Fatalf("visible=%v crashed=%v, want visible not crashed", state.Visible, state.Crashed)
	}
	if state.Version != "v0.9" || state.FocusedID != "resume" {
		t.Fatalf("version=%q focused=%q", state.Version, state.FocusedID)
	}
	if len(state.Sections) != 3 {
		t.Fatalf("sections = %d, want 3", len(state.Sections))
	}

	session := state.Sections[0]
	if session.ID != 0 || session.Title != "Session" || len(session.Items) != 1 {
		t.Fatalf("session section mismatch: %+v", session)
	}
	resume := session.Items[0]
	if resume.Kind != 0 || resume.ID != "resume" || resume.Label != "resume last session" || resume.Detail != "4 files" || resume.JumpKey != "r" {
		t.Fatalf("resume item mismatch: %+v", resume)
	}

	recent := state.Sections[1].Items[0]
	if recent.Kind != 1 || recent.ID != "recent-1" || recent.Label != "startup.ex" || recent.Detail != "lib/minga_editor" || recent.JumpKey != "1" || recent.IconColor != 0x61AFEF {
		t.Fatalf("recent item mismatch: %+v", recent)
	}

	action := state.Sections[2].Items[0]
	if action.Kind != 2 || action.ID != "action-find-file" || action.Label != "open file" || action.Chord != "SPC f f" || action.IconColor != 0x61AFEF {
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

func TestDecodeEmptyStateCrashedFlag(t *testing.T) {
	var body []byte
	body = append(body, 0x01, 0x01) // visible=1, flags bit0 = crashed
	body = append(body, str8("v0.9")...)
	body = append(body, str8("resume")...)
	body = append(body, 0x00) // zero sections

	cmd, err := DecodeCommand(frameEmptyState(body))
	if err != nil {
		t.Fatalf("decode crashed empty_state: %v", err)
	}
	if !cmd.Chrome.EmptyState.Crashed {
		t.Fatalf("crashed flag should decode true")
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
