package ui

import (
	"image/color"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/protocol"
	"github.com/jsmestad/minga/go/tui/internal/terminal"
)

func sameColor(a, b color.Color) bool {
	if a == nil || b == nil {
		return a == b
	}
	ar, ag, ab, aa := a.RGBA()
	br, bg, bb, ba := b.RGBA()
	return ar == br && ag == bg && ab == bb && aa == ba
}

func TestDiagnosticsUseTheUnderlineTheTerminalCanDraw(t *testing.T) {
	const (
		plain  = "no styled underlines"
		styled = "styled underlines, no underline colour"
		full   = "styled underlines and underline colour"
	)
	for _, tc := range []struct {
		name      string
		terminal  string
		severity  byte
		underline lipgloss.Underline
		muted     bool
	}{
		{"an error is curly", full, 0, lipgloss.UnderlineCurly, false},
		{"a warning is dotted", full, 1, lipgloss.UnderlineDotted, false},
		{"an info is dotted and faint", full, 2, lipgloss.UnderlineDotted, true},
		{"a hint is dotted and faint", full, 3, lipgloss.UnderlineDotted, true},
		{"an error without underline colour is still curly", styled, 0, lipgloss.UnderlineCurly, false},
		{"a warning without underline colour is still dotted", styled, 1, lipgloss.UnderlineDotted, false},
		{"an error falls back to a plain underline", plain, 0, lipgloss.UnderlineSingle, false},
		{"a warning falls back to a plain underline", plain, 1, lipgloss.UnderlineSingle, false},
		{"a hint falls back to a plain underline", plain, 3, lipgloss.UnderlineSingle, false},
	} {
		t.Run(tc.name+" ("+tc.terminal+")", func(t *testing.T) {
			model := New(80, 24, nil)
			model.capabilities.Resolve(generated.TerminalFeatureStyledUnderlines, tc.terminal != plain)
			model.capabilities.Resolve(generated.TerminalFeatureUnderlineColor, tc.terminal == full)
			text := lipgloss.Color("#123456")

			style := model.diagnosticStyle(lipgloss.NewStyle().Foreground(text), tc.severity)

			if got := style.GetUnderlineStyle(); got != tc.underline {
				t.Fatalf("underline = %v, want %v", got, tc.underline)
			}
			tone := model.palette().Diagnostic(tc.severity)
			if tc.muted {
				tone = model.palette().Muted()
			}
			if tc.terminal == full {
				// The text keeps its own colour; only the underline carries the severity.
				if !sameColor(style.GetForeground(), text) || !sameColor(style.GetUnderlineColor(), tone) {
					t.Fatalf("foreground %v, underline colour %v; want the text colour and %v", style.GetForeground(), style.GetUnderlineColor(), tone)
				}
			} else if !sameColor(style.GetForeground(), tone) {
				// Without an underline colour the underline has the text's colour, so the text takes the severity's.
				t.Fatalf("foreground = %v, want %v", style.GetForeground(), tone)
			}
		})
	}
}

func TestAPendingTerminalDrawsThePlainUnderline(t *testing.T) {
	model := New(80, 24, nil)
	style := model.diagnosticStyle(lipgloss.NewStyle(), 0)
	if style.GetUnderlineStyle() != lipgloss.UnderlineSingle {
		t.Fatal("before the terminal answered, a diagnostic must use the underline every terminal draws")
	}
}

func TestTheTerminfoAnswerTurnsStyledUnderlinesOn(t *testing.T) {
	model, _ := terminalModel()
	for _, msg := range []tea.Msg{tea.CapabilityMsg{Content: "Smulx=\x1b[4:%p1%dm"}, tea.CapabilityMsg{Content: "Setulc=\x1b[58:2::%p1%dm"}} {
		updated, _ := model.Update(msg)
		model = updated.(Model)
	}
	if !model.capabilities.Supports(generated.TerminalFeatureStyledUnderlines) || !model.capabilities.Supports(generated.TerminalFeatureUnderlineColor) {
		t.Fatal("a terminfo answer with a value must mark the feature as detected")
	}
	if model.diagnosticStyle(lipgloss.NewStyle(), 0).GetUnderlineStyle() != lipgloss.UnderlineCurly {
		t.Fatal("an error must be curly once the terminal said it draws styled underlines")
	}

	// A name without a value is a terminal saying it does not have the capability.
	other, _ := terminalModel()
	updated, _ := other.Update(tea.CapabilityMsg{Content: "Smulx"})
	if updated.(Model).capabilities.Supports(generated.TerminalFeatureStyledUnderlines) {
		t.Fatal("a terminfo answer without a value must not turn the feature on")
	}
}

