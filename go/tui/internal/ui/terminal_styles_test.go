package ui

import (
	"image/color"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/jsmestad/minga/go/tui/internal/generated"
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
