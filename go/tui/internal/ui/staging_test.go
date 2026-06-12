package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// beginFrame builds a begin_frame command for a transaction (#2219).
func beginFrame(seq, base uint32) protocol.Command {
	return protocol.Command{Kind: protocol.CommandBeginFrame, FrameSeq: seq, BaseFrameSeq: base}
}

// commitFrame builds a commit_frame command for a transaction (#2219).
func commitFrame(seq uint32) protocol.Command {
	return protocol.Command{Kind: protocol.CommandCommitFrame, FrameSeq: seq}
}

// windowRowsCommand builds a full window-content command carrying a single row
// of text, so a test can prove whether that text reached the rendered View.
func windowRowsCommand(id uint16, text string) protocol.Command {
	return protocol.Command{Kind: protocol.CommandWindowContent, Window: protocol.WindowContent{
		ID:            id,
		CursorVisible: true,
		Rows:          []protocol.WindowRow{{Text: text}},
	}}
}

func renderedBody(model Model) string {
	return ansi.Strip(model.View().Content)
}

// drainKeyframeRequests reports how many request_keyframe (0x08) packets and the
// last_good_frame_seq they carried were written to the out channel.
func drainKeyframeRequests(t *testing.T, out chan []byte) []uint32 {
	t.Helper()
	var seqs []uint32
	for _, packet := range drainOutboundPackets(out) {
		if seq, ok := decodeKeyframeRequest(packet); ok {
			seqs = append(seqs, seq)
		}
	}
	return seqs
}

func drainOutboundPackets(out chan []byte) [][]byte {
	var packets [][]byte
	for {
		select {
		case packet := <-out:
			packets = append(packets, packet)
		default:
			return packets
		}
	}
}

func decodeKeyframeRequest(packet []byte) (uint32, bool) {
	if len(packet) != 5 || packet[0] != generated.OPRequestKeyframe {
		return 0, false
	}
	return uint32(packet[1])<<24 | uint32(packet[2])<<16 | uint32(packet[3])<<8 | uint32(packet[4]), true
}

func decodeLogMessage(packet []byte) (byte, string, bool) {
	if len(packet) < 4 || packet[0] != generated.OPLogMessage {
		return 0, "", false
	}
	msgLen := int(packet[2])<<8 | int(packet[3])
	if len(packet) != 4+msgLen {
		return 0, "", false
	}
	return packet[1], string(packet[4:]), true
}

func applyTo(t *testing.T, model Model, commands ...protocol.Command) Model {
	t.Helper()
	updated, _ := model.Update(port.PacketMsg{Commands: commands})
	return updated.(Model)
}

// Stale in-flight frames after an invalidation each fail their base check,
// but only the FIRST invalidation sends request_keyframe; the rest discard
// silently until a valid commit clears the pending flag (#2266 review).
func TestInvalidationDebouncesKeyframeRequests(t *testing.T) {
	out := make(chan []byte, 8)
	m := New(80, 24, out)

	// First invalidation: commit with no open transaction.
	m = applyTo(t, m, commitFrame(7))
	if seqs := drainKeyframeRequests(t, out); len(seqs) != 1 {
		t.Fatalf("first invalidation should send one request_keyframe, got %d", len(seqs))
	}

	// Stale in-flight frame: base mismatch while resync is already pending.
	m = applyTo(t, m, beginFrame(8, 7), windowRowsCommand(1, "stale"), commitFrame(8))
	if seqs := drainKeyframeRequests(t, out); len(seqs) != 0 {
		t.Fatalf("pending resync must not re-request, got %d", len(seqs))
	}

	// The keyframe arrives and commits: pending clears, content applies.
	m = applyTo(t, m, beginFrame(9, 0), testThemeCommand(), windowRowsCommand(1, "fresh"), commitFrame(9))
	if m.resyncPending {
		t.Fatal("valid commit should clear resyncPending")
	}
	if !strings.Contains(renderedBody(m), "fresh") {
		t.Fatal("keyframe content should render after commit")
	}
}