func TestFocusBordersDimWhileTheTerminalIsInTheBackground(t *testing.T) {
	model, _ := terminalModel()
	quiet := model.palette().TreeSeparator()

	if !sameColor(model.palette().FocusBorder(quiet), model.palette().Accent()) {
		t.Fatal("a terminal that reported nothing is treated as focused: the focus border has the accent")
	}

	updated, _ := model.Update(tea.BlurMsg{})
	model = updated.(Model)
	if !sameColor(model.palette().FocusBorder(quiet), quiet) {
		t.Fatal("in the background no pane has the keyboard: the focus border takes its quiet colour")
	}
	if !sameColor(model.palette().AgentInputBorder(), model.palette().PopupBorder()) {
		t.Fatal("the composer's border must dim with the other borders")
	}

	updated, _ = model.Update(tea.FocusMsg{})
	model = updated.(Model)
	if !sameColor(model.palette().FocusBorder(quiet), model.palette().Accent()) {
		t.Fatal("back in the foreground the focus border has the accent again")
	}
}

func TestTheDrawnBytesCarryTheUnderlineStyle(t *testing.T) {
	model := New(80, 24, nil)
	plain := model.diagnosticStyle(lipgloss.NewStyle(), 0).Render("x")
	if strings.Contains(plain, "4:3") || strings.Contains(plain, "58:") || strings.Contains(plain, "58;") {
		t.Fatalf("a terminal that was not seen to draw styled underlines got them: %q", plain)
	}

	model.capabilities.Resolve(generated.TerminalFeatureStyledUnderlines, true)
	model.capabilities.Resolve(generated.TerminalFeatureUnderlineColor, true)
	for _, tc := range []struct {
		severity byte
		sgr      string
	}{{0, "4:3"}, {1, "4:4"}, {3, "4:4"}} {
		drawn := model.diagnosticStyle(lipgloss.NewStyle(), tc.severity).Render("x")
		if !strings.Contains(drawn, tc.sgr) {
			t.Fatalf("severity %d: %q does not carry SGR %s", tc.severity, drawn, tc.sgr)
		}
		if !strings.Contains(drawn, "58") {
			t.Fatalf("severity %d: %q does not colour the underline (SGR 58)", tc.severity, drawn)
		}
	}
}

func TestASpaceInsideAStyledDiagnosticKeepsTheUnderline(t *testing.T) {
	model := New(80, 24, nil)
	model.capabilities.Resolve(generated.TerminalFeatureStyledUnderlines, true)
	model.capabilities.Resolve(generated.TerminalFeatureUnderlineColor, true)
	curly := model.diagnosticStyle(lipgloss.NewStyle(), 0)

	for _, text := range []string{" ", "  "} {
		drawn := renderCell(curly, text)
		if !strings.Contains(drawn, "4:3") {
			t.Fatalf("a space inside an error must carry the curly underline: %q", drawn)
		}
		if strings.Count(drawn, " ") != len(text) || strings.Contains(drawn, "x") {
			t.Fatalf("the spaces themselves must be what is drawn: %q", drawn)
		}
	}

	// Text, and anything without a styled underline, is drawn by Lip Gloss as it always was.
	plain := model.diagnosticStyle(lipgloss.NewStyle(), 0).UnderlineStyle(lipgloss.UnderlineSingle)
	for _, tc := range []struct {
		style lipgloss.Style
		text  string
	}{{curly, "ab"}, {curly, "a b"}, {plain, " "}, {lipgloss.NewStyle(), " "}, {curly, ""}} {
		if got, want := renderCell(tc.style, tc.text), tc.style.Render(tc.text); got != want {
			t.Fatalf("renderCell(%q) = %q, want Lip Gloss's own %q", tc.text, got, want)
		}
	}
}

