package ui

import (
	"hash/fnv"
	"sort"

	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

// lineCache memoizes the rendered string of each window body row so that a
// window-content delta whose rows are mostly refs (#2288, the ref-or-full wire
// format) reuses the previously composed lines instead of re-running the
// lipgloss tree for every row on every frame. The protocol's granularity is
// rows, so the cache is line-level.
//
// Correctness over cleverness: a cached line is only ever returned when EVERY
// input that produced it is identical. A row's rendered string depends on more
// than its own text/spans (content_hash); it also depends on per-window state
// (scroll, cursorline, selection, search, diagnostics, highlights, annotations,
// gutter, indent guides, geometry width) and global state (theme/palette,
// editor background, terminal width). All of that is folded into a per-window
// "context" fingerprint. When the context changes, the window's whole row map
// is dropped, so the cache can never serve a stale line. Within a stable
// context, a row hits the cache only when its row_id, content_hash, and row
// index all match, because the rendered output is also a function of the row's
// position (cursorline row, gutter entry index, indent levels indexed by row,
// per-row overlays). This makes patched output byte-identical to a from-scratch
// compose by construction (AC 4): the cache stores exactly what the full path
// produced, under an identical-inputs guarantee.
//
// The cache is a pointer field on Model so it survives the value-copied Model
// the Bubbletea Update loop produces, the same lifetime trick latency.Recorder
// uses.
type lineCache struct {
	windows map[uint16]*windowLineCache

	// hits/misses count cached-vs-recomposed body lines for the in-progress
	// compose. They are reset at the start of each compose (resetCounters) and
	// read back after it (takeCounters) so the model can fold them into the
	// latency HUD and tests can assert hit/miss behavior per frame.
	//
	// These counters are intentionally plain (non-atomic) fields: compose is
	// single-threaded. It runs inside the Bubbletea Update loop (composeBody),
	// and View() only reads the already-composed viewport content. No second
	// goroutine ever touches the cache during a compose, so this invariant is
	// load-bearing but implicit; do not read or mutate the cache off the Update
	// goroutine.
	hits   uint64
	misses uint64
}

// windowLineCache holds one window's cached rows under a single context
// fingerprint. A context change drops the whole map. The map is rebuilt fresh
// on every window render (see beginWindowRender + builder.commit) and holds
// exactly the rows rendered this frame, so it stays bounded at viewport size
// even across vertical scroll, where the BEAM re-emits a row at a new index and
// its old key would otherwise linger forever.
type windowLineCache struct {
	context uint64
	rows    map[lineCacheKey]string
}

// lineCacheKey identifies a cached rendered row within a window context. The
// rowIndex is zero for position-independent rows and the actual index when
// cursorline, gutter, indent guides, or overlays make composition positional.
type lineCacheKey struct {
	rowID    uint64
	hash     uint32
	rowIndex int
}

func newLineCache() *lineCache {
	return &lineCache{windows: map[uint16]*windowLineCache{}}
}

// reset clears every cached line. It is the full-invalidation sink used by
// resize, structural commands, and keyframe resync (#2288 AC 2, AC 5).
func (c *lineCache) reset() {
	if c == nil {
		return
	}
	c.windows = map[uint16]*windowLineCache{}
}

// dropWindow removes one window's cached lines when the window goes away, so a
// closed split does not leak its row map for the life of the session.
func (c *lineCache) dropWindow(windowID uint16) {
	if c == nil {
		return
	}
	delete(c.windows, windowID)
}

// resetCounters zeroes the per-compose hit/miss counters at the start of a
// compose so each frame reports only its own cache activity.
func (c *lineCache) resetCounters() {
	if c == nil {
		return
	}
	c.hits = 0
	c.misses = 0
}

// takeCounters returns the per-compose hit/miss counts gathered since the last
// resetCounters.
func (c *lineCache) takeCounters() (hits, misses uint64) {
	if c == nil {
		return 0, 0
	}
	return c.hits, c.misses
}

// windowRenderBuilder accumulates the lines rendered for a single window during
// one compose. It reads hits from the window's previous-frame map (prev) and
// writes every row it touches into a fresh map (next). commit swaps
// next in, so the stored map holds exactly the rows rendered this frame and can
// never grow past the viewport. Without this rebuild, vertical scroll (the BEAM
// re-emits a stable row at a shifted index) would keep adding new {id,hash,idx}
// keys while the old-index entries lingered for the life of the session.
type windowRenderBuilder struct {
	cache    *lineCache
	windowID uint16
	context  uint64
	prev     map[lineCacheKey]string // previous frame's rows, read-only lookups
	next     map[lineCacheKey]string // this frame's rows, populated as we render
}

// beginWindowRender starts a fresh per-frame map for the window. It captures the
// prior map for lookups only when the context still matches; a context change
// means no prior line is reusable, so prev stays nil and every row misses.
func (c *lineCache) beginWindowRender(windowID uint16, context uint64) *windowRenderBuilder {
	if c == nil {
		return nil
	}
	b := &windowRenderBuilder{
		cache:    c,
		windowID: windowID,
		context:  context,
		next:     map[lineCacheKey]string{},
	}
	if entry, ok := c.windows[windowID]; ok && entry.context == context {
		b.prev = entry.rows
	}
	return b
}

// lookup returns a previously cached rendered row for the key, or ("", false) on
// a miss. On a hit it also carries the line forward into this frame's map so the
// row survives the per-frame rebuild without recomposing.
func (b *windowRenderBuilder) lookup(key lineCacheKey) (string, bool) {
	if b == nil || b.prev == nil {
		return "", false
	}
	line, ok := b.prev[key]
	if ok {
		b.next[key] = line
	}
	return line, ok
}

// store records a freshly rendered row into this frame's map.
func (b *windowRenderBuilder) store(key lineCacheKey, line string) {
	if b == nil {
		return
	}
	b.next[key] = line
}

// commit swaps this frame's map in as the window's cache, discarding
// any prior-frame keys that were not rendered (and thus not carried forward).
// This is what keeps the map bounded at the rendered row count.
func (b *windowRenderBuilder) commit() {
	if b == nil || b.cache == nil {
		return
	}
	b.cache.windows[b.windowID] = &windowLineCache{context: b.context, rows: b.next}
}

// windowContextFingerprint folds every input that affects a window's row
// rendering EXCEPT the per-row text/spans/id/hash (which are the cache key)
// into one hash. Any change here invalidates the whole window's cached rows.
// It is deliberately conservative: it mixes in the full per-window overlay and
// chrome state, the global theme/background/width, and the placement geometry,
// so a cached line is reused only under byte-for-byte identical render inputs.
func (m Model) windowContextFingerprint(window protocol.WindowContent, width int, gutter protocol.Gutter, hasGutter bool) uint64 {
	h := fnv.New64a()
	writeUint := func(v uint64) {
		var buf [8]byte
		for i := 0; i < 8; i++ {
			buf[i] = byte(v >> (8 * i))
		}
		h.Write(buf[:])
	}
	writeStr := func(s string) {
		writeUint(uint64(len(s)))
		h.Write([]byte(s))
	}
	writeBool := func(b bool) {
		if b {
			writeUint(1)
		} else {
			writeUint(0)
		}
	}

	// Terminal/global render inputs.
	writeUint(uint64(uint32(width)))
	writeUint(uint64(m.bg))
	// The active palette is the source of every color the row render reads
	// (text, selection, search, diagnostic, gutter, indent guide). Fold its
	// identity in so a theme swap invalidates cached lines. paletteFingerprint
	// returns a stable digest of the palette's resolved colors.
	writeUint(m.paletteFingerprint())

	// Per-window scroll and cursorline.
	writeUint(uint64(window.ScrollLeft))
	writeUint(uint64(m.presentationScrollEffectiveLeft(window)))
	writeBool(window.Cursorline.Visible)
	writeUint(uint64(window.Cursorline.Row))
	writeUint(uint64(window.Cursorline.BG))

	// Per-window overlays. These shift a row's background/foreground per
	// column, so any change recomposes the affected window's lines.
	writeUint(uint64(window.Selection.Type))
	writeUint(uint64(window.Selection.StartRow))
	writeUint(uint64(window.Selection.StartCol))
	writeUint(uint64(window.Selection.EndRow))
	writeUint(uint64(window.Selection.EndCol))
	for _, hl := range window.Highlights {
		writeUint(uint64(hl.Kind))
		writeUint(uint64(hl.StartRow))
		writeUint(uint64(hl.StartCol))
		writeUint(uint64(hl.EndRow))
		writeUint(uint64(hl.EndCol))
	}
	for _, match := range window.SearchMatches {
		writeUint(uint64(match.Row))
		writeUint(uint64(match.StartCol))
		writeUint(uint64(match.EndCol))
		writeBool(match.Current)
	}
	for _, diag := range window.Diagnostics {
		writeUint(uint64(diag.Severity))
		writeUint(uint64(diag.StartRow))
		writeUint(uint64(diag.StartCol))
		writeUint(uint64(diag.EndRow))
		writeUint(uint64(diag.EndCol))
	}
	for _, ann := range window.Annotations {
		writeUint(uint64(ann.Row))
		writeUint(uint64(ann.Kind))
		writeUint(uint64(ann.FG))
		writeUint(uint64(ann.BG))
		writeStr(ann.Text)
	}

	// Gutter (line numbers, signs, cursor line) renders to the left of each row
	// and is indexed by row, so its full identity is part of the context.
	writeBool(hasGutter)
	if hasGutter {
		writeUint(uint64(gutter.SignColWidth))
		writeUint(uint64(gutter.LineNumberWidth))
		writeUint(uint64(gutter.LineNumberStyle))
		writeUint(uint64(gutter.CursorLine))
		writeUint(uint64(gutter.ContentHeight))
		for _, entry := range gutter.Entries {
			writeUint(uint64(entry.BufferLine))
			writeUint(uint64(entry.SignType))
			writeUint(uint64(entry.DisplayType))
			writeStr(entry.SignText)
		}
	}

	// Indent guides are indexed by row and column and change the rendered glyph
	// of whitespace cells, so fold their full identity in too.
	if guides, ok := m.indentGuides[window.ID]; ok {
		writeUint(uint64(guides.TabWidth))
		writeUint(uint64(guides.ActiveGuideCol))
		for _, col := range guides.GuideCols {
			writeUint(uint64(col))
		}
		for _, level := range guides.IndentLevels {
			writeUint(uint64(level))
		}
	}

	return h.Sum64()
}

// paletteFingerprint returns a stable digest of the active palette so any theme
// change invalidates cached lines. It hashes the raw color slots directly (the
// single source of every color the row render path resolves), sorted by slot so
// the digest is deterministic regardless of Go's map iteration order.
func (m Model) paletteFingerprint() uint64 {
	colors := m.activePalette.colors
	slots := make([]int, 0, len(colors))
	for slot := range colors {
		slots = append(slots, int(slot))
	}
	sort.Ints(slots)

	h := fnv.New64a()
	var buf [12]byte
	for _, slot := range slots {
		v := colors[byte(slot)]
		buf[0] = byte(slot)
		buf[1] = byte(v)
		buf[2] = byte(v >> 8)
		buf[3] = byte(v >> 16)
		buf[4] = byte(v >> 24)
		h.Write(buf[:5])
	}
	return h.Sum64()
}
