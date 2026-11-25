package ui

import (
	"sync"
	"sync/atomic"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/term"
)

const inputFilterInterval = 16 * time.Millisecond // ~60fps

type InputFilter struct {
	now         func() time.Time
	lastMotion  time.Time
	outputEpoch atomic.Uint64
}

func NewInputFilter() *InputFilter {
	return &InputFilter{now: time.Now}
}

func (f *InputFilter) Filter(model tea.Model, msg tea.Msg) tea.Msg {
	msg = normalizeTerminalInput(resolveKeyBoundary(msg))
	switch msg := msg.(type) {
	case tea.MouseClickMsg:
		if msg.Button == tea.MouseLeft {
			if m, ok := model.(Model); ok && m.presentedClick != nil {
				epoch := f.outputEpoch.Load()
				if epoch&1 != 0 {
					return nil
				}
				m.presentedClick.epoch = &f.outputEpoch
				m.presentedClick.observedEpoch = epoch
			}
		}
	case tea.MouseMotionMsg:
		if !f.allow(&f.lastMotion) {
			return nil
		}
	}
	return msg
}

type trackedTerminalOutput struct {
	term.File
	mu    sync.Mutex
	epoch *atomic.Uint64
}

// TrackOutput lets pointer input detect a terminal write that overlaps target selection.
func (f *InputFilter) TrackOutput(writer term.File) term.File {
	return &trackedTerminalOutput{File: writer, epoch: &f.outputEpoch}
}

func (w *trackedTerminalOutput) Write(p []byte) (int, error) {
	w.mu.Lock()
	w.epoch.Add(1)
	n, err := w.File.Write(p)
	w.epoch.Add(1)
	w.mu.Unlock()
	return n, err
}

func (f *InputFilter) allow(last *time.Time) bool {
	at := f.now()
	if !last.IsZero() && at.Sub(*last) < inputFilterInterval {
		return false
	}
	*last = at
	return true
}
