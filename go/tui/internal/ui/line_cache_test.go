package ui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// fullWindowFrame stages a full window-content command inside a fresh frame
// transaction (begin/commit) so it commits through the real apply path the way
// the BEAM delivers it. base 0 makes it a keyframe (always valid).
func fullWindowFrame(seq uint32, window protocol.WindowContent) []protocol.Command {
	return []protocol.Command{
		beginFrame(seq, 0),
		{Kind: protocol.CommandWindowContent, Window: window},
		commitFrame(seq),
	}
}

// deltaWindowFrame stages a window-delta command inside a delta transaction
// (base = prior seq) so ref rows resolve against the committed window.
func deltaWindowFrame(seq, base uint32, window protocol.WindowContent) []protocol.Command {
	return []protocol.Command{
		beginFrame(seq, base),
		{Kind: protocol.CommandWindowDelta, Window: window},
		commitFrame(seq),
	}
}

// frameCounters returns the cache hit/miss counts of the compose that ran
// during the model's last Update (composeBody records them and leaves them set
// until the next compose). This is the real per-frame measurement: the refs of
// a just-applied delta hit the cache state that existed before the delta.
func frameCounters(m Model) (hits, misses uint64) {
	return m.lineCache.takeCounters()
}

// recomposeCounters drives one fresh compose over the current model state and
// returns its hit/miss counts. The first call after a state change warms the
// cache; a second call is fully warm. Useful for asserting cold vs warm.
func recomposeCounters(m Model) (hits, misses uint64) {
	m.lineCache.resetCounters()
	_ = m.content()
	return m.lineCache.takeCounters()
}

// AC 1: a full-row frame recomposes every row (all misses), then a delta frame
// whose rows are refs reuses the cached lines (hits) and only recomposes the
// rows that arrived with full content (misses).
func TestLineCacheCountsHitsForRefRowsAndMissesForFullRows(t *testing.T) {
	m := New(80, 24, nil)

	window := protocol.WindowContent{
		ID:            1,
		CursorVisible: true,
		ContentEpoch:  1,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "line one"},
			{ID: 2, ContentHash: 22, Text: "line two"},
			{ID: 3, ContentHash: 33, Text: "line three"},
		},
	}
	m = applyTo(t, m, fullWindowFrame(1, window)...)

	// The committed frame's own compose ran against a cold cache: every row is
	// a miss.
	if hits, misses := frameCounters(m); hits != 0 || misses != 3 {
		t.Fatalf("cold full frame: hits=%d misses=%d, want 0/3", hits, misses)
	}

	// A fresh recompose with no state change is all hits: the rows are
	// unchanged so every line is served from the cache.
	if hits, misses := recomposeCounters(m); hits != 3 || misses != 0 {
		t.Fatalf("warm recompose: hits=%d misses=%d, want 3/0", hits, misses)
	}

	// Delta frame: rows 1 and 3 are refs (unchanged), row 2 arrives full.
	delta := protocol.WindowContent{
		ID:           1,
		ContentEpoch: 1,
		Rows: []protocol.WindowRow{
			{Ref: true, ID: 1, ContentHash: 11},
			{ID: 2, ContentHash: 44, Text: "line two edited"},
			{Ref: true, ID: 3, ContentHash: 33},
		},
	}
	m = applyTo(t, m, deltaWindowFrame(2, 1, delta)...)

	// The delta frame's own compose: two ref rows hit the cache warmed by the
	// prior frame, the one full row is a miss.
	if hits, misses := frameCounters(m); hits != 2 || misses != 1 {
		t.Fatalf("delta-with-refs frame: hits=%d misses=%d, want 2/1", hits, misses)
	}
}

