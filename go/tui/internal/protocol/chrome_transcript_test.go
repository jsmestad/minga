package protocol

import (
	"encoding/binary"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// userBody builds the shared kind-first message body for a user text message:
// <<0x01, len:u32, text>>.
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

func TestDecodeAgentTranscriptStructuredBodies(t *testing.T) {
	styled := []byte{0x07, 0, 1, 0, 1}
	styled = append(styled, string16("  def hello")...)
	styled = append(styled, 0x98, 0xBE, 0x65, 0x21, 0x24, 0x2B, 0x10)

	markdown := []byte{0x0A, 0, 1}
	markdown = append(markdown, u32Bytes(123)...)
	markdown = append(markdown, 0x07, 0x01)
	markdown = append(markdown, string16("elixir")...)
	markdown = append(markdown, string16("Elixir")...)
	markdown = append(markdown, string16("lib/demo.ex")...)
	markdown = append(markdown, 0x01, 0, 1, 0, 1)
	markdown = append(markdown, string16("IO.puts(:hi)")...)
	markdown = append(markdown, 0x98, 0xBE, 0x65, 0x21, 0x24, 0x2B, 0x10)

	got, _, _ := decodeAgentTranscript(replaceFrameBytes(9, false, []transcriptEntry{
		{id: 7, body: styled},
		{id: 8, body: markdown},
	}))
	if !got.Present || len(got.Messages) != 2 {
		t.Fatalf("structured transcript not decoded: %+v", got)
	}
	run := got.Messages[0].StyledLines[0][0]
	if !run.Code() || run.Flags != 0x10 {
		t.Fatalf("styled run flags = 0x%02X, want code flag", run.Flags)
	}
	block := got.Messages[1].MarkdownBlocks[0]
	if block.Kind != 0x07 || !block.Complete() || block.Language != "elixir" || block.Label != "Elixir" || block.TargetPath != "lib/demo.ex" || !block.Lines[0][0].Code() {
		t.Fatalf("markdown code block decoded incorrectly: %+v", block)
	}
}

func TestDecodeAgentTranscriptRetainedBodyFields(t *testing.T) {
	assistant := []byte{0x02}
	assistant = binary.BigEndian.AppendUint32(assistant, uint32(len("hello")))
	assistant = append(assistant, []byte("hello")...)

	thinking := []byte{0x03, 1}
	thinking = append(thinking, u32Bytes(7)...)
	thinking = append(thinking, []byte("thought")...)

	system := []byte{0x05, 1}
	system = append(system, u32Bytes(3)...)
	system = append(system, []byte("sys")...)

	styledAssistant := []byte{0x07, 0, 1, 0, 1}
	styledAssistant = append(styledAssistant, string16("docs")...)
	styledAssistant = append(styledAssistant, 0x61, 0xAF, 0xFE, 0x21, 0x24, 0x2B, 0x08)
	styledAssistant = append(styledAssistant, string16("https://example.test")...)

	tool := []byte{0x04, 2, 1, 1}
	tool = append(tool, u32Bytes(25)...)
	tool = append(tool, string16("read_file")...)
	tool = append(tool, string16("lib/app.ex")...)
	tool = append(tool, u32Bytes(2)...)
	tool = append(tool, []byte("ok")...)
	tool = append(tool, 1, 3)
	tool = append(tool, []byte{0, 1}...)
	tool = append(tool, string16("lib/app.ex")...)

	styledTool := []byte{0x08, 1, 1, 1}
	styledTool = append(styledTool, u32Bytes(42)...)
	styledTool = append(styledTool, string16("shell")...)
	styledTool = append(styledTool, string16("ran")...)
	styledTool = append(styledTool, 0, 1, 0, 1)
	markdown := []byte{0x0A, 0, 1}
	markdown = append(markdown, u32Bytes(77)...)
	markdown = append(markdown, 0x07, 0x01)
	markdown = append(markdown, string16("elixir")...)
	markdown = append(markdown, string16("Demo")...)
	markdown = append(markdown, string16("lib/demo.ex")...)
	markdown = append(markdown, 0x01, 0, 1, 0, 1)
	markdown = append(markdown, string16("IO.inspect(:ok)")...)
	markdown = append(markdown, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x10)

	styledTool = append(styledTool, string16("done")...)
	styledTool = append(styledTool, 0x98, 0xBE, 0x65, 0x21, 0x24, 0x2B, 0x10)
	styledTool = append(styledTool, 2, 1)
	styledTool = append(styledTool, []byte{0, 1}...)
	styledTool = append(styledTool, string16("-old")...)

	approval := []byte{0x09, 1}
	approval = append(approval, string16("edit_file")...)
	approval = append(approval, string16("demo.ex")...)
	approval = append(approval, string16("tc_1")...)
	approval = append(approval, 2)
	approval = append(approval, []byte{0, 1}...)
	approval = append(approval, string16("mix test")...)

	usage := []byte{0x06}
	usage = append(usage, u32Bytes(10)...)
	usage = append(usage, u32Bytes(20)...)
	usage = append(usage, u32Bytes(3)...)
	usage = append(usage, u32Bytes(4)...)
	usage = append(usage, u32Bytes(500)...)

	got, _, _ := decodeAgentTranscript(replaceFrameBytes(11, false, []transcriptEntry{
		{id: 1, body: assistant},
		{id: 2, body: thinking},
		{id: 3, body: system},
		{id: 4, body: styledAssistant},
		{id: 5, body: tool},
		{id: 6, body: styledTool},
		{id: 7, body: approval},
		{id: 8, body: usage},
		{id: 9, body: markdown},
	}))
	if !got.Present || len(got.Messages) != 9 {
		t.Fatalf("retained bodies not decoded: %+v", got)
	}
	if got.Messages[0].Kind != 0x02 || got.Messages[0].Text != "hello" {
		t.Fatalf("assistant fields not retained: %+v", got.Messages[0])
	}
	if !got.Messages[1].Collapsed || got.Messages[1].Text != "thought" {
		t.Fatalf("thinking fields not retained: %+v", got.Messages[1])
	}
	if got.Messages[2].Status != 1 || got.Messages[2].Text != "sys" {
		t.Fatalf("system fields not retained: %+v", got.Messages[2])
	}
	if got.Messages[3].StyledLines[0][0].URL != "https://example.test" || got.Messages[3].StyledLines[0][0].Flags&0x08 == 0 {
		t.Fatalf("styled assistant link fields not retained: %+v", got.Messages[3].StyledLines)
	}
	if got.Messages[4].Name != "read_file" || got.Messages[4].Summary != "lib/app.ex" || got.Messages[4].Status != 2 || !got.Messages[4].IsError || !got.Messages[4].Collapsed || got.Messages[4].DurationMS != 25 || got.Messages[4].Result != "ok" || got.Messages[4].AutoApprovedScope != 1 || got.Messages[4].PreviewKind != 3 || got.Messages[4].PreviewLines[0] != "lib/app.ex" {
		t.Fatalf("tool fields not retained: %+v", got.Messages[4])
	}
	styledToolRun := got.Messages[5].StyledLines[0][0]
	if got.Messages[5].Name != "shell" || got.Messages[5].Summary != "ran" || got.Messages[5].Status != 1 || !got.Messages[5].IsError || !got.Messages[5].Collapsed || got.Messages[5].DurationMS != 42 || got.Messages[5].Result != "done" || got.Messages[5].AutoApprovedScope != 2 || got.Messages[5].PreviewKind != 1 || got.Messages[5].PreviewLines[0] != "-old" || styledToolRun.Text != "done" || styledToolRun.FG != 0x98BE65 || styledToolRun.BG != 0x21242B || !styledToolRun.Code() {
		t.Fatalf("styled tool fields not retained: %+v", got.Messages[5])
	}
	if got.Messages[6].Status != 1 || got.Messages[6].Name != "edit_file" || got.Messages[6].Summary != "demo.ex" || got.Messages[6].Result != "tc_1" || got.Messages[6].PreviewKind != 2 || got.Messages[6].PreviewLines[0] != "mix test" {
		t.Fatalf("approval fields not retained: %+v", got.Messages[6])
	}
	if got.Messages[7].Usage.Input != 10 || got.Messages[7].Usage.Output != 20 || got.Messages[7].Usage.CacheRead != 3 || got.Messages[7].Usage.CacheWrite != 4 || got.Messages[7].Usage.CostMicros != 500 {
		t.Fatalf("usage fields not retained: %+v", got.Messages[7])
	}
	markdownBlock := got.Messages[8].MarkdownBlocks[0]
	if markdownBlock.Kind != 0x07 || !markdownBlock.Complete() || markdownBlock.Language != "elixir" || markdownBlock.Label != "Demo" || markdownBlock.TargetPath != "lib/demo.ex" || markdownBlock.CapabilityFlags != 0x01 || markdownBlock.Lines[0][0].Text != "IO.inspect(:ok)" || markdownBlock.Lines[0][0].FG != 0x010203 || markdownBlock.Lines[0][0].BG != 0x040506 || !markdownBlock.Lines[0][0].Code() {
		t.Fatalf("markdown capability fields not retained: %+v", markdownBlock)
	}
}

func TestDecodeAgentTranscriptMalformedKnownBodyRejectsFrame(t *testing.T) {
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: []byte{0x01, 0, 0, 0, 5, 'h'}},
	})

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("malformed known body should reject whole frame")
	}
}