func TestLinesAreRecomposedWhenTheTerminalsFeaturesOrPlaceChange(t *testing.T) {
	window := protocol.WindowContent{
		ID: 1, CursorVisible: true, ContentEpoch: 1,
		Rows: []protocol.WindowRow{{ID: 1, ContentHash: 11, Text: "line one"}, {ID: 2, ContentHash: 22, Text: "line two"}},
	}
	for _, tc := range []struct {
		name       string
		msg        tea.Msg
		recomposed bool
	}{
		{"the terminal says it draws styled underlines", tea.CapabilityMsg{Content: "Smulx=\x1b[4:%p1%dm"}, true},
		{"the terminal window goes to the background", tea.BlurMsg{}, true},
		{"the timeout settles what was pending", capabilityTimeoutMsg{}, true},
		{"an answer for a capability the frontend does not use", tea.CapabilityMsg{Content: "RGB=8"}, false},
		{"a focus event while already in the foreground", tea.FocusMsg{}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := New(80, 24, make(chan []byte, 16))
			m = applyTo(t, m, fullWindowFrame(1, window)...)
			if hits, misses := recomposeCounters(m); hits != 2 || misses != 0 {
				t.Fatalf("warm cache before the message: hits=%d misses=%d, want 2/0", hits, misses)
			}

			updated, _ := m.Update(tc.msg)
			m = updated.(Model)

			// The compose that ran during this Update: misses mean the lines were drawn again, not served from the cache.
			hits, misses := frameCounters(m)
			if recomposed := misses == 2 && hits == 0; recomposed != tc.recomposed {
				t.Fatalf("after the message: hits=%d misses=%d, recomposed should be %v", hits, misses, tc.recomposed)
			}
		})
	}
}

// reportSources returns how the last report says each feature was settled.
func reportSources(packets [][]byte) map[terminal.Feature]terminal.Source {
	var sources map[terminal.Feature]terminal.Source
	for _, packet := range packets {
		if len(packet) < 4 || packet[0] != generated.OPTerminalReport {
			continue
		}
		sources = map[terminal.Feature]terminal.Source{}
		for i := 4; i+2 < len(packet); i += 3 {
			sources[terminal.Feature(packet[i])] = terminal.Source(packet[i+2])
		}
	}
	return sources
}

// The report carries how each feature was settled, so a terminal that confirms what the table said is news:
// `:checkhealth terminal` must not go on saying "known terminal" after the terminal answered.
func TestAConfirmingAnswerFromAKnownTerminalIsReportedWithItsNewSource(t *testing.T) {
	out := make(chan []byte, 16)
	ghostty := func(name string) string {
		if name == "TERM_PROGRAM" {
			return "ghostty"
		}
		return ""
	}
	model := New(80, 24, out).WithTerminalEnvironment(ghostty)
	if !model.capabilities.Supports(generated.TerminalFeatureStyledUnderlines) {
		t.Fatal("a known terminal has styled underlines from the start")
	}

	// The timeout settles the rest: the one settled report goes out.
	updated, _ := model.Update(capabilityTimeoutMsg{})
	model = updated.(Model)
	settled := drainOutboundPackets(out)
	if report := lastReport(settled); report[generated.TerminalFeatureStyledUnderlines] != generated.TerminalFeatureStatusDetected {
		t.Fatalf("settled report = %v", report)
	}
	if sources := reportSources(settled); sources[generated.TerminalFeatureStyledUnderlines] != terminal.SourceKnownTerminal {
		t.Fatalf("settled sources = %v, want styled underlines from the table of known terminals", sources)
	}

	// The terminal then confirms what the table said. The status stays and the source changes.
	updated, _ = model.Update(tea.CapabilityMsg{Content: "Smulx=\x1b[4:%p1%dm"})
	model = updated.(Model)
	confirmed := drainOutboundPackets(out)
	if report := lastReport(confirmed); report[generated.TerminalFeatureStyledUnderlines] != generated.TerminalFeatureStatusDetected {
		t.Fatalf("report after the answer = %v", report)
	}
	if sources := reportSources(confirmed); sources[generated.TerminalFeatureStyledUnderlines] != terminal.SourceAnswered {
		t.Fatalf("sources after the answer = %v, want styled underlines answered by the terminal", sources)
	}

	// The same answer again changes nothing, so nothing is sent.
	updated, _ = model.Update(tea.CapabilityMsg{Content: "Smulx=\x1b[4:%p1%dm"})
	model = updated.(Model)
	if again := lastReport(drainOutboundPackets(out)); again != nil {
		t.Fatalf("an identical report was sent again: %v", again)
	}
}

