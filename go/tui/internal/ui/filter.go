package ui

import (
	"time"

	tea "charm.land/bubbletea/v2"
)

const inputFilterInterval = 16 * time.Millisecond // ~60fps

type InputFilter struct {
	now        func() time.Time
	lastMotion time.Time
	lastWheel  time.Time
}

func NewInputFilter() *InputFilter {
	return &InputFilter{now: time.Now}
}

func (f *InputFilter) Filter(_ tea.Model, msg tea.Msg) tea.Msg {
	switch msg.(type) {
	case tea.MouseMotionMsg:
		if !f.allow(&f.lastMotion) {
			return nil
		}
	case tea.MouseWheelMsg:
		if !f.allow(&f.lastWheel) {
			return nil
		}
	}
	return msg
}

func (f *InputFilter) allow(last *time.Time) bool {
	at := f.now()
	if !last.IsZero() && at.Sub(*last) < inputFilterInterval {
		return false
	}
	*last = at
	return true
}
