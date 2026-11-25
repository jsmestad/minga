package ui

import (
	"bytes"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/ansi"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/jsmestad/minga/go/tui/internal/terminal"
)

func terminalModel() (Model, chan []byte) {
	out := make(chan []byte, 16)
	return New(80, 24, out), out
}

// lastReport returns the statuses of the last terminal_report among the packets, or nil when none was sent.
func lastReport(packets [][]byte) map[terminal.Feature]terminal.Status {
	var report map[terminal.Feature]terminal.Status
	for _, packet := range packets {
		if len(packet) < 4 || packet[0] != generated.OPTerminalReport {
			continue
		}
		report = map[terminal.Feature]terminal.Status{}
		for i := 4; i+1 < len(packet); i += 2 {
			report[terminal.Feature(packet[i])] = terminal.Status(packet[i+1])
		}
	}
	return report
}

func TestTheFirstReportHasEveryDetectedFeaturePending(t *testing.T) {
	model, _ := terminalModel()
	report := lastReport([][]byte{model.TerminalReportPacket()})
	for _, feature := range []terminal.Feature{generated.TerminalFeatureTrueColor, generated.TerminalFeatureKittyKeyboard, generated.TerminalFeatureSynchronizedOutput, generated.TerminalFeatureFocusReporting} {
		if report[feature] != generated.TerminalFeatureStatusPending {
			t.Fatalf("feature %d = %d before the terminal answered, want pending", feature, report[feature])
		}
	}
}

func TestTheViewAsksTheTerminalToReportFocus(t *testing.T) {
	model, _ := terminalModel()
	if !model.View().ReportFocus {
		t.Fatal("the view must turn on focus reporting")
	}
}

func TestTerminalFocusIsSentToTheBEAMAsTheForeground(t *testing.T) {
	for _, tc := range []struct {
		name string
		msg  tea.Msg
		want []byte
	}{
		{"the terminal got the focus", tea.FocusMsg{}, protocol.EncodeFrontendForeground(true)},
		{"the terminal lost the focus", tea.BlurMsg{}, protocol.EncodeFrontendForeground(false)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model, out := terminalModel()
			updated, _ := model.Update(tc.msg)
			model = updated.(Model)

			packets := drainOutboundPackets(out)
			if len(packets) != 1 || !bytes.Equal(packets[0], tc.want) {
				t.Fatalf("packets = % x, want only % x", packets, tc.want)
			}
			// A focus event also proves that the terminal reports focus.
			if !model.capabilities.Supports(generated.TerminalFeatureFocusReporting) {
				t.Fatal("a focus event must mark focus reporting as detected")
			}
		})
	}
}

var terminalAnswers = []struct {
	name    string
	msg     tea.Msg
	feature terminal.Feature
	want    terminal.Status
}{
	{"the terminal answers the keyboard query", tea.KeyboardEnhancementsMsg{Flags: ansi.KittyDisambiguateEscapeCodes}, generated.TerminalFeatureKittyKeyboard, generated.TerminalFeatureStatusDetected},
	{"a true colour profile", tea.ColorProfileMsg{Profile: colorprofile.TrueColor}, generated.TerminalFeatureTrueColor, generated.TerminalFeatureStatusDetected},
	{"a 256 colour profile uses the colour fallback", tea.ColorProfileMsg{Profile: colorprofile.ANSI256}, generated.TerminalFeatureTrueColor, generated.TerminalFeatureStatusFallback},
	{"focus reporting is a mode the terminal knows", tea.ModeReportMsg{Mode: ansi.ModeFocusEvent, Value: ansi.ModeReset}, generated.TerminalFeatureFocusReporting, generated.TerminalFeatureStatusDetected},
	{"focus reporting is a mode the terminal does not know", tea.ModeReportMsg{Mode: ansi.ModeFocusEvent, Value: ansi.ModeNotRecognized}, generated.TerminalFeatureFocusReporting, generated.TerminalFeatureStatusMissing},
	{"synchronized output is a mode the terminal knows", tea.ModeReportMsg{Mode: ansi.ModeSynchronizedOutput, Value: ansi.ModeSet}, generated.TerminalFeatureSynchronizedOutput, generated.TerminalFeatureStatusDetected},
	{"synchronized output is a mode the terminal does not know", tea.ModeReportMsg{Mode: ansi.ModeSynchronizedOutput, Value: ansi.ModeNotRecognized}, generated.TerminalFeatureSynchronizedOutput, generated.TerminalFeatureStatusMissing},
	{"synchronized output is permanently off: it cannot be used", tea.ModeReportMsg{Mode: ansi.ModeSynchronizedOutput, Value: ansi.ModePermanentlyReset}, generated.TerminalFeatureSynchronizedOutput, generated.TerminalFeatureStatusMissing},
	{"focus reporting is permanently off: it cannot be used", tea.ModeReportMsg{Mode: ansi.ModeFocusEvent, Value: ansi.ModePermanentlyReset}, generated.TerminalFeatureFocusReporting, generated.TerminalFeatureStatusMissing},
}

func TestATerminalAnswerSettlesItsFeatureAndWaitsForTheOthers(t *testing.T) {
	for _, tc := range terminalAnswers {
		t.Run(tc.name, func(t *testing.T) {
			model, out := terminalModel()
			updated, _ := model.Update(tc.msg)
			model = updated.(Model)

			if got := model.capabilities.Status(tc.feature); got != tc.want {
				t.Fatalf("the frontend holds %d, want %d", got, tc.want)
			}
			// The other answers are still open, so the report waits: one packet per answer would be startup noise.
			if report := lastReport(drainOutboundPackets(out)); report != nil {
				t.Fatalf("a report went out while answers were pending: %v", report)
			}
		})
	}
}

