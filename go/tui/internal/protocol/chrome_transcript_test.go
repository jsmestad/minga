package protocol

import (
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// userBody builds the shared kind-first message body for a user text message:
// <<0x01, len:u32, text>>. This is the same body the 0x78 messages section
// carries after its per-message id, so the resident transcript reuses it.
func userBody(text string) []byte {
	body := []byte{0x01}
	body = binary.BigEndian.AppendUint32(body, uint32(len(text)))
	return append(body, []byte(text)...)
}

type transcriptEntry struct {
	id   uint32
	body []byte
}

// replaceFrameBytes builds a full_replace gui_agent_transcript (0x86) wire frame:
// [opcode][len:u32] version(1) mode(1)=0 epoch(4) truncated(1) count(4)
// count*[id(4) body_len(4) body].
func replaceFrameBytes(epoch uint32, truncated bool, entries []transcriptEntry) []byte {
	payload := []byte{transcriptVersion, transcriptModeReplace}
	payload = binary.BigEndian.AppendUint32(payload, epoch)
	payload = append(payload, boolByte(truncated))
	payload = binary.BigEndian.AppendUint32(payload, uint32(len(entries)))
	return frameBytes(appendEntries(payload, entries))
}

// appendFrameBytes builds an append gui_agent_transcript (0x86) wire frame:
// version(1) mode(1)=1 epoch(4) truncated(1) trim_front(4) base_count(4) count(4)
// count*entries.
func appendFrameBytes(epoch uint32, truncated bool, trimFront, base uint32, entries []transcriptEntry) []byte {
	payload := []byte{transcriptVersion, transcriptModeAppend}
	payload = binary.BigEndian.AppendUint32(payload, epoch)
	payload = append(payload, boolByte(truncated))
	payload = binary.BigEndian.AppendUint32(payload, trimFront)
	payload = binary.BigEndian.AppendUint32(payload, base)
	payload = binary.BigEndian.AppendUint32(payload, uint32(len(entries)))
	return frameBytes(appendEntries(payload, entries))
}

func appendEntries(payload []byte, entries []transcriptEntry) []byte {
	for _, e := range entries {
		payload = binary.BigEndian.AppendUint32(payload, e.id)
		payload = binary.BigEndian.AppendUint32(payload, uint32(len(e.body)))
		payload = append(payload, e.body...)
	}
	return payload
}

func frameBytes(payload []byte) []byte {
	frame := []byte{generated.OPGuiAgentTranscript}
	frame = binary.BigEndian.AppendUint32(frame, uint32(len(payload)))
	return append(frame, payload...)
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}

func TestDecodeAgentTranscriptFullReplace(t *testing.T) {
	frame := replaceFrameBytes(7, true, []transcriptEntry{
		{id: 1, body: userBody("first")},
		{id: 2, body: userBody("second")},
	})

	got, _, size := decodeAgentTranscript(frame)
	if size != len(frame) {
		t.Fatalf("size = %d, want %d", size, len(frame))
	}
	if !got.Present || !got.FullReplace() || got.Epoch != 7 || !got.Truncated {
		t.Fatalf("unexpected header: %+v", got)
	}
	if len(got.Messages) != 2 {
		t.Fatalf("message count = %d, want 2", len(got.Messages))
	}
	if got.Messages[0].ID != 1 || got.Messages[0].Text != "first" {
		t.Fatalf("message[0] = %+v", got.Messages[0])
	}
	if got.Messages[1].ID != 2 || got.Messages[1].Text != "second" {
		t.Fatalf("message[1] = %+v", got.Messages[1])
	}
}

func TestDecodeAgentTranscriptAppend(t *testing.T) {
	frame := appendFrameBytes(7, false, 2, 3, []transcriptEntry{
		{id: 4, body: userBody("fourth")},
	})

	got, _, _ := decodeAgentTranscript(frame)
	if got.FullReplace() {
		t.Fatalf("append frame reported full_replace")
	}
	if got.Epoch != 7 || got.TrimFront != 2 || got.BaseCount != 3 || got.Truncated {
		t.Fatalf("header = %+v", got)
	}
	if len(got.Messages) != 1 || got.Messages[0].ID != 4 || got.Messages[0].Text != "fourth" {
		t.Fatalf("messages = %+v", got.Messages)
	}
}

func TestDecodeAgentTranscriptTruncatedBodyStops(t *testing.T) {
	// count claims 2 entries but only one full entry is present; decode keeps the
	// decodable prefix and does not panic.
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: userBody("only")},
	})
	// Bump the count field. Offset: opcode(1)+len(4)+version(1)+mode(1)+epoch(4)+
	// truncated(1) = 12 for a full_replace frame.
	binary.BigEndian.PutUint32(frame[12:], 2)

	got, _, _ := decodeAgentTranscript(frame)
	if len(got.Messages) != 1 {
		t.Fatalf("expected 1 decodable message, got %d", len(got.Messages))
	}
}

func TestDecodeAgentTranscriptShortHeader(t *testing.T) {
	frame := []byte{generated.OPGuiAgentTranscript, 0, 0, 0, 2, 0xAA, 0xBB}
	got, _, size := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("short header should not be marked present")
	}
	if size != len(frame) {
		t.Fatalf("size = %d, want %d", size, len(frame))
	}
}

func TestDecodeAgentTranscriptRoutesThroughChrome(t *testing.T) {
	frame := replaceFrameBytes(4, false, []transcriptEntry{
		{id: 9, body: userBody("hello")},
	})
	chrome := decodeChrome(frame)
	if chrome.Opcode != generated.OPGuiAgentTranscript {
		t.Fatalf("opcode = %#x", chrome.Opcode)
	}
	if !chrome.AgentTranscript.Present || len(chrome.AgentTranscript.Messages) != 1 {
		t.Fatalf("chrome transcript not decoded: %+v", chrome.AgentTranscript)
	}
	if chrome.Bytes != len(frame) {
		t.Fatalf("chrome.Bytes = %d, want %d", chrome.Bytes, len(frame))
	}
}
