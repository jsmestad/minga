// Package latency records end-to-end keystroke-to-terminal-write latency for
// the Go TUI (ticket #2215).
//
// The frontend stamps a monotonically increasing correlation sequence into each
// key packet at input decode (Stamp). The BEAM echoes that sequence back on the
// commit_frame of the resulting frame; the frontend resolves the sample when the
// frame is about to be written to the terminal (Resolve). Samples are kept in a
// fixed-size ring buffer so the recorder never grows unbounded and the HUD can
// report live p50/p99 without allocating.
//
// The recorder is safe for concurrent use. In the Bubbletea model the Update
// loop is single-goroutine, but keeping it mutex-guarded means the bench harness
// and any future async present path can share one recorder.
package latency

import (
	"fmt"
	"sort"
	"sync"
	"time"
)

// ringSize bounds the number of in-flight stamps and recorded samples. A few
// thousand entries is far more than a human can outrun between frames, and it
// keeps the percentile sort cheap.
const ringSize = 4096

// pendingStamp pairs a correlation sequence with the time it was stamped.
type pendingStamp struct {
	seq uint32
	at  time.Time
}

// Recorder stamps keystrokes and resolves them into latency samples.
type Recorder struct {
	mu sync.Mutex

	now func() time.Time

	nextSeq uint32

	// pending maps a still-unresolved sequence to its stamp time. Bounded by
	// pendingOrder so a frame that never echoes a sequence cannot leak.
	pending      map[uint32]time.Time
	pendingOrder []uint32

	// samples is a ring buffer of resolved durations (most recent wins).
	samples []time.Duration
	head    int
	count   int

	resolved uint64
	dropped  uint64

	// compose is a ring buffer of frame compose-time durations (most recent
	// wins), tracking how long View() spent building the frame (#2288). It is
	// separate from the keystroke-to-write samples above so the HUD can show
	// both the end-to-end latency and the frontend's own compose cost, the
	// metric the line-cache is meant to drive down on large terminals.
	compose      []time.Duration
	composeHead  int
	composeCount int
	// composeCacheHits/Misses count cached vs recomposed body lines across all
	// composes since boot. They feed the HUD and let tests assert the cache is
	// actually serving hits on ref-row frames.
	composeCacheHits   uint64
	composeCacheMisses uint64
}

// New returns a Recorder using the wall clock.
func New() *Recorder {
	return newWithClock(time.Now)
}

func newWithClock(now func() time.Time) *Recorder {
	return &Recorder{
		now:     now,
		pending: make(map[uint32]time.Time, ringSize),
		samples: make([]time.Duration, ringSize),
		compose: make([]time.Duration, ringSize),
	}
}

// Stamp allocates the next correlation sequence, records the current time
// against it, and returns the sequence to embed in the outgoing key packet.
// Sequences start at 1 so that 0 can remain the "no correlation" sentinel.
func (r *Recorder) Stamp() uint32 {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.nextSeq++
	if r.nextSeq == 0 {
		r.nextSeq = 1
	}
	seq := r.nextSeq

	r.pending[seq] = r.now()
	r.pendingOrder = append(r.pendingOrder, seq)
	r.evictOldestPending()
	return seq
}

// evictOldestPending bounds the pending set. Unresolved stamps (frames that
// coalesced away an earlier keystroke, so its sequence is never echoed) are
// dropped oldest-first once the ring fills.
func (r *Recorder) evictOldestPending() {
	for len(r.pendingOrder) > ringSize {
		oldest := r.pendingOrder[0]
		r.pendingOrder = r.pendingOrder[1:]
		if _, ok := r.pending[oldest]; ok {
			delete(r.pending, oldest)
			r.dropped++
		}
	}
}

