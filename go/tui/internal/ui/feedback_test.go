package ui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

var feedbackTestStart = time.Date(2026, 7, 13, 12, 0, 0, 0, time.UTC)

func testOperation(id uint64, status generated.OperationStatus, message string) generated.GuiStatusBarOperation {
	return generated.GuiStatusBarOperation{
		OperationID: id,
		Kind:        generated.OperationKindExternalFormat,
		Status:      status,
		Message:     message,
	}
}

func presented(t *testing.T, feedback feedbackState) string {
	t.Helper()
	text, _, ok := feedback.presentation()
	if !ok {
		t.Fatal("expected visible operation presentation")
	}
	return text
}

func TestFeedbackPresentsEverySemanticStatus(t *testing.T) {
	tests := []struct {
		status generated.OperationStatus
		want   string
	}{
		{generated.OperationStatusPending, "Working..."},
		{generated.OperationStatusQueued, "Queued · Working..."},
		{generated.OperationStatusRunning, "Working..."},
		{generated.OperationStatusSuccess, "✓ Working..."},
		{generated.OperationStatusError, "✕ Error · Working..."},
		{generated.OperationStatusTimeout, "! Timed out · Working..."},
		{generated.OperationStatusCanceled, "× Canceled · Working..."},
		{generated.OperationStatusStale, "↷ Stale · Working..."},
	}

	for _, test := range tests {
		t.Run(test.want, func(t *testing.T) {
			var feedback feedbackState
			operation := testOperation(1, test.status, "Working...")
			feedback.transition(&operation, feedbackTestStart)
			if got := presented(t, feedback); got != test.want {
				t.Fatalf("presentation = %q, want %q", got, test.want)
			}
		})
	}
}

func TestFeedbackRunningSpinnerExactBoundaryAndPunctuationIndependence(t *testing.T) {
	for _, message := range []string{"Formatting", "Formatting…", "Formatting..."} {
		t.Run(message, func(t *testing.T) {
			var feedback feedbackState
			operation := testOperation(1, generated.OperationStatusRunning, message)
			feedback.transition(&operation, feedbackTestStart)
			feedback.tick(feedbackTestStart.Add(spinnerDelay - time.Nanosecond))
			if got := presented(t, feedback); got != message {
				t.Fatalf("before 100ms = %q, want %q", got, message)
			}

			feedback.tick(feedbackTestStart.Add(spinnerDelay))
			if got := presented(t, feedback); got != feedback.spinner()+" "+message {
				t.Fatalf("at 100ms = %q", got)
			}
			if !feedback.spinnerOnAt.Equal(feedbackTestStart.Add(spinnerDelay)) {
				t.Fatalf("spinner visibility = %v", feedback.spinnerOnAt)
			}
		})
	}
}

func TestFeedbackPendingWaitingCancelAndMetadataExactBoundary(t *testing.T) {
	var feedback feedbackState
	operation := testOperation(1, generated.OperationStatusPending, "Formatting…")
	operation.Flags = operationCancelableFlag | operationProgressFlag
	operation.ProgressCurrent = 3
	operation.ProgressTotal = 10
	feedback.transition(&operation, feedbackTestStart)

	feedback.tick(feedbackTestStart.Add(waitingDelay - time.Nanosecond))
	if got := presented(t, feedback); got != "Formatting… · 3/10" {
		t.Fatalf("before waiting boundary = %q", got)
	}
	feedback.tick(feedbackTestStart.Add(waitingDelay))
	if got := presented(t, feedback); got != "Waiting · Formatting… · 3/10 · Esc cancel" {
		t.Fatalf("at waiting boundary = %q", got)
	}
}