// The per-window row map must stay bounded at the rendered row count even
// across a long scroll, where the BEAM re-emits a stable row (same row_id and
// content_hash) at a shifted viewport index. Because the cache key includes the
// row index, a scrolled row lands under a new key while its old-index key would
// otherwise linger forever. The per-frame rebuild discards keys not rendered
// this frame, so the map equals the viewport size, not the accumulated total of
// every (id, hash, index) ever seen.
func TestLineCacheMapStaysBoundedAcrossScroll(t *testing.T) {
	const viewport = 20 // rows visible at once
	const buffer = 200  // total rows in the file
	m := New(80, uint16(viewport+4), nil)

	// A buffer line's stable wire identity: scrolling never changes a line's
	// id/hash, only its viewport index, so the same row keeps the same key parts
	// except rowIndex.
	bufRow := func(bufLine int) protocol.WindowRow {
		return protocol.WindowRow{
			ID:          uint64(bufLine + 1),
			ContentHash: uint32(1000 + bufLine),
			Text:        "buffer line " + strings.Repeat("x", bufLine%7),
		}
	}
	geom := protocol.PaneGeometry{ViewportRows: uint16(viewport)}

	// Initial keyframe: the top viewport [0, viewport).
	firstRows := make([]protocol.WindowRow, viewport)
	for i := range firstRows {
		firstRows[i] = bufRow(i)
	}
	m = applyTo(t, m, fullWindowFrame(1, protocol.WindowContent{
		ID: 1, CursorVisible: true, ContentEpoch: 1, Geometry: geom, GeometrySet: true, Rows: firstRows,
	})...)

	// Scroll down one buffer line at a time via delta-with-refs frames (base !=
	// 0, so the cache is kept, exactly how the BEAM expresses a vertical scroll).
	// Each delta re-emits the visible rows: the carried-over rows are refs (same
	// id/hash, now one index higher in the previous window's resolved set), and
	// the newly revealed bottom row arrives full. Every carried row's viewport
	// index shifts, so under the pre-fix unbounded cache the window map would
	// accumulate one entry per (id, hash, index) pair seen across the whole
	// scroll (~buffer * viewport entries) instead of staying at viewport size.
	seq := uint32(1)
	for top := 1; top <= buffer-viewport; top++ {
		seq++
		rows := make([]protocol.WindowRow, viewport)
		for i := 0; i < viewport; i++ {
			bl := top + i
			if i < viewport-1 {
				// Carried over from the prior viewport: emit as a ref.
				rows[i] = protocol.WindowRow{Ref: true, ID: uint64(bl + 1), ContentHash: uint32(1000 + bl)}
			} else {
				// Newly revealed bottom line: full row.
				rows[i] = bufRow(bl)
			}
		}
		m = applyTo(t, m, deltaWindowFrame(seq, seq-1, protocol.WindowContent{
			ID: 1, ContentEpoch: 1, Geometry: geom, GeometrySet: true, Rows: rows,
		})...)
	}

	entry, ok := m.lineCache.windows[1]
	if !ok {
		t.Fatal("expected a cached entry for window 1")
	}
	got := len(entry.rows)
	if got != viewport {
		t.Fatalf("window map size = %d after scrolling a %d-row buffer; want exactly %d (the rendered row count), not the accumulated total", got, buffer, viewport)
	}
}

// AC 4 (make-or-break): the patched output must be byte-identical to a
// from-scratch full composition for the same model state. After a delta frame
// patches cached lines, resetting the cache and recomposing from scratch must
// produce exactly the same body string.
func TestLineCachePatchedOutputEqualsFullRecompose(t *testing.T) {
	build := func() Model {
		m := New(120, 40, nil)
		window := protocol.WindowContent{
			ID:            1,
			CursorVisible: true,
			ContentEpoch:  1,
			Cursorline:    protocol.Cursorline{Visible: true, Row: 1, BG: 0x223344},
			Rows: []protocol.WindowRow{
				{ID: 1, ContentHash: 11, Text: "alpha beta gamma"},
				{ID: 2, ContentHash: 22, Text: "delta epsilon zeta"},
				{ID: 3, ContentHash: 33, Text: "eta theta iota"},
				{ID: 4, ContentHash: 44, Text: "kappa lambda mu"},
			},
		}
		m = applyTo(t, m, fullWindowFrame(1, window)...)
		delta := protocol.WindowContent{
			ID:           1,
			ContentEpoch: 1,
			Cursorline:   protocol.Cursorline{Visible: true, Row: 1, BG: 0x223344},
			Rows: []protocol.WindowRow{
				{Ref: true, ID: 1, ContentHash: 11},
				{ID: 2, ContentHash: 55, Text: "delta EDITED zeta"},
				{Ref: true, ID: 3, ContentHash: 33},
				{Ref: true, ID: 4, ContentHash: 44},
			},
		}
		return applyTo(t, m, deltaWindowFrame(2, 1, delta)...)
	}

	patched := build()
	patchedBody := patched.content()
	// Confirm the patch path actually served hits, otherwise the equivalence
	// claim is vacuous (it would just be two full recomposes).
	if hits, _ := frameCounters(patched); hits == 0 {
		t.Fatal("expected the patch path to serve cache hits; test would be vacuous")
	}

	// From-scratch composition of the identical final state: drop the cache so
	// every line is recomposed by the full lipgloss path.
	fresh := build()
	fresh.lineCache.reset()
	fullBody := fresh.content()

	if patchedBody != fullBody {
		t.Fatalf("patched output diverged from full recompose:\npatched=%q\nfull   =%q", patchedBody, fullBody)
	}
}

