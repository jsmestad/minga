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