func TestFeedbackQueuedFormattingAndKindFallback(t *testing.T) {
	var feedback feedbackState
	operation := testOperation(1, generated.OperationStatusQueued, "")
	operation.Kind = generated.OperationKindGitCommit
	operation.Flags = operationQueueFlag | operationProgressFlag | operationCancelableFlag
	operation.QueuePosition = 2
	operation.QueueTotal = 5
	operation.ProgressCurrent = 7
	operation.ProgressTotal = 10
	feedback.transition(&operation, feedbackTestStart)

	if got := presented(t, feedback); got != "Queued 2/5 · Committing changes · 7/10" {
		t.Fatalf("queued presentation = %q", got)
	}
	feedback.tick(feedbackTestStart.Add(waitingDelay))
	if got := presented(t, feedback); got != "Queued 2/5 · Committing changes · 7/10 · Esc cancel" {
		t.Fatalf("queued cancel presentation = %q", got)
	}

	operation.Flags &^= operationQueueFlag
	feedback.transition(&operation, feedbackTestStart.Add(waitingDelay+time.Millisecond))
	if got := presented(t, feedback); !strings.HasPrefix(got, "Queued · Committing changes") {
		t.Fatalf("queue numbers should be omitted when unavailable: %q", got)
	}
}

func TestFeedbackSameIdentityUpdatesDoNotRestartDeadlines(t *testing.T) {
	var feedback feedbackState
	operation := testOperation(7, generated.OperationStatusRunning, "Formatting")
	feedback.transition(&operation, feedbackTestStart)
	runningOnset := feedback.runningOnset
	onset := feedback.onset

	updated := operation
	updated.Message = "Formatting buffer"
	updated.Flags = operationProgressFlag | operationCancelableFlag
	updated.ProgressCurrent = 4
	updated.ProgressTotal = 8
	feedback.transition(&updated, feedbackTestStart.Add(90*time.Millisecond))
	if !feedback.runningOnset.Equal(runningOnset) || !feedback.onset.Equal(onset) {
		t.Fatalf("same-ID update restarted deadlines: onset=%v running=%v", feedback.onset, feedback.runningOnset)
	}

	feedback.tick(feedbackTestStart.Add(spinnerDelay))
	if got := presented(t, feedback); !strings.Contains(got, "Formatting buffer · 4/8") || !strings.HasPrefix(got, feedback.spinner()+" ") {
		t.Fatalf("updated running presentation = %q", got)
	}
}

func TestFeedbackRunningDelayStartsWhenSameIdentityEntersRunning(t *testing.T) {
	var feedback feedbackState
	pending := testOperation(1, generated.OperationStatusPending, "Waiting")
	feedback.transition(&pending, feedbackTestStart)
	runningAt := feedbackTestStart.Add(2 * time.Second)
	running := testOperation(1, generated.OperationStatusRunning, "Running")
	feedback.transition(&running, runningAt)

	feedback.tick(runningAt.Add(spinnerDelay - time.Nanosecond))
	if got := presented(t, feedback); got != "Running" {
		t.Fatalf("running spinner started from operation onset: %q", got)
	}
	feedback.tick(runningAt.Add(spinnerDelay))
	if got := presented(t, feedback); !strings.HasPrefix(got, feedback.spinner()+" ") {
		t.Fatalf("running spinner missing at phase boundary: %q", got)
	}
}

func TestFeedbackSpinnerHoldAndSuccessDwellExactBoundaries(t *testing.T) {
	var feedback feedbackState
	running := testOperation(1, generated.OperationStatusRunning, "Formatting")
	feedback.transition(&running, feedbackTestStart)
	feedback.tick(feedbackTestStart.Add(spinnerDelay))

	success := testOperation(1, generated.OperationStatusSuccess, "Formatted")
	feedback.transition(&success, feedbackTestStart.Add(spinnerDelay+spinnerHold-time.Nanosecond))
	if got := presented(t, feedback); !strings.HasPrefix(got, feedback.spinner()+" Formatting") {
		t.Fatalf("success replaced spinner before hold: %q", got)
	}

	visibleAt := feedbackTestStart.Add(spinnerDelay + spinnerHold)
	feedback.tick(visibleAt)
	if got := presented(t, feedback); got != "✓ Formatted" {
		t.Fatalf("success at hold boundary = %q", got)
	}
	feedback.tick(visibleAt.Add(terminalDwell - time.Nanosecond))
	if got := presented(t, feedback); got != "✓ Formatted" {
		t.Fatalf("success disappeared before dwell: %q", got)
	}
	feedback.tick(visibleAt.Add(terminalDwell))
	if _, _, ok := feedback.presentation(); ok {
		t.Fatal("success should disappear at the 1500ms dwell boundary")
	}
}