func TestInvalidationLogsToMessagesAndDebouncesDiagnostics(t *testing.T) {
	out := make(chan []byte, 8)
	m := New(80, 24, out)

	m = applyTo(t, m, commitFrame(7))
	packets := drainOutboundPackets(out)

	var logs []string
	var keyframes []uint32
	for _, packet := range packets {
		if seq, ok := decodeKeyframeRequest(packet); ok {
			keyframes = append(keyframes, seq)
		}
		if level, text, ok := decodeLogMessage(packet); ok {
			if level != protocol.LogLevelWarn {
				t.Fatalf("invalidation log level = %d, want warn", level)
			}
			logs = append(logs, text)
		}
	}

	if len(keyframes) != 1 || keyframes[0] != 0 {
		t.Fatalf("first invalidation should request keyframe from last good seq 0, got %v", keyframes)
	}
	if len(logs) != 1 {
		t.Fatalf("first invalidation should send one log_message, got %d", len(logs))
	}
	if !strings.Contains(logs[0], "Go TUI frame invalidated (commit_frame with no open transaction)") {
		t.Fatalf("invalidation log should explain the reason, got %q", logs[0])
	}

	m = applyTo(t, m, beginFrame(8, 7), windowRowsCommand(1, "stale"), commitFrame(8))
	if packets := drainOutboundPackets(out); len(packets) != 0 {
		t.Fatalf("pending resync should debounce duplicate keyframe requests and logs, got %d packets", len(packets))
	}
}

// AC-3: a begin + partial content leaves View() output unchanged until commit.

func TestStagingDoesNotPaintBeforeCommit(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)

	// Commit a first keyframe so there is a known baseline frame on screen.
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), windowRowsCommand(1, "committed line"), commitFrame(1))
	before := renderedBody(model)
	if !strings.Contains(before, "committed line") {
		t.Fatalf("baseline frame should render committed content: %q", before)
	}

	// Open a new transaction and feed partial content WITHOUT committing.
	model = applyTo(t, model, beginFrame(2, 1), windowRowsCommand(1, "staged but uncommitted"))

	mid := renderedBody(model)
	if strings.Contains(mid, "staged but uncommitted") {
		t.Fatalf("uncommitted staged content must not paint: %q", mid)
	}
	if mid != before {
		t.Fatalf("View output changed before commit:\n before=%q\n after =%q", before, mid)
	}
	if reqs := drainKeyframeRequests(t, out); len(reqs) != 0 {
		t.Fatalf("a healthy open transaction must not request a keyframe: %v", reqs)
	}
}

// AC-3: commit applies the staged frame atomically.
func TestStagingAppliesAtomicallyOnCommit(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(1, 0), testThemeCommand(), windowRowsCommand(1, "first frame"), commitFrame(1))

	// Stage the next frame across two separate packets, committing only at the end.
	model = applyTo(t, model, beginFrame(2, 1), windowRowsCommand(1, "second frame"))
	if got := renderedBody(model); strings.Contains(got, "second frame") {
		t.Fatalf("content must not paint mid-transaction: %q", got)
	}
	model = applyTo(t, model, commitFrame(2))

	got := renderedBody(model)
	if !strings.Contains(got, "second frame") {
		t.Fatalf("commit should apply the staged frame: %q", got)
	}
	if strings.Contains(got, "first frame") {
		t.Fatalf("committed frame should replace the prior content: %q", got)
	}
	if got := model.lastCommittedSeq; got != 2 {
		t.Fatalf("lastCommittedSeq = %d, want 2", got)
	}
}