// Resolve records the elapsed time for a sequence echoed on a frame boundary.
// A sequence of 0 (no correlation) or an unknown sequence is ignored; the BEAM
// coalesces rapid keystrokes into one frame, so only the latest sequence in a
// frame resolves and earlier ones fall out of pending naturally.
func (r *Recorder) Resolve(seq uint32) {
	if seq == 0 {
		return
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	stampedAt, ok := r.pending[seq]
	if !ok {
		return
	}
	delete(r.pending, seq)
	r.dropForgetOrder(seq)

	r.samples[r.head] = r.now().Sub(stampedAt)
	r.head = (r.head + 1) % ringSize
	if r.count < ringSize {
		r.count++
	}
	r.resolved++
}

// dropForgetOrder removes seq from pendingOrder so the slice does not grow
// without bound when sequences resolve out of stamp order.
func (r *Recorder) dropForgetOrder(seq uint32) {
	for i, s := range r.pendingOrder {
		if s == seq {
			r.pendingOrder = append(r.pendingOrder[:i], r.pendingOrder[i+1:]...)
			return
		}
	}
}

// ObserveCompose records a single frame's compose duration into the compose
// ring (#2288). It also folds in how many body lines that compose served from
// the line cache (hits) versus recomposed (misses), so the HUD can show the
// cache's effect alongside the compose time it drives down.
func (r *Recorder) ObserveCompose(d time.Duration, cacheHits, cacheMisses uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.compose[r.composeHead] = d
	r.composeHead = (r.composeHead + 1) % ringSize
	if r.composeCount < ringSize {
		r.composeCount++
	}
	r.composeCacheHits += cacheHits
	r.composeCacheMisses += cacheMisses
}

// Stats summarizes the resolved samples currently in the ring buffer.
type Stats struct {
	Count    int
	Resolved uint64
	Dropped  uint64
	P50      time.Duration
	P99      time.Duration
	Max      time.Duration

	// ComposeCount/ComposeP50/ComposeP99/ComposeMax summarize frame compose
	// time over the compose ring (#2288). ComposeCacheHits/Misses are the
	// cumulative cached-vs-recomposed body-line counts since boot.
	ComposeCount       int
	ComposeP50         time.Duration
	ComposeP99         time.Duration
	ComposeMax         time.Duration
	ComposeCacheHits   uint64
	ComposeCacheMisses uint64
}

// Snapshot returns percentile statistics over the buffered samples. It copies
// the live window before sorting so the hot path is never blocked on a sort of
// the shared buffer.
func (r *Recorder) Snapshot() Stats {
	r.mu.Lock()
	window := make([]time.Duration, r.count)
	for i := 0; i < r.count; i++ {
		idx := (r.head - r.count + i + ringSize) % ringSize
		window[i] = r.samples[idx]
	}
	composeWindow := make([]time.Duration, r.composeCount)
	for i := 0; i < r.composeCount; i++ {
		idx := (r.composeHead - r.composeCount + i + ringSize) % ringSize
		composeWindow[i] = r.compose[idx]
	}
	stats := Stats{
		Count:              r.count,
		Resolved:           r.resolved,
		Dropped:            r.dropped,
		ComposeCount:       r.composeCount,
		ComposeCacheHits:   r.composeCacheHits,
		ComposeCacheMisses: r.composeCacheMisses,
	}
	r.mu.Unlock()

	if len(composeWindow) > 0 {
		sort.Slice(composeWindow, func(i, j int) bool { return composeWindow[i] < composeWindow[j] })
		stats.ComposeP50 = percentile(composeWindow, 0.50)
		stats.ComposeP99 = percentile(composeWindow, 0.99)
		stats.ComposeMax = composeWindow[len(composeWindow)-1]
	}

	if len(window) == 0 {
		return stats
	}

	sort.Slice(window, func(i, j int) bool { return window[i] < window[j] })
	stats.P50 = percentile(window, 0.50)
	stats.P99 = percentile(window, 0.99)
	stats.Max = window[len(window)-1]
	return stats
}

// percentile returns the value at the given ratio of a pre-sorted slice using
// nearest-rank, matching the BEAM bench's percentile/2.
func percentile(sorted []time.Duration, ratio float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	index := int(float64(len(sorted))*ratio+0.999999) - 1
	if index < 0 {
		index = 0
	}
	if index >= len(sorted) {
		index = len(sorted) - 1
	}
	return sorted[index]
}

// HUD renders a one-line latency overlay suitable for an on-screen badge. It
// shows the keystroke-to-write latency and, when available, the frame compose
// time and line-cache hit rate the #2288 line cache drives (compose time down,
// hit rate up).
func (s Stats) HUD() string {
	latPart := "lat: (no samples)"
	if s.Count > 0 {
		latPart = fmt.Sprintf(
			"lat p50 %s  p99 %s  max %s  n=%d",
			fmtDur(s.P50), fmtDur(s.P99), fmtDur(s.Max), s.Count,
		)
	}
	if s.ComposeCount == 0 {
		return latPart
	}
	return fmt.Sprintf("%s  %s", latPart, s.composeHUD())
}

// composeHUD renders the compose-time and cache portion of the HUD.
func (s Stats) composeHUD() string {
	total := s.ComposeCacheHits + s.ComposeCacheMisses
	hitRate := 0.0
	if total > 0 {
		hitRate = float64(s.ComposeCacheHits) / float64(total) * 100
	}
	return fmt.Sprintf(
		"compose p50 %s  p99 %s  cache %.0f%% (%d/%d)",
		fmtDur(s.ComposeP50), fmtDur(s.ComposeP99), hitRate, s.ComposeCacheHits, total,
	)
}

func fmtDur(d time.Duration) string {
	switch {
	case d >= time.Millisecond:
		return fmt.Sprintf("%.2fms", float64(d)/float64(time.Millisecond))
	default:
		return fmt.Sprintf("%dµs", d.Microseconds())
	}
}