func TestAForcedFeatureIsReportedAsTheUsersAndDrawnAsForced(t *testing.T) {
	out := make(chan []byte, 16)
	model, problems := New(80, 24, out).WithTerminalOverrides("styled_underlines=on,underline_color=off,true_color=off,bogus=on")
	if len(problems) != 1 {
		t.Fatalf("problems = %v, want the one unusable entry", problems)
	}

	first := [][]byte{model.TerminalReportPacket()}
	if report, sources := lastReport(first), reportSources(first); report[generated.TerminalFeatureStyledUnderlines] != generated.TerminalFeatureStatusDetected ||
		report[generated.TerminalFeatureUnderlineColor] != generated.TerminalFeatureStatusFallback ||
		sources[generated.TerminalFeatureStyledUnderlines] != terminal.SourceUser || sources[generated.TerminalFeatureUnderlineColor] != terminal.SourceUser {
		t.Fatalf("first report = %v, sources %v", report, sources)
	}

	// The terminal says the opposite of both. The user's choice stays, in the report and in what is drawn.
	for _, msg := range []tea.Msg{tea.CapabilityMsg{Content: "Smulx;Setulc=\x1b[58:2::%p1%dm"}, tea.ColorProfileMsg{Profile: colorprofile.TrueColor}, capabilityTimeoutMsg{}} {
		updated, _ := model.Update(msg)
		model = updated.(Model)
	}
	if !model.capabilities.Supports(generated.TerminalFeatureStyledUnderlines) || model.capabilities.Supports(generated.TerminalFeatureUnderlineColor) {
		t.Fatal("what the user forced must decide what is drawn")
	}
	settled := drainOutboundPackets(out)
	if sources := reportSources(settled); sources[generated.TerminalFeatureStyledUnderlines] != terminal.SourceUser || sources[generated.TerminalFeatureTrueColor] != terminal.SourceUser {
		t.Fatalf("settled sources = %v", sources)
	}
	if report := lastReport(settled); report[generated.TerminalFeatureTrueColor] != generated.TerminalFeatureStatusFallback {
		t.Fatalf("true colour forced off = %d, want fallback", report[generated.TerminalFeatureTrueColor])
	}

	// A forced colour profile is what the program is started with. Forced off caps what detection found at 256
	// colours, so a terminal with fewer keeps what it has.
	for detected, want := range map[colorprofile.Profile]colorprofile.Profile{
		colorprofile.TrueColor: colorprofile.ANSI256,
		colorprofile.ANSI256:   colorprofile.ANSI256,
		colorprofile.ANSI:      colorprofile.ANSI,
		colorprofile.ASCII:     colorprofile.ASCII,
		colorprofile.NoTTY:     colorprofile.NoTTY,
	} {
		if profile, forced := model.ForcedColorProfile(detected); !forced || profile != want {
			t.Fatalf("forced off with %v detected = %v, %v; want %v", detected, profile, forced, want)
		}
	}
	forcedOn, _ := New(80, 24, nil).WithTerminalOverrides("true_color=on")
	if profile, forced := forcedOn.ForcedColorProfile(colorprofile.ANSI); !forced || profile != colorprofile.TrueColor {
		t.Fatalf("forced on = %v, %v; want true colour", profile, forced)
	}
	if _, forced := New(80, 24, nil).ForcedColorProfile(colorprofile.ANSI); forced {
		t.Fatal("without an override the profile is detected")
	}
}
