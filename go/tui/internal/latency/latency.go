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

// Stats summarizes the resolved samples currently in the ring buffer.
type Stats struct {
	Count    int
	Resolved uint64
	Dropped  uint64
	P50      time.Duration
	P99      time.Duration
	Max      time.Duration
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
	stats := Stats{Count: r.count, Resolved: r.resolved, Dropped: r.dropped}
	r.mu.Unlock()

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

// HUD renders a one-line latency overlay suitable for an on-screen badge.
func (s Stats) HUD() string {
	if s.Count == 0 {
		return "lat: (no samples)"
	}
	return fmt.Sprintf(
		"lat p50 %s  p99 %s  max %s  n=%d",
		fmtDur(s.P50), fmtDur(s.P99), fmtDur(s.Max), s.Count,
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
