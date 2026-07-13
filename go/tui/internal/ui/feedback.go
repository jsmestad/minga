package ui

import (
	"fmt"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
)

const (
	feedbackTickInterval = 80 * time.Millisecond
	spinnerDelay         = 100 * time.Millisecond
	spinnerHold          = 500 * time.Millisecond
	waitingDelay         = time.Second
	terminalDwell        = 1500 * time.Millisecond

	operationCancelableFlag = byte(0x01)
	operationQueueFlag      = byte(0x02)
	operationProgressFlag   = byte(0x04)
)

var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

type feedbackTickMsg struct {
	at time.Time
}

func feedbackTick(after time.Duration) tea.Cmd {
	return tea.Tick(after, func(at time.Time) tea.Msg {
		return feedbackTickMsg{at: at}
	})
}

// feedbackState owns only local presentation timing. The latest operation is a
// value copy of the BEAM projection; presentation never mutates or clears the
// semantic StatusBar operation itself.
type feedbackState struct {
	frame   uint64
	ticking bool
	now     time.Time

	latest      generated.GuiStatusBarOperation
	hasLatest   bool
	displayed   generated.GuiStatusBarOperation
	hasDisplay  bool
	deferred    generated.GuiStatusBarOperation
	hasDeferred bool

	onset         time.Time
	runningOnset  time.Time
	spinnerOnAt   time.Time
	terminalUntil time.Time
}

func (f *feedbackState) transition(operation *generated.GuiStatusBarOperation, now time.Time) {
	now = f.monotonic(now)
	if operation == nil {
		f.advance(now)
		f.hasLatest = false
		if !f.hasDisplay || !terminalDwells(f.displayed.Status) {
			f.resetDisplay()
		}
		return
	}

	incoming := *operation
	if !f.hasLatest || incoming.OperationID != f.latest.OperationID {
		f.replaceIdentity(incoming, now)
		return
	}

	f.advance(now)
	previousStatus := f.latest.Status
	f.latest = incoming
	if incoming.Status == previousStatus {
		f.refreshSameStatus(incoming)
		return
	}

	f.hasDeferred = false
	f.terminalUntil = time.Time{}
	switch incoming.Status {
	case generated.OperationStatusPending, generated.OperationStatusQueued:
		f.displayed = incoming
		f.hasDisplay = true
		f.runningOnset = time.Time{}
		f.spinnerOnAt = time.Time{}
	case generated.OperationStatusRunning:
		f.displayed = incoming
		f.hasDisplay = true
		f.runningOnset = now
		f.spinnerOnAt = time.Time{}
	case generated.OperationStatusSuccess:
		if f.hasDisplay && f.displayed.OperationID == incoming.OperationID &&
			f.displayed.Status == generated.OperationStatusRunning && !f.spinnerOnAt.IsZero() &&
			now.Before(f.spinnerOnAt.Add(spinnerHold)) {
			f.deferred = incoming
			f.hasDeferred = true
			return
		}
		f.showTerminal(incoming, now)
	case generated.OperationStatusCanceled, generated.OperationStatusStale:
		f.showTerminal(incoming, now)
	default:
		// Error and timeout remain exactly as long as the BEAM projects them.
		f.displayed = incoming
		f.hasDisplay = true
		f.runningOnset = time.Time{}
		f.spinnerOnAt = time.Time{}
	}
}

func (f *feedbackState) replaceIdentity(operation generated.GuiStatusBarOperation, now time.Time) {
	f.latest = operation
	f.hasLatest = true
	f.displayed = operation
	f.hasDisplay = true
	f.hasDeferred = false
	f.onset = now
	f.runningOnset = time.Time{}
	f.spinnerOnAt = time.Time{}
	f.terminalUntil = time.Time{}

	switch operation.Status {
	case generated.OperationStatusRunning:
		f.runningOnset = now
	case generated.OperationStatusSuccess, generated.OperationStatusCanceled, generated.OperationStatusStale:
		f.terminalUntil = now.Add(terminalDwell)
	}
}

func (f *feedbackState) refreshSameStatus(operation generated.GuiStatusBarOperation) {
	if f.hasDeferred {
		f.deferred = operation
		return
	}
	if f.hasDisplay && f.displayed.OperationID == operation.OperationID && f.displayed.Status == operation.Status {
		f.displayed = operation
	}
}

func (f *feedbackState) showTerminal(operation generated.GuiStatusBarOperation, now time.Time) {
	f.displayed = operation
	f.hasDisplay = true
	f.runningOnset = time.Time{}
	f.spinnerOnAt = time.Time{}
	if terminalDwells(operation.Status) {
		f.terminalUntil = now.Add(terminalDwell)
	}
}

func (f *feedbackState) tick(now time.Time) {
	f.frame++
	f.advance(f.monotonic(now))
}

func (f *feedbackState) advance(now time.Time) {
	if f.hasDisplay && f.displayed.Status == generated.OperationStatusRunning && f.spinnerOnAt.IsZero() &&
		!f.runningOnset.IsZero() && !now.Before(f.runningOnset.Add(spinnerDelay)) {
		f.spinnerOnAt = now
	}

	if f.hasDeferred && !f.spinnerOnAt.IsZero() && !now.Before(f.spinnerOnAt.Add(spinnerHold)) {
		deferred := f.deferred
		f.hasDeferred = false
		f.showTerminal(deferred, now)
	}

	if f.hasDisplay && !f.terminalUntil.IsZero() && !now.Before(f.terminalUntil) {
		f.resetDisplay()
	}
}

