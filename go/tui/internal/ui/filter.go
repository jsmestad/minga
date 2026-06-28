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
	wheelDelta int
	wheelMod   tea.KeyMod
}

func NewInputFilter() *InputFilter {
	return &InputFilter{now: time.Now}
}

func (f *InputFilter) Filter(_ tea.Model, msg tea.Msg) tea.Msg {
	switch msg := msg.(type) {
	case tea.MouseMotionMsg:
		if !f.allow(&f.lastMotion) {
			return nil
		}
	case tea.MouseWheelMsg:
		mouse := tea.MouseMsg(msg).Mouse()
		delta := wheelDeltaSign(mouse.Button)
		if delta == 0 {
			return msg
		}
		if f.wheelDelta != 0 && (f.wheelDelta > 0) != (delta > 0) {
			f.wheelDelta = 0
		}
		f.wheelDelta += delta
		f.wheelMod = mouse.Mod
		if !f.allow(&f.lastWheel) {
			return nil
		}
		return msg
	}
	return msg
}

func (f *InputFilter) DrainCoalesced() (delta int, mod tea.KeyMod) {
	d, m := f.wheelDelta, f.wheelMod
	f.wheelDelta = 0
	return d, m
}

func (f *InputFilter) allow(last *time.Time) bool {
	at := f.now()
	if !last.IsZero() && at.Sub(*last) < inputFilterInterval {
		return false
	}
	*last = at
	return true
}

func wheelDeltaSign(button tea.MouseButton) int {
	switch button {
	case tea.MouseWheelDown:
		return 1
	case tea.MouseWheelUp:
		return -1
	default:
		return 0
	}
}