func TestDecodeAgentTranscriptTextTrailingByteRejectsFrame(t *testing.T) {
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: []byte{0x01, 0, 0, 0, 2, 'h', 'i', 0xFF}},
	})

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("known text body with trailing byte should reject whole frame")
	}
}

func TestDecodeAgentTranscriptAbsentStyledLineRejectsFrame(t *testing.T) {
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: []byte{0x07, 0, 1}},
	})

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("styled body missing declared line should reject whole frame")
	}
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

func TestDecodeAgentTranscriptTruncatedBodyRejectsFrame(t *testing.T) {
	// count claims 2 entries but only one full entry is present. The whole frame
	// must be rejected (Present=false): folding a PARTIAL delta would silently
	// corrupt the resident store, which is worse than skipping the frame and
	// letting the next full_replace resync.
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: userBody("only")},
	})
	// Bump the count field. Offset: opcode(1)+len(4)+version(1)+mode(1)+epoch(4)+
	// truncated(1) = 12 for a full_replace frame.
	binary.BigEndian.PutUint32(frame[12:], 2)

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("truncated frame should be rejected, got Present with %d messages", len(got.Messages))
	}
}

func TestDecodeAgentTranscriptUnknownModeRejected(t *testing.T) {
	// Only modes 0 (full_replace) and 1 (append) exist. An unknown mode must be
	// rejected at decode: the decoder's layout branch is append-shaped (mode==1)
	// while the store's apply branch is full_replace-shaped (mode==0), so a mode
	// that passed through would be parsed with one layout and applied with the
	// other (split-brain).
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: userBody("hi")},
	})
	// mode byte offset: opcode(1)+len(4)+version(1) = 6.
	frame[6] = 2

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("unknown mode should be rejected, got Present")
	}
}

func TestDecodeAgentTranscriptUnknownVersionRejected(t *testing.T) {
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: userBody("hi")},
	})
	// version byte offset: opcode(1)+len(4) = 5.
	frame[5] = 9

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("unknown version should be rejected, got Present")
	}
}

func TestDecodeAgentTranscriptHugeCountRejected(t *testing.T) {
	// A corrupt count far beyond what the payload could hold must be rejected
	// cleanly rather than sized into a giant allocation.
	frame := replaceFrameBytes(1, false, []transcriptEntry{
		{id: 1, body: userBody("only")},
	})
	binary.BigEndian.PutUint32(frame[12:], 0xFFFF_FFFF)

	got, _, _ := decodeAgentTranscript(frame)
	if got.Present {
		t.Fatalf("huge count should be rejected, got Present")
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