func (f *feedbackState) monotonic(now time.Time) time.Time {
	if now.Before(f.now) {
		return f.now
	}
	f.now = now
	return now
}

func (f *feedbackState) resetDisplay() {
	f.hasDisplay = false
	f.hasDeferred = false
	f.runningOnset = time.Time{}
	f.spinnerOnAt = time.Time{}
	f.terminalUntil = time.Time{}
	if !f.hasLatest {
		f.onset = time.Time{}
	}
}

func (f feedbackState) spinner() string {
	return spinnerFrames[int(f.frame)%len(spinnerFrames)]
}

func (f feedbackState) presentation() (string, generated.OperationStatus, bool) {
	if !f.hasDisplay {
		return "", 0, false
	}

	operation := f.displayed
	message := operation.Message
	if message == "" {
		message = operationKindLabel(operation.Kind)
	}

	var text string
	switch operation.Status {
	case generated.OperationStatusPending:
		text = message
		if f.deadlineReached(f.onset.Add(waitingDelay)) {
			text = "Waiting · " + message
		}
	case generated.OperationStatusQueued:
		if operation.Flags&operationQueueFlag != 0 {
			text = fmt.Sprintf("Queued %d/%d · %s", operation.QueuePosition, operation.QueueTotal, message)
		} else {
			text = "Queued · " + message
		}
	case generated.OperationStatusRunning:
		text = message
		if !f.spinnerOnAt.IsZero() {
			text = f.spinner() + " " + message
		}
	case generated.OperationStatusSuccess:
		text = "✓ " + message
	case generated.OperationStatusError:
		text = "✕ Error · " + message
	case generated.OperationStatusTimeout:
		text = "! Timed out · " + message
	case generated.OperationStatusCanceled:
		text = "× Canceled · " + message
	case generated.OperationStatusStale:
		text = "↷ Stale · " + message
	default:
		text = message
	}

	metadata := make([]string, 0, 2)
	if operation.Flags&operationProgressFlag != 0 {
		metadata = append(metadata, fmt.Sprintf("%d/%d", operation.ProgressCurrent, operation.ProgressTotal))
	}
	if activeOperation(operation.Status) && operation.Flags&operationCancelableFlag != 0 && f.deadlineReached(f.onset.Add(waitingDelay)) {
		metadata = append(metadata, "Esc cancel")
	}
	if len(metadata) > 0 {
		text += " · " + strings.Join(metadata, " · ")
	}
	return text, operation.Status, true
}

func (f feedbackState) deadlineReached(deadline time.Time) bool {
	return !deadline.IsZero() && !f.now.Before(deadline)
}

func (f *feedbackState) nextTick(now time.Time, pickerLoading bool) (time.Duration, bool) {
	now = f.monotonic(now)
	f.advance(now)
	deadline := time.Time{}
	animated := pickerLoading

	if f.hasDisplay {
		operation := f.displayed
		switch operation.Status {
		case generated.OperationStatusPending:
			if now.Before(f.onset.Add(waitingDelay)) {
				deadline = f.onset.Add(waitingDelay)
			}
		case generated.OperationStatusQueued:
			if operation.Flags&operationCancelableFlag != 0 && now.Before(f.onset.Add(waitingDelay)) {
				deadline = f.onset.Add(waitingDelay)
			}
		case generated.OperationStatusRunning:
			animated = true
			if f.spinnerOnAt.IsZero() {
				deadline = f.runningOnset.Add(spinnerDelay)
			} else if f.hasDeferred {
				deadline = f.spinnerOnAt.Add(spinnerHold)
			}
			if operation.Flags&operationCancelableFlag != 0 && now.Before(f.onset.Add(waitingDelay)) {
				deadline = earlierDeadline(deadline, f.onset.Add(waitingDelay))
			}
		case generated.OperationStatusSuccess, generated.OperationStatusCanceled, generated.OperationStatusStale:
			if !f.terminalUntil.IsZero() && now.Before(f.terminalUntil) {
				deadline = f.terminalUntil
			}
		}
	}

	if !animated && deadline.IsZero() {
		return 0, false
	}
	delay := feedbackTickInterval
	if !deadline.IsZero() {
		until := deadline.Sub(now)
		if until < delay {
			delay = until
		}
	}
	if delay <= 0 {
		delay = time.Nanosecond
	}
	return delay, true
}

func earlierDeadline(current time.Time, candidate time.Time) time.Time {
	if current.IsZero() || candidate.Before(current) {
		return candidate
	}
	return current
}

func terminalDwells(status generated.OperationStatus) bool {
	return status == generated.OperationStatusSuccess || status == generated.OperationStatusCanceled || status == generated.OperationStatusStale
}

func activeOperation(status generated.OperationStatus) bool {
	return status == generated.OperationStatusPending || status == generated.OperationStatusQueued || status == generated.OperationStatusRunning
}

func operationKindLabel(kind generated.OperationKind) string {
	switch kind {
	case generated.OperationKindExternalFormat:
		return "Formatting"
	case generated.OperationKindGitStage:
		return "Staging changes"
	case generated.OperationKindGitUnstage:
		return "Unstaging changes"
	case generated.OperationKindGitDiscard:
		return "Discarding changes"
	case generated.OperationKindGitStageAll:
		return "Staging all changes"
	case generated.OperationKindGitUnstageAll:
		return "Unstaging all changes"
	case generated.OperationKindGitCommit:
		return "Committing changes"
	case generated.OperationKindLspReferences:
		return "Finding references"
	case generated.OperationKindLspRename:
		return "Renaming"
	default:
		return "Operation"
	}
}
