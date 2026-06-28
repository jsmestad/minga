package ui

import (
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

const (
	feedbackTickInterval = 80 * time.Millisecond
	spinnerDelayMs       = 100 * time.Millisecond
	spinnerHoldMs        = 500 * time.Millisecond
)

var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

type feedbackTickMsg struct{}

func feedbackTick() tea.Cmd {
	return tea.Tick(feedbackTickInterval, func(time.Time) tea.Msg {
		return feedbackTickMsg{}
	})
}

type feedbackState struct {
	frame       uint64
	ticking     bool
	onset       time.Time
	spinnerOn   bool
	spinnerOnAt time.Time
	lastMessage string
}

func (f *feedbackState) tick() {
	f.frame++
	now := time.Now()
	if !f.onset.IsZero() && now.Sub(f.onset) >= spinnerDelayMs {
		if !f.spinnerOn {
			f.spinnerOn = true
			f.spinnerOnAt = now
		}
	}
	if f.onset.IsZero() && f.spinnerOn && !f.spinnerOnAt.IsZero() {
		if now.Sub(f.spinnerOnAt) >= spinnerHoldMs {
			f.spinnerOn = false
		}
	}
}

func (f feedbackState) spinner() string {
	return spinnerFrames[int(f.frame)%len(spinnerFrames)]
}

// inflight returns true when the status message indicates a pending operation.
// The BEAM convention is to suffix pending messages with "…".
func inflight(message string) bool {
	return strings.HasSuffix(message, "…") ||
		strings.HasSuffix(message, "… [Esc to cancel]")
}

// updateStatus tracks in-flight status transitions.
func (f *feedbackState) updateStatus(message string) {
	if message == f.lastMessage {
		return
	}
	f.lastMessage = message
	if inflight(message) {
		if f.onset.IsZero() {
			f.onset = time.Now()
		}
	} else {
		f.onset = time.Time{}
	}
}

// active returns true when the feedback system needs the animation tick running.
func (f feedbackState) active() bool {
	return !f.onset.IsZero() || f.spinnerOn
}

// formatMessage prefixes the status message with a braille spinner when the
// spinner is visible, or returns it unchanged. This is read-only (value receiver).
func (f feedbackState) formatMessage(message string) string {
	if f.spinnerOn && inflight(message) {
		return f.spinner() + " " + message
	}
	return message
}