func TestTheReportGoesOutOnceWhenTheLastAnswerIsIn(t *testing.T) {
	model, out := terminalModel()
	answers := []tea.Msg{
		tea.ColorProfileMsg{Profile: colorprofile.TrueColor},
		tea.KeyboardEnhancementsMsg{Flags: ansi.KittyDisambiguateEscapeCodes},
		tea.ModeReportMsg{Mode: ansi.ModeSynchronizedOutput, Value: ansi.ModeNotRecognized},
		tea.ModeReportMsg{Mode: ansi.ModeFocusEvent, Value: ansi.ModeReset},
	}
	for i, msg := range answers {
		updated, _ := model.Update(msg)
		model = updated.(Model)
		packets := drainOutboundPackets(out)
		if last := i == len(answers)-1; (len(packets) == 1) != last {
			t.Fatalf("after answer %d: %d packets", i+1, len(packets))
		} else if last {
			report := lastReport(packets)
			want := map[terminal.Feature]terminal.Status{
				generated.TerminalFeatureTrueColor:          generated.TerminalFeatureStatusDetected,
				generated.TerminalFeatureKittyKeyboard:      generated.TerminalFeatureStatusDetected,
				generated.TerminalFeatureSynchronizedOutput: generated.TerminalFeatureStatusMissing,
				generated.TerminalFeatureFocusReporting:     generated.TerminalFeatureStatusDetected,
			}
			for feature, status := range want {
				if report[feature] != status || model.capabilities.Status(feature) != status {
					t.Fatalf("feature %d reported %d, held %d, want %d", feature, report[feature], model.capabilities.Status(feature), status)
				}
			}
		}
	}

	// The timeout that follows has nothing to settle, and an answer that repeats is not news.
	for _, msg := range []tea.Msg{capabilityTimeoutMsg{}, answers[0]} {
		updated, _ := model.Update(msg)
		model = updated.(Model)
		if again := lastReport(drainOutboundPackets(out)); again != nil {
			t.Fatalf("a settled, unchanged report was sent again: %v", again)
		}
	}
}

func TestAFocusEventAfterTheTimeoutCorrectsTheReport(t *testing.T) {
	model, out := terminalModel()
	updated, _ := model.Update(capabilityTimeoutMsg{})
	model = updated.(Model)
	if got := lastReport(drainOutboundPackets(out))[generated.TerminalFeatureFocusReporting]; got != generated.TerminalFeatureStatusMissing {
		t.Fatalf("focus reporting after the timeout = %d, want missing", got)
	}

	// The terminal answered no query in time, then reports a focus change: it has the feature after all.
	updated, _ = model.Update(tea.BlurMsg{})
	packets := drainOutboundPackets(out)
	if len(packets) != 2 || !bytes.Equal(packets[0], protocol.EncodeFrontendForeground(false)) {
		t.Fatalf("packets = % x, want the background event and a corrected report", packets)
	}
	if got := lastReport(packets)[generated.TerminalFeatureFocusReporting]; got != generated.TerminalFeatureStatusDetected {
		t.Fatalf("focus reporting after a focus event = %d, want detected", got)
	}
}

func TestTheTimeoutSettlesWhatTheTerminalNeverAnswered(t *testing.T) {
	model, out := terminalModel()
	updated, _ := model.Update(tea.ColorProfileMsg{Profile: colorprofile.TrueColor})
	model = updated.(Model)
	drainOutboundPackets(out)

	updated, _ = model.Update(capabilityTimeoutMsg{})
	model = updated.(Model)

	report := lastReport(drainOutboundPackets(out))
	want := map[terminal.Feature]terminal.Status{
		generated.TerminalFeatureTrueColor:          generated.TerminalFeatureStatusDetected,
		generated.TerminalFeatureKittyKeyboard:      generated.TerminalFeatureStatusFallback,
		generated.TerminalFeatureSynchronizedOutput: generated.TerminalFeatureStatusMissing,
		generated.TerminalFeatureFocusReporting:     generated.TerminalFeatureStatusMissing,
	}
	if len(report) != len(want) {
		t.Fatalf("report = %v, want %v", report, want)
	}
	for feature, status := range want {
		if report[feature] != status {
			t.Fatalf("feature %d = %d after the timeout, want %d", feature, report[feature], status)
		}
	}

	// A second timeout has nothing to settle and sends nothing.
	updated, _ = model.Update(capabilityTimeoutMsg{})
	if again := lastReport(drainOutboundPackets(out)); again != nil {
		t.Fatalf("a settled report was sent again: %v", again)
	}
}

func TestOtherMessagesSendNoReport(t *testing.T) {
	model, out := terminalModel()
	for _, msg := range []tea.Msg{tea.WindowSizeMsg{Width: 80, Height: 24}, tea.ModeReportMsg{Mode: ansi.ModeBracketedPaste, Value: ansi.ModeSet}} {
		updated, _ := model.Update(msg)
		model = updated.(Model)
	}
	if report := lastReport(drainOutboundPackets(out)); report != nil {
		t.Fatalf("an unrelated message produced a report: %v", report)
	}
}