// AC-3: a truncated transaction (new begin before commit) requests a keyframe and
// does NOT partially paint; the prior committed frame stays on screen.
func TestTruncatedTransactionRequestsKeyframeAndKeepsPriorFrame(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(7, 0), testThemeCommand(), windowRowsCommand(1, "good frame"), commitFrame(7))
	drainKeyframeRequests(t, out) // clear

	// Open a transaction, feed content, then open ANOTHER begin before committing.
	model = applyTo(t, model, beginFrame(8, 7), windowRowsCommand(1, "doomed partial"), beginFrame(9, 7))

	got := renderedBody(model)
	if strings.Contains(got, "doomed partial") {
		t.Fatalf("truncated transaction must not paint partial content: %q", got)
	}
	if !strings.Contains(got, "good frame") {
		t.Fatalf("prior committed frame should remain on screen: %q", got)
	}
	reqs := drainKeyframeRequests(t, out)
	if len(reqs) != 1 || reqs[0] != 7 {
		t.Fatalf("truncation should request a keyframe from last good seq 7, got %v", reqs)
	}
	if !model.resyncPending {
		t.Fatal("model should mark resync pending after truncation")
	}
}

// AC-3: a malformed transaction (stream error inside it) requests a keyframe and
// keeps the prior frame.
func TestStreamErrorInsideTransactionRequestsKeyframe(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(3, 0), testThemeCommand(), windowRowsCommand(1, "stable"), commitFrame(3))
	drainKeyframeRequests(t, out)

	// The reader appends CommandStreamError at the failure point and stops, so no
	// commit_frame follows it in the batch.
	model = applyTo(t, model,
		beginFrame(4, 3),
		windowRowsCommand(1, "partial then garbage"),
		protocol.Command{Kind: protocol.CommandStreamError},
	)

	got := renderedBody(model)
	if strings.Contains(got, "partial then garbage") {
		t.Fatalf("a stream error must abort the transaction without painting: %q", got)
	}
	if !strings.Contains(got, "stable") {
		t.Fatalf("prior committed frame should remain: %q", got)
	}
	reqs := drainKeyframeRequests(t, out)
	if len(reqs) != 1 || reqs[0] != 3 {
		t.Fatalf("stream error should request keyframe from seq 3, got %v", reqs)
	}
}

// A stream error OUTSIDE any transaction is harmless (transport survivor) and
// must not request a keyframe.
func TestStreamErrorOutsideTransactionIsHarmless(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, protocol.Command{Kind: protocol.CommandStreamError})
	if reqs := drainKeyframeRequests(t, out); len(reqs) != 0 {
		t.Fatalf("out-of-band stream error must not request a keyframe: %v", reqs)
	}
}

// AC-2: a commit whose seq does not match the open begin requests a keyframe.
func TestCommitSeqMismatchRequestsKeyframe(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(10, 0), testThemeCommand(), windowRowsCommand(1, "base"), commitFrame(10))
	drainKeyframeRequests(t, out)

	model = applyTo(t, model, beginFrame(11, 10), windowRowsCommand(1, "mismatch"), commitFrame(99))

	if got := renderedBody(model); strings.Contains(got, "mismatch") {
		t.Fatalf("a seq-mismatched commit must not apply staged content: %q", got)
	}
	reqs := drainKeyframeRequests(t, out)
	if len(reqs) != 1 || reqs[0] != 10 {
		t.Fatalf("seq mismatch should request keyframe from seq 10, got %v", reqs)
	}
	if model.lastCommittedSeq != 10 {
		t.Fatalf("lastCommittedSeq should stay at 10 after a rejected commit, got %d", model.lastCommittedSeq)
	}
}

// AC-2: a delta transaction whose base does not match the last committed frame
// requests a keyframe.
func TestBaseMismatchRequestsKeyframe(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(20, 0), testThemeCommand(), windowRowsCommand(1, "committed"), commitFrame(20))
	drainKeyframeRequests(t, out)

	// base 19 was never committed (last good is 20) -> base mismatch.
	model = applyTo(t, model, beginFrame(21, 19), windowRowsCommand(1, "bad base"), commitFrame(21))

	if got := renderedBody(model); strings.Contains(got, "bad base") {
		t.Fatalf("a base-mismatched transaction must not apply: %q", got)
	}
	reqs := drainKeyframeRequests(t, out)
	if len(reqs) != 1 || reqs[0] != 20 {
		t.Fatalf("base mismatch should request keyframe from seq 20, got %v", reqs)
	}
}