// AC 4, broader: across a sequence of edits (each a delta touching one row),
// the patched body must always equal a from-scratch recompose of the same
// committed state.
func TestLineCacheEquivalenceAcrossEditSequence(t *testing.T) {
	m := New(100, 30, nil)
	rows := []protocol.WindowRow{
		{ID: 1, ContentHash: 100, Text: "func main() {"},
		{ID: 2, ContentHash: 200, Text: "  fmt.Println(\"hi\")"},
		{ID: 3, ContentHash: 300, Text: "}"},
	}
	m = applyTo(t, m, fullWindowFrame(1, protocol.WindowContent{ID: 1, CursorVisible: true, ContentEpoch: 1, Rows: rows})...)

	edits := []struct {
		hash uint32
		text string
	}{
		{210, "  fmt.Println(\"hi there\")"},
		{220, "  fmt.Println(\"hello\")"},
		{230, "  fmt.Println(\"hello world\")"},
	}
	seq := uint32(1)
	for _, edit := range edits {
		seq++
		delta := protocol.WindowContent{
			ID:           1,
			ContentEpoch: 1,
			Rows: []protocol.WindowRow{
				{Ref: true, ID: 1, ContentHash: 100},
				{ID: 2, ContentHash: edit.hash, Text: edit.text},
				{Ref: true, ID: 3, ContentHash: 300},
			},
		}
		m = applyTo(t, m, deltaWindowFrame(seq, seq-1, delta)...)

		patchedBody := m.content()
		fresh := m
		fresh.lineCache = newLineCache()
		if patchedBody != fresh.content() {
			t.Fatalf("edit %q: patched body diverged from full recompose", edit.text)
		}
	}
}

// AC 2: a resize invalidates the cache and takes the full composition path. The
// first compose after resize is all misses (cold cache) at the new width.
func TestLineCacheResizeInvalidatesCache(t *testing.T) {
	m := New(80, 24, nil)
	window := protocol.WindowContent{
		ID:            1,
		CursorVisible: true,
		ContentEpoch:  1,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "one"},
			{ID: 2, ContentHash: 22, Text: "two"},
		},
	}
	m = applyTo(t, m, fullWindowFrame(1, window)...)
	// Warm the cache: a fresh recompose with no change is all hits.
	if hits, misses := recomposeCounters(m); hits != 2 || misses != 0 {
		t.Fatalf("cache failed to warm: hits=%d misses=%d, want 2/0", hits, misses)
	}

	updated, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	m = updated.(Model)

	// The resize Update's own compose ran against a cleared cache: all misses.
	if hits, misses := frameCounters(m); hits != 0 || misses != 2 {
		t.Fatalf("post-resize compose: hits=%d misses=%d, want 0/2 (cache cleared)", hits, misses)
	}
}

