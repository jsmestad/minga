package ui

import (
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
)

func TestInputFilterThrottlesMotion(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	msg := tea.MouseMotionMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseNone})

	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("first motion should pass through")
	}

	now = now.Add(5 * time.Millisecond)
	if got := f.Filter(nil, msg); got != nil {
		t.Fatal("motion within 16ms should be dropped")
	}

	now = now.Add(20 * time.Millisecond)
	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("motion after 16ms should pass through")
	}
}

func TestInputFilterThrottlesWheel(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	msg := tea.MouseWheelMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseWheelDown})

	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("first wheel should pass through")
	}

	now = now.Add(5 * time.Millisecond)
	if got := f.Filter(nil, msg); got != nil {
		t.Fatal("wheel within 16ms should be dropped")
	}

	now = now.Add(20 * time.Millisecond)
	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("wheel after 16ms should pass through")
	}
}

func TestInputFilterPassesKeyPresses(t *testing.T) {
	f := NewInputFilter()
	msg := tea.KeyPressMsg(tea.Key{Code: 'a', Text: "a"})
	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("key presses must never be dropped")
	}
}

func TestInputFilterExactBoundaryPasses(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	msg := tea.MouseMotionMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseNone})

	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("first motion should pass through")
	}

	now = now.Add(inputFilterInterval)
	if got := f.Filter(nil, msg); got == nil {
		t.Fatal("motion at exactly 16ms should pass (condition is strictly less-than)")
	}
}

func TestInputFilterMotionAndWheelThrottleIndependently(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	motion := tea.MouseMotionMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseNone})
	wheel := tea.MouseWheelMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseWheelDown})

	if got := f.Filter(nil, motion); got == nil {
		t.Fatal("first motion should pass")
	}

	now = now.Add(5 * time.Millisecond)
	if got := f.Filter(nil, wheel); got == nil {
		t.Fatal("first wheel should pass even when motion was just allowed")
	}
}

func TestInputFilterCoalescesDroppedWheelEvents(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	down := tea.MouseWheelMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseWheelDown})

	if got := f.Filter(nil, down); got == nil {
		t.Fatal("first wheel should pass through")
	}
	delta, _ := f.DrainCoalesced()
	if delta != 1 {
		t.Fatalf("first event delta should be 1, got %d", delta)
	}

	now = now.Add(3 * time.Millisecond)
	f.Filter(nil, down)
	now = now.Add(3 * time.Millisecond)
	f.Filter(nil, down)
	now = now.Add(3 * time.Millisecond)
	f.Filter(nil, down)

	now = now.Add(20 * time.Millisecond)
	if got := f.Filter(nil, down); got == nil {
		t.Fatal("wheel after 16ms should pass through")
	}
	delta, _ = f.DrainCoalesced()
	if delta != 4 {
		t.Fatalf("coalesced delta should be 4 (3 dropped + 1 passed), got %d", delta)
	}
}

func TestInputFilterCoalescesOpposingDirections(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	down := tea.MouseWheelMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseWheelDown})
	up := tea.MouseWheelMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseWheelUp})

	f.Filter(nil, down)
	f.DrainCoalesced()

	now = now.Add(3 * time.Millisecond)
	f.Filter(nil, down)
	now = now.Add(3 * time.Millisecond)
	f.Filter(nil, up)

	now = now.Add(20 * time.Millisecond)
	f.Filter(nil, down)
	delta, _ := f.DrainCoalesced()
	if delta != 1 {
		t.Fatalf("opposing directions should cancel: 2 down - 1 up = 1, got %d", delta)
	}
}

func TestInputFilterDrainResetsAccumulator(t *testing.T) {
	now := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)
	f := &InputFilter{now: func() time.Time { return now }}

	down := tea.MouseWheelMsg(tea.Mouse{X: 5, Y: 5, Button: tea.MouseWheelDown})

	f.Filter(nil, down)
	f.DrainCoalesced()

	delta, _ := f.DrainCoalesced()
	if delta != 0 {
		t.Fatalf("second drain should return 0, got %d", delta)
	}
}
