package latency

import (
	"testing"
	"time"
)

// fakeClock returns successive times from a controllable cursor so tests can
// assert exact resolved durations without sleeping.
type fakeClock struct{ now time.Time }

func (c *fakeClock) advance(d time.Duration) { c.now = c.now.Add(d) }
func (c *fakeClock) read() time.Time         { return c.now }

func newTestRecorder() (*Recorder, *fakeClock) {
	clock := &fakeClock{now: time.Unix(0, 0)}
	return newWithClock(clock.read), clock
}

func TestStampReturnsMonotonicNonZeroSequences(t *testing.T) {
	r, _ := newTestRecorder()
	a := r.Stamp()
	b := r.Stamp()
	if a == 0 || b == 0 {
		t.Fatalf("sequences must be non-zero, got %d and %d", a, b)
	}
	if b != a+1 {
		t.Fatalf("sequences must increase by one, got %d then %d", a, b)
	}
}

func TestResolveRecordsElapsedDuration(t *testing.T) {
	r, clock := newTestRecorder()
	seq := r.Stamp()
	clock.advance(750 * time.Microsecond)
	r.Resolve(seq)

	stats := r.Snapshot()
	if stats.Count != 1 {
		t.Fatalf("count = %d, want 1", stats.Count)
	}
	if stats.P50 != 750*time.Microsecond {
		t.Fatalf("p50 = %s, want 750µs", stats.P50)
	}
	if stats.Resolved != 1 {
		t.Fatalf("resolved = %d, want 1", stats.Resolved)
	}
}

func TestResolveIgnoresZeroAndUnknownSequences(t *testing.T) {
	r, _ := newTestRecorder()
	r.Resolve(0)
	r.Resolve(999) // never stamped
	if got := r.Snapshot().Count; got != 0 {
		t.Fatalf("count = %d, want 0 (no spurious samples)", got)
	}
}

func TestSnapshotPercentiles(t *testing.T) {
	r, clock := newTestRecorder()
	// Stamp and resolve 100 samples of 1µs..100µs so percentiles are exact.
	for i := 1; i <= 100; i++ {
		seq := r.Stamp()
		clock.advance(time.Duration(i) * time.Microsecond)
		r.Resolve(seq)
		clock.advance(-time.Duration(i) * time.Microsecond) // keep base aligned
	}

	stats := r.Snapshot()
	if stats.Count != 100 {
		t.Fatalf("count = %d, want 100", stats.Count)
	}
	// nearest-rank p50 over 1..100µs -> 50µs, p99 -> 99µs, max -> 100µs.
	if stats.P50 != 50*time.Microsecond {
		t.Fatalf("p50 = %s, want 50µs", stats.P50)
	}
	if stats.P99 != 99*time.Microsecond {
		t.Fatalf("p99 = %s, want 99µs", stats.P99)
	}
	if stats.Max != 100*time.Microsecond {
		t.Fatalf("max = %s, want 100µs", stats.Max)
	}
}

func TestRingBufferBoundsSamples(t *testing.T) {
	r, clock := newTestRecorder()
	total := ringSize + 500
	for i := 0; i < total; i++ {
		seq := r.Stamp()
		clock.advance(time.Microsecond)
		r.Resolve(seq)
	}
	stats := r.Snapshot()
	if stats.Count != ringSize {
		t.Fatalf("count = %d, want ring cap %d", stats.Count, ringSize)
	}
	if stats.Resolved != uint64(total) {
		t.Fatalf("resolved = %d, want %d", stats.Resolved, total)
	}
}

func TestUnresolvedStampsAreEvicted(t *testing.T) {
	r, _ := newTestRecorder()
	// Stamp far more than the ring without resolving; oldest must be dropped so
	// pending never grows past the bound (mirrors frame coalescing dropping
	// intermediate keystrokes).
	for i := 0; i < ringSize+100; i++ {
		r.Stamp()
	}
	if got := len(r.pending); got > ringSize {
		t.Fatalf("pending size = %d, want <= %d", got, ringSize)
	}
	if r.Snapshot().Dropped == 0 {
		t.Fatal("expected dropped count > 0 after overflowing pending")
	}
}

func TestHUDStringHasNoSamplesPlaceholder(t *testing.T) {
	r, _ := newTestRecorder()
	if got := r.Snapshot().HUD(); got == "" {
		t.Fatal("HUD must render a placeholder when empty")
	}
}