// AC 5: a keyframe (base_frame_seq=0) fully resets the cache along with the rest
// of the staged state. A delta that edits a row, then a keyframe carrying fresh
// content for the same row IDs, must recompose every row (cold cache) and the
// rendered body must reflect the keyframe content with no stale lines.
func TestLineCacheKeyframeResetsCache(t *testing.T) {
	m := New(80, 24, nil)
	window := protocol.WindowContent{
		ID:            1,
		CursorVisible: true,
		ContentEpoch:  1,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "stale one"},
			{ID: 2, ContentHash: 22, Text: "stale two"},
		},
	}
	m = applyTo(t, m, fullWindowFrame(1, window)...)
	// Warm the cache so it holds the stale lines.
	if hits, _ := recomposeCounters(m); hits == 0 {
		t.Fatal("cache failed to warm before keyframe")
	}

	// Keyframe (base 0) resync with fresh content reusing the same row IDs.
	keyframe := protocol.WindowContent{
		ID:            1,
		CursorVisible: true,
		ContentEpoch:  2,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "fresh one"},
			{ID: 2, ContentHash: 22, Text: "fresh two"},
		},
	}
	m = applyTo(t, m, fullWindowFrame(7, keyframe)...)

	// The keyframe reset means its own compose is all misses (cold cache),
	// even though the row IDs and hashes repeat from the pre-resync frame.
	if hits, misses := frameCounters(m); hits != 0 || misses != 2 {
		t.Fatalf("post-keyframe compose: hits=%d misses=%d, want 0/2 (cache reset)", hits, misses)
	}

	// And no stale line survives: the rendered body shows the fresh content.
	body := renderedBody(m)
	if !strings.Contains(body, "fresh one") || !strings.Contains(body, "fresh two") {
		t.Fatalf("keyframe content missing from body: %q", body)
	}
	if strings.Contains(body, "stale one") || strings.Contains(body, "stale two") {
		t.Fatalf("stale cached line survived keyframe reset: %q", body)
	}
}

// A theme change must invalidate cached lines even though the rows are
// unchanged refs, because the rendered colors depend on the palette (AC 2,
// chrome-state-changed path). The context fingerprint folds the palette in, so
// the post-theme compose recomposes rather than serving stale-colored lines.
func TestLineCacheThemeChangeInvalidatesViaFingerprint(t *testing.T) {
	m := New(80, 24, nil)
	window := protocol.WindowContent{
		ID:            1,
		CursorVisible: true,
		ContentEpoch:  1,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "colored"},
		},
	}
	m = applyTo(t, m, fullWindowFrame(1, window)...)
	recomposeCounters(m) // warm

	// Capture the raw (ANSI-bearing) body so a color-only change is visible;
	// renderedBody strips ANSI and would hide it.
	bodyBefore := m.content()

	// Swap the editor foreground via a direct palette mutation, mirroring a
	// gui_theme chrome change, then confirm the next compose recomposes.
	m.activePalette.colors[themeEditorFG] = 0xFF0000
	if hits, misses := recomposeCounters(m); hits != 0 || misses != 1 {
		t.Fatalf("post-theme compose: hits=%d misses=%d, want 0/1 (palette fingerprint changed)", hits, misses)
	}

	// The recomposed line must differ from the pre-theme line (new fg color in
	// the ANSI sequence), proving a stale-colored cached line was not reused.
	if got := m.content(); got == bodyBefore {
		t.Fatal("theme change produced an identical body; cached line was not recomposed")
	}
}

// AC 3: the compose-time metric and cache stats are recorded through the
// latency recorder and visible in the HUD string.
func TestComposeMetricRecordedAndVisibleInHUD(t *testing.T) {
	m := New(80, 24, nil)
	window := protocol.WindowContent{
		ID:            1,
		CursorVisible: true,
		ContentEpoch:  1,
		Rows: []protocol.WindowRow{
			{ID: 1, ContentHash: 11, Text: "metric line"},
		},
	}
	m = applyTo(t, m, fullWindowFrame(1, window)...)
	// A second frame so the cache serves at least one hit, exercising the
	// cache portion of the HUD.
	m = applyTo(t, m, deltaWindowFrame(2, 1, protocol.WindowContent{
		ID:           1,
		ContentEpoch: 1,
		Rows:         []protocol.WindowRow{{Ref: true, ID: 1, ContentHash: 11}},
	})...)

	stats := m.latency.Snapshot()
	if stats.ComposeCount == 0 {
		t.Fatal("expected compose samples to be recorded")
	}
	if stats.ComposeCacheHits == 0 {
		t.Fatal("expected at least one cache hit to be recorded")
	}

	hud := stats.HUD()
	if !strings.Contains(hud, "compose") {
		t.Fatalf("HUD missing compose section: %q", hud)
	}
	if !strings.Contains(hud, "cache") {
		t.Fatalf("HUD missing cache section: %q", hud)
	}
}