// AC-2: the resync indicator shows after a drop and clears when a valid keyframe
// commits.
func TestResyncIndicatorShowsThenClearsOnKeyframe(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(30, 0), testThemeCommand(), windowRowsCommand(1, "ok"), commitFrame(30))

	// Force an invalidation (double begin).
	model = applyTo(t, model, beginFrame(31, 30), beginFrame(32, 30))
	if !model.resyncPending {
		t.Fatal("resyncPending should be set after a drop")
	}
	footer := ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if !strings.Contains(footer, "resync") {
		t.Fatalf("footer should surface a resync indicator: %q", footer)
	}

	// A valid keyframe (base 0) arrives and commits -> indicator clears.
	model = applyTo(t, model, beginFrame(40, 0), testThemeCommand(), windowRowsCommand(1, "recovered"), commitFrame(40))
	if model.resyncPending {
		t.Fatal("resyncPending should clear after a valid commit")
	}
	footer = ansi.Strip(strings.Join(model.footerLines(), "\n"))
	if strings.Contains(footer, "resync") {
		t.Fatalf("resync indicator should clear after recovery: %q", footer)
	}
	if got := renderedBody(model); !strings.Contains(got, "recovered") {
		t.Fatalf("recovered keyframe should render: %q", got)
	}
}

// Out-of-band allowance: set_title / set_window_bg arriving with no open
// transaction apply directly (sanctioned side channels) and do NOT request a
// keyframe.
func TestOutOfBandSideChannelsApplyWithoutTransaction(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)

	model = applyTo(t, model,
		protocol.Command{Kind: protocol.CommandSetTitle, Title: "minga - file.ex"},
		protocol.Command{Kind: protocol.CommandSetWindowBg, WindowBg: 0x112233},
	)

	if model.title != "minga - file.ex" {
		t.Fatalf("out-of-band set_title should apply directly, got %q", model.title)
	}
	if model.bg != 0x112233 {
		t.Fatalf("out-of-band set_window_bg should apply directly, got 0x%06X", model.bg)
	}
	if reqs := drainKeyframeRequests(t, out); len(reqs) != 0 {
		t.Fatalf("sanctioned out-of-band commands must not request a keyframe: %v", reqs)
	}
}

// A semantic command with no open transaction is a protocol violation under the
// staged model: it must NOT apply and must request a keyframe.
func TestSemanticCommandOutsideTransactionRequestsKeyframe(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	model = applyTo(t, model, beginFrame(50, 0), testThemeCommand(), windowRowsCommand(1, "committed"), commitFrame(50))
	drainKeyframeRequests(t, out)

	model = applyTo(t, model, windowRowsCommand(1, "stray semantic"))

	if got := renderedBody(model); strings.Contains(got, "stray semantic") {
		t.Fatalf("a stray out-of-transaction semantic command must not paint: %q", got)
	}
	reqs := drainKeyframeRequests(t, out)
	if len(reqs) != 1 || reqs[0] != 50 {
		t.Fatalf("stray semantic command should request keyframe from seq 50, got %v", reqs)
	}
}

// Latency resolves at commit, not at begin: a stamped sequence echoed on
// commit_frame produces a sample.
func TestLatencyResolvesOnCommit(t *testing.T) {
	out := make(chan []byte, 16)
	model := New(40, 8, out)
	seq := model.latency.Stamp()

	model = applyTo(t, model, beginFrame(60, 0), testThemeCommand(), windowRowsCommand(1, "frame"))
	if model.latency.Snapshot().Resolved != 0 {
		t.Fatal("latency must not resolve before commit")
	}

	commit := commitFrame(60)
	commit.InputSeq = seq
	model = applyTo(t, model, commit)
	if model.latency.Snapshot().Resolved != 1 {
		t.Fatalf("commit_frame should resolve the latency sample, resolved=%d", model.latency.Snapshot().Resolved)
	}
}
