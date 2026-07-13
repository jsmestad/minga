package ui

import (
	"image/color"
	"strings"
	"testing"
	"unicode"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
)

func TestRenderStatusMessageSanitizesTerminalText(t *testing.T) {
	tests := []struct {
		name    string
		payload string
		want    string
	}{
		{name: "CSI color", payload: "before\x1b[31mred\x1b[0mafter", want: "beforeredafter"},
		{name: "OSC 8 hyperlink", payload: "see \x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\ now", want: "see link now"},
		{name: "OSC 52 clipboard", payload: "copy\x1b]52;c;Y2xpcGJvYXJk\x07done", want: "copydone"},
		{name: "DCS", payload: "before\x1bP1;2|payload\x1b\\after", want: "beforeafter"},
		{name: "carriage return", payload: "left\rright", want: "left right"},
		{name: "line feed", payload: "left\nright", want: "left right"},
		{name: "standalone controls", payload: "a\tb\x07c\x7fd\u0085e", want: "a b c d e"},
		{name: "printable Unicode and markers", payload: "✓ Привет · 世界 ↷", want: "✓ Привет · 世界 ↷"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := sanitizeTerminalText(tt.payload); got != tt.want {
				t.Fatalf("sanitizeTerminalText() = %q, want %q", got, tt.want)
			}

			for _, source := range []string{"notice", "operation"} {
				t.Run(source, func(t *testing.T) {
					model := New(120, 8, nil, nil)
					foreground := model.palette().Warning()
					statusMessage := tt.payload
					wantText := tt.want
					if source == "operation" {
						operation := testOperation(1, generated.OperationStatusError, tt.payload)
						model.feedback.transition(&operation, feedbackTestStart)
						foreground = model.palette().Error()
						statusMessage = ""
						wantText = "✕ Error · " + tt.want
					}

					want := lipgloss.NewStyle().Bold(true).Foreground(foreground).Background(model.palette().ChromeSurface()).Render(wantText)
					if got := model.renderStatusMessage(statusMessage); got != want {
						t.Fatalf("renderStatusMessage() = %q, want %q", got, want)
					}

					line := ansi.Strip(model.renderStatusSegments(protocol.StatusBar{Message: statusMessage}))
					if strings.ContainsAny(line, "\r\n") {
						t.Fatalf("footer rendered multiple lines: %q", line)
					}
					for _, r := range line {
						if unicode.IsControl(r) {
							t.Fatalf("footer retained control rune %U: %q", r, line)
						}
					}
				})
			}
		})
	}
}

func TestRenderStatusMessagePrefersNewNoticeOverRetainedTerminalOperation(t *testing.T) {
	model := New(80, 8, nil, nil)
	palette := model.palette()

	for _, tt := range []struct {
		name   string
		status generated.OperationStatus
	}{
		{name: "success", status: generated.OperationStatusSuccess},
		{name: "error", status: generated.OperationStatusError},
		{name: "timeout", status: generated.OperationStatusTimeout},
		{name: "canceled", status: generated.OperationStatusCanceled},
		{name: "stale", status: generated.OperationStatusStale},
	} {
		t.Run(tt.name, func(t *testing.T) {
			model.feedback = feedbackState{}
			operation := testOperation(1, tt.status, "Old terminal result")
			model.feedback.transition(&operation, feedbackTestStart)

			want := lipgloss.NewStyle().Bold(true).Foreground(palette.Warning()).Background(palette.ChromeSurface()).Render("Saved")
			if got := model.renderStatusMessage("Saved"); got != want {
				t.Fatalf("terminal operation suppressed notice: got %q, want %q", got, want)
			}
		})
	}
}

func TestRenderStatusMessageUsesSemanticPaletteRoles(t *testing.T) {
	model := New(80, 8, nil, nil)
	palette := model.palette()
	tests := []struct {
		name       string
		status     generated.OperationStatus
		foreground color.Color
	}{
		{name: "pending", status: generated.OperationStatusPending, foreground: palette.ChromeText()},
		{name: "queued", status: generated.OperationStatusQueued, foreground: palette.ChromeText()},
		{name: "running", status: generated.OperationStatusRunning, foreground: palette.Accent()},
		{name: "success", status: generated.OperationStatusSuccess, foreground: palette.Hint()},
		{name: "error", status: generated.OperationStatusError, foreground: palette.Error()},
		{name: "timeout", status: generated.OperationStatusTimeout, foreground: palette.Warning()},
		{name: "canceled", status: generated.OperationStatusCanceled, foreground: palette.Muted()},
		{name: "stale", status: generated.OperationStatusStale, foreground: palette.Info()},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			model.feedback = feedbackState{}
			operation := testOperation(1, tt.status, "Formatting")
			model.feedback.transition(&operation, feedbackTestStart)
			text, _, visible := model.feedback.presentation()
			if !visible {
				t.Fatal("operation presentation is not visible")
			}

			statusMessage := "fallback notice"
			if !activeOperation(tt.status) {
				statusMessage = ""
			}

			want := lipgloss.NewStyle().Bold(true).Foreground(tt.foreground).Background(palette.ChromeSurface()).Render(text)
			if got := model.renderStatusMessage(statusMessage); got != want {
				t.Fatalf("raw styled output = %q, want palette-styled %q", got, want)
			}
		})
	}
}
