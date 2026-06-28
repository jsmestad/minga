package ui

import (
	"testing"
	"time"
)

func TestInflight(t *testing.T) {
	tests := []struct {
		message string
		want    bool
	}{
		{"Formatting…", true},
		{"Finding references…", true},
		{"Renaming…", true},
		{"Formatting… [Esc to cancel]", true},
		{"Formatted", false},
		{"Format error: LSP request failed", false},
		{"", false},
	}
	for _, tt := range tests {
		t.Run(tt.message, func(t *testing.T) {
			if got := inflight(tt.message); got != tt.want {
				t.Errorf("inflight(%q) = %v, want %v", tt.message, got, tt.want)
			}
		})
	}
}

func TestFeedbackUpdateStatus(t *testing.T) {
	var f feedbackState
	f.updateStatus("Formatting…")
	if f.onset.IsZero() {
		t.Error("onset should be set for in-flight message")
	}
	if f.lastMessage != "Formatting…" {
		t.Errorf("lastMessage = %q, want %q", f.lastMessage, "Formatting…")
	}

	f.updateStatus("Formatted")
	if !f.onset.IsZero() {
		t.Error("onset should be cleared for non-in-flight message")
	}
}

func TestFeedbackSpinnerDelay(t *testing.T) {
	var f feedbackState
	f.updateStatus("Formatting…")

	f.tick()
	if f.spinnerOn {
		t.Error("spinner should not be on before delay threshold")
	}

	f.onset = time.Now().Add(-spinnerDelayMs - time.Millisecond)
	f.tick()
	if !f.spinnerOn {
		t.Error("spinner should be on after delay threshold")
	}
}

func TestFeedbackFormatMessage(t *testing.T) {
	var f feedbackState

	result := f.formatMessage("Formatting…")
	if result != "Formatting…" {
		t.Errorf("should not prefix spinner when not active, got %q", result)
	}

	f.spinnerOn = true
	f.frame = 0
	result = f.formatMessage("Formatting…")
	want := spinnerFrames[0] + " " + "Formatting…"
	if result != want {
		t.Errorf("should prefix spinner, got %q want %q", result, want)
	}

	result = f.formatMessage("Formatted")
	if result != "Formatted" {
		t.Errorf("should not prefix non-inflight message, got %q", result)
	}
}

func TestFeedbackActive(t *testing.T) {
	var f feedbackState
	if f.active() {
		t.Error("idle state should not be active")
	}

	f.updateStatus("Formatting…")
	if !f.active() {
		t.Error("in-flight state should be active")
	}

	f.updateStatus("Formatted")
	if f.active() {
		t.Error("cleared state should not be active")
	}
}

func TestFeedbackSpinnerHold(t *testing.T) {
	var f feedbackState
	f.updateStatus("Formatting…")
	f.onset = time.Now().Add(-spinnerDelayMs - time.Millisecond)
	f.tick()
	if !f.spinnerOn {
		t.Fatal("spinner should be on")
	}

	f.updateStatus("Formatted")
	if !f.spinnerOn {
		t.Error("spinner should hold after status clears (hold floor)")
	}
	if !f.active() {
		t.Error("should be active during hold period")
	}

	f.spinnerOnAt = time.Now().Add(-spinnerHoldMs - time.Millisecond)
	f.tick()
	if f.spinnerOn {
		t.Error("spinner should clear after hold floor elapsed")
	}
}

func TestFeedbackSpinnerRotates(t *testing.T) {
	var f feedbackState
	first := f.spinner()
	f.frame++
	second := f.spinner()
	if first == second {
		t.Error("spinner should rotate on frame advance")
	}
}

func TestFeedbackDuplicateMessage(t *testing.T) {
	var f feedbackState
	f.updateStatus("Formatting…")
	onset := f.onset

	f.updateStatus("Formatting…")
	if !f.onset.Equal(onset) {
		t.Error("duplicate message should not reset onset")
	}
}