func TestFeedbackNonSuccessTerminalsReplaceSpinnerImmediately(t *testing.T) {
	statuses := []generated.OperationStatus{
		generated.OperationStatusError,
		generated.OperationStatusTimeout,
		generated.OperationStatusCanceled,
		generated.OperationStatusStale,
	}
	for _, status := range statuses {
		t.Run(presentedStatusName(status), func(t *testing.T) {
			var feedback feedbackState
			running := testOperation(1, generated.OperationStatusRunning, "Running")
			feedback.transition(&running, feedbackTestStart)
			feedback.tick(feedbackTestStart.Add(spinnerDelay))

			terminal := testOperation(1, status, "Stopped")
			feedback.transition(&terminal, feedbackTestStart.Add(spinnerDelay+time.Nanosecond))
			_, gotStatus, ok := feedback.presentation()
			if !ok || gotStatus != status || feedback.hasDeferred {
				t.Fatalf("terminal did not replace spinner immediately: status=%d feedback=%+v", gotStatus, feedback)
			}
		})
	}
}

func TestFeedbackSuccessBeforeSpinnerIsImmediate(t *testing.T) {
	var feedback feedbackState
	running := testOperation(1, generated.OperationStatusRunning, "Formatting")
	feedback.transition(&running, feedbackTestStart)
	success := testOperation(1, generated.OperationStatusSuccess, "Formatted")
	visibleAt := feedbackTestStart.Add(spinnerDelay - time.Nanosecond)
	feedback.transition(&success, visibleAt)
	if got := presented(t, feedback); got != "✓ Formatted" {
		t.Fatalf("fast success = %q", got)
	}
	if !feedback.terminalUntil.Equal(visibleAt.Add(terminalDwell)) {
		t.Fatalf("success dwell deadline = %v", feedback.terminalUntil)
	}
}

func TestFeedbackTerminalReplacementAndDwellPolicies(t *testing.T) {
	for _, status := range []generated.OperationStatus{generated.OperationStatusError, generated.OperationStatusTimeout} {
		t.Run(presentedStatusName(status), func(t *testing.T) {
			var feedback feedbackState
			operation := testOperation(1, status, "Failed")
			feedback.transition(&operation, feedbackTestStart)
			feedback.tick(feedbackTestStart.Add(10 * terminalDwell))
			if _, _, ok := feedback.presentation(); !ok {
				t.Fatal("error/timeout must remain while BEAM projects it")
			}
			feedback.transition(nil, feedbackTestStart.Add(10*terminalDwell))
			if _, _, ok := feedback.presentation(); ok {
				t.Fatal("error/timeout must clear when BEAM stops projecting it")
			}
		})
	}

	for _, status := range []generated.OperationStatus{generated.OperationStatusCanceled, generated.OperationStatusStale} {
		t.Run(presentedStatusName(status), func(t *testing.T) {
			var feedback feedbackState
			operation := testOperation(1, status, "Stopped")
			feedback.transition(&operation, feedbackTestStart)
			feedback.transition(nil, feedbackTestStart.Add(time.Millisecond))
			feedback.tick(feedbackTestStart.Add(terminalDwell - time.Nanosecond))
			if _, _, ok := feedback.presentation(); !ok {
				t.Fatal("canceled/stale should dwell after projection disappears")
			}
			feedback.tick(feedbackTestStart.Add(terminalDwell))
			if _, _, ok := feedback.presentation(); ok {
				t.Fatal("canceled/stale should clear at dwell boundary")
			}
		})
	}
}

