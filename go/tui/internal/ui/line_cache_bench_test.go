package ui

import (
	"fmt"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/port"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// largeFrameModel builds a model with one window filling a 220x60 terminal,
// committed through the real frame transaction path, so a compose exercises the
// full body render. rowCount rows each have a stable id+hash so they are
// cacheable.
func largeFrameModel(b *testing.B, width, height, rowCount int) Model {
	b.Helper()
	m := New(uint16(width), uint16(height), nil)
	rows := make([]protocol.WindowRow, rowCount)
	for i := range rows {
		rows[i] = protocol.WindowRow{
			ID:          uint64(i + 1),
			ContentHash: uint32(1000 + i),
			Text:        fmt.Sprintf("line %4d  func example(arg int) (string, error) { return \"x\", nil }", i),
		}
	}
	window := protocol.WindowContent{ID: 1, CursorVisible: true, ContentEpoch: 1, Rows: rows}
	updated, _ := m.Update(port.PacketMsg{Commands: fullWindowFrame(1, window)})
	return updated.(Model)
}

// BenchmarkComposeFullRecompose measures the full-recompose cost: the cache is
// cleared before every compose, so every body line runs the lipgloss tree. This
// is the pre-#2288 baseline cost on a 220x60 frame.
func BenchmarkComposeFullRecompose(b *testing.B) {
	m := largeFrameModel(b, 220, 60, 60)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		m.lineCache.reset()
		_ = m.content()
	}
}

// BenchmarkComposeWarmCacheAllRefs measures the patched-compose cost when every
// row is an unchanged ref: the cache is warm and every body line is a hit. This
// is the steady-state cost the #2288 line cache delivers.
func BenchmarkComposeWarmCacheAllRefs(b *testing.B) {
	m := largeFrameModel(b, 220, 60, 60)
	_ = m.content() // warm the cache once
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = m.content()
	}
}

// BenchmarkComposeWarmCacheOneDirtyRow measures the realistic keystroke case:
// one row changed, the rest are cache hits. This is what a single edit costs on
// a 220x60 frame with the line cache.
func BenchmarkComposeWarmCacheOneDirtyRow(b *testing.B) {
	m := largeFrameModel(b, 220, 60, 60)
	_ = m.content() // warm

	dirtyHash := uint32(0)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		// Mutate one row's hash so exactly one line misses the cache, like a
		// single-line edit delivered as a delta-with-refs frame.
		dirtyHash++
		win := m.windows[1]
		win.Rows[30].ContentHash = 9_000_000 + dirtyHash
		m.windows[1] = win
		_ = m.content()
	}
}
