package ui

import (
	"fmt"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

var transcriptBenchmarkView string

func transcriptBenchmarkModel(tb testing.TB, count int) Model {
	return transcriptBenchmarkModelAtPosition(tb, count, true)
}

func transcriptBenchmarkModelAtPosition(tb testing.TB, count int, scrolled bool) Model {
	tb.Helper()
	model := New(80, 30, nil)
	messages := make([]protocol.AgentChatMessage, count)
	for index := range messages {
		messages[index] = protocol.AgentChatMessage{
			ID:   uint32(index + 1),
			Kind: agentKindUser,
			Text: fmt.Sprintf("MESSAGE_%05d %s", index, stringsOfLength(180)),
		}
	}
	commands := []protocol.Command{
		beginFrame(1, 0),
		testThemeCommand(),
		{Kind: protocol.CommandChrome, Chrome: protocol.ChromePayload{Opcode: generated.OPGuiAgentChat, AgentChat: visibleAgentChat()}},
		transcriptCommand(replaceFrame(1, messages...)),
		commitFrame(1),
	}
	updated, _ := model.Update(port.PacketMsg{Commands: commands})
	model = updated.(Model)
	if scrolled {
		model.transcript.scrollBy(-1 << 20)
	}
	updated, _ = model.Update(port.PacketMsg{Commands: []protocol.Command{beginFrame(2, 1), commitFrame(2)}})
	model = updated.(Model)
	transcriptBenchmarkView = model.View().Content
	return model
}

func BenchmarkTranscriptPinnedWarmUpdateView(b *testing.B) {
	model := transcriptBenchmarkModelAtPosition(b, 10_000, false)
	seq := uint32(3)
	base := uint32(2)
	b.ReportAllocs()
	b.ResetTimer()
	for iteration := 0; iteration < b.N; iteration++ {
		updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{beginFrame(seq, base), commitFrame(seq)}})
		model = updated.(Model)
		transcriptBenchmarkView = model.View().Content
		base = seq
		seq++
	}
}

func stringsOfLength(length int) string {
	bytes := make([]byte, length)
	for index := range bytes {
		bytes[index] = 'x'
	}
	return string(bytes)
}

// BenchmarkTranscriptWarmUpdateView measures the real empty-delta Update plus
// View path while the reader is away from the bottom. Full replacement setup is
// outside the timed region because installing N semantic records is a distinct
// payload cost, not transcript layout work.
func BenchmarkTranscriptWarmUpdateView(b *testing.B) {
	for _, count := range []int{100, 1_000, 10_000} {
		b.Run(fmt.Sprintf("messages_%d", count), func(b *testing.B) {
			model := transcriptBenchmarkModel(b, count)
			seq := uint32(3)
			base := uint32(2)
			b.ReportAllocs()
			b.ResetTimer()
			for iteration := 0; iteration < b.N; iteration++ {
				updated, _ := model.Update(port.PacketMsg{Commands: []protocol.Command{beginFrame(seq, base), commitFrame(seq)}})
				model = updated.(Model)
				transcriptBenchmarkView = model.View().Content
				base = seq
				seq++
			}
		})
	}
}

func BenchmarkTranscriptOwnerPrepare(b *testing.B) {
	for _, count := range []int{100, 1000, 10000} {
		for _, mode := range []string{"delta", "full_incoming"} {
			b.Run(fmt.Sprintf("%s/%d", mode, count), func(b *testing.B) {
				messages := make([]protocol.AgentChatMessage, count)
				for index := range messages {
					messages[index] = msg(uint32(index+1), "resident payload")
				}
				tr := testTranscriptWithMessages(messages)
				frame := appendFrame(1, 1, uint32(count-2), msg(uint32(count), "tail"), msg(uint32(count+1), "new"))
				if mode == "full_incoming" {
					frame = replaceFrame(1, messages...)
				}
				b.ReportAllocs()
				b.ResetTimer()
				var changed int
				for range b.N {
					plan := tr.prepare()
					if reason := plan.apply(frame); reason != transcriptApplied {
						b.Fatal(reason)
					}
					changed = len(plan.cells)
				}
				b.ReportMetric(float64(changed), "changed_cells/op")
			})
		}
	}
}