func TestFeedbackDifferentIdentityImmediatelyInvalidatesHoldAndDwell(t *testing.T) {
	t.Run("spinner hold", func(t *testing.T) {
		var feedback feedbackState
		running := testOperation(1, generated.OperationStatusRunning, "Old operation")
		feedback.transition(&running, feedbackTestStart)
		feedback.tick(feedbackTestStart.Add(spinnerDelay))
		success := testOperation(1, generated.OperationStatusSuccess, "Old success")
		feedback.transition(&success, feedbackTestStart.Add(spinnerDelay+time.Millisecond))
		if !feedback.hasDeferred {
			t.Fatal("expected same-ID success to be deferred")
		}

		replacement := testOperation(2, generated.OperationStatusPending, "New operation")
		feedback.transition(&replacement, feedbackTestStart.Add(spinnerDelay+2*time.Millisecond))
		if feedback.hasDeferred || !feedback.terminalUntil.IsZero() || feedback.displayed.OperationID != 2 {
			t.Fatalf("replacement retained prior identity state: %+v", feedback)
		}
		if got := presented(t, feedback); got != "New operation" {
			t.Fatalf("replacement presentation = %q", got)
		}
	})

	t.Run("terminal dwell", func(t *testing.T) {
		var feedback feedbackState
		terminal := testOperation(1, generated.OperationStatusSuccess, "Old success")
		feedback.transition(&terminal, feedbackTestStart)
		oldDeadline := feedback.terminalUntil
		if oldDeadline.IsZero() {
			t.Fatal("expected terminal result to establish a dwell deadline")
		}

		replacement := testOperation(2, generated.OperationStatusPending, "New operation")
		feedback.transition(&replacement, feedbackTestStart.Add(time.Millisecond))
		if !feedback.terminalUntil.IsZero() {
			t.Fatalf("replacement retained terminal deadline %v", feedback.terminalUntil)
		}
		if got := presented(t, feedback); got != "New operation" {
			t.Fatalf("replacement presentation = %q", got)
		}

		feedback.tick(oldDeadline)
		if got := presented(t, feedback); got != "Waiting · New operation" {
			t.Fatalf("replacement did not promote at old dwell deadline: %q", got)
		}
		if feedback.displayed.OperationID != replacement.OperationID {
			t.Fatalf("old dwell deadline restored operation %d", feedback.displayed.OperationID)
		}
	})
}

func TestFeedbackStaleTickCannotRestoreOldIdentity(t *testing.T) {
	var feedback feedbackState
	old := testOperation(1, generated.OperationStatusRunning, "Old")
	feedback.transition(&old, feedbackTestStart)
	replacementAt := feedbackTestStart.Add(200 * time.Millisecond)
	replacement := testOperation(2, generated.OperationStatusPending, "New")
	feedback.transition(&replacement, replacementAt)

	feedback.tick(feedbackTestStart.Add(80 * time.Millisecond))
	if feedback.displayed.OperationID != 2 || presented(t, feedback) != "New" {
		t.Fatalf("stale tick restored old identity: %+v", feedback)
	}
}

func TestFeedbackTickCadenceShortensToExactDeadlines(t *testing.T) {
	var feedback feedbackState
	running := testOperation(1, generated.OperationStatusRunning, "Running")
	feedback.transition(&running, feedbackTestStart)
	if delay, ok := feedback.nextTick(feedbackTestStart, false); !ok || delay != feedbackTickInterval {
		t.Fatalf("first running tick = %v, %v", delay, ok)
	}
	if delay, ok := feedback.nextTick(feedbackTestStart.Add(80*time.Millisecond), false); !ok || delay != 20*time.Millisecond {
		t.Fatalf("deadline tick = %v, %v", delay, ok)
	}

	var queued feedbackState
	operation := testOperation(2, generated.OperationStatusQueued, "Queued")
	queued.transition(&operation, feedbackTestStart)
	if _, ok := queued.nextTick(feedbackTestStart, false); ok {
		t.Fatal("non-cancelable queued operation has no animation deadline")
	}
	operation.Flags = operationCancelableFlag
	queued.transition(&operation, feedbackTestStart)
	if delay, ok := queued.nextTick(feedbackTestStart.Add(990*time.Millisecond), false); !ok || delay != 10*time.Millisecond {
		t.Fatalf("cancel deadline tick = %v, %v", delay, ok)
	}
}

func presentedStatusName(status generated.OperationStatus) string {
	return fmt.Sprintf("status_%d", status)
}
