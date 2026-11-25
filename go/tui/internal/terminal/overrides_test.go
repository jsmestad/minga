package terminal

import (
	"strings"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

func TestOverridesForceAFeatureOnOrOff(t *testing.T) {
	styled, colour, trueColor := generated.TerminalFeatureStyledUnderlines, generated.TerminalFeatureUnderlineColor, generated.TerminalFeatureTrueColor

	caps, problems := NewCapabilities().WithOverrides("styled_underlines=on, underline_color=off,true_color=on")
	if len(problems) != 0 {
		t.Fatalf("problems = %v", problems)
	}
	for feature, want := range map[Feature]Status{styled: detected, colour: fallback, trueColor: detected} {
		if caps.Status(feature) != want || caps.Source(feature) != SourceUser {
			t.Fatalf("feature %d: status %d, source %d; want status %d forced by the user", feature, caps.Status(feature), caps.Source(feature), want)
		}
	}
	if forced, on := caps.Forced(colour); !forced || on {
		t.Fatalf("underline colour: forced %v, on %v; want forced off", forced, on)
	}
	if forced, _ := caps.Forced(generated.TerminalFeatureKittyKeyboard); forced {
		t.Fatal("a feature the user did not name is not forced")
	}
	if caps.Status(generated.TerminalFeatureKittyKeyboard) != pending {
		t.Fatal("a feature the user did not name is detected as usual")
	}
}

// What the user forced is above everything the frontend works out by itself, whatever arrives afterwards.
func TestNothingReplacesWhatTheUserForced(t *testing.T) {
	styled := generated.TerminalFeatureStyledUnderlines
	ghostty := env(map[string]string{"TERM_PROGRAM": "ghostty"})

	for name, later := range map[string]func(*Capabilities){
		"the terminal answers yes":     func(c *Capabilities) { c.ObserveTermcap("Smulx=\\x1b[4:%p1%dm") },
		"the terminal answers no":      func(c *Capabilities) { c.ObserveTermcap("Smulx") },
		"an answer by another path":    func(c *Capabilities) { c.Resolve(styled, true) },
		"the table of known terminals": func(c *Capabilities) { *c = c.WithEnvironment(ghostty) },
		"the timeout":                  func(c *Capabilities) { c.Expire() },
		"all of them, one after another": func(c *Capabilities) {
			*c = c.WithEnvironment(ghostty)
			c.ObserveTermcap("Smulx=\\x1b[4:%p1%dm")
			c.Expire()
		},
	} {
		for setting, want := range map[string]Status{"on": detected, "off": fallback} {
			t.Run(name+", forced "+setting, func(t *testing.T) {
				caps, _ := NewCapabilities().WithOverrides("styled_underlines=" + setting)
				later(&caps)
				if caps.Status(styled) != want || caps.Source(styled) != SourceUser {
					t.Fatalf("status %d, source %d; want status %d forced by the user", caps.Status(styled), caps.Source(styled), want)
				}
			})
		}
	}
}

// The other sources keep their order: the terminal's answer replaces the table and the timeout, as before.
func TestWithoutAnOverrideTheTerminalsAnswerStillWins(t *testing.T) {
	styled := generated.TerminalFeatureStyledUnderlines
	caps := NewCapabilities().WithEnvironment(env(map[string]string{"TERM_PROGRAM": "ghostty"}))
	caps.ObserveTermcap("Smulx")
	if caps.Status(styled) != fallback || caps.Source(styled) != SourceAnswered {
		t.Fatalf("status %d, source %d", caps.Status(styled), caps.Source(styled))
	}
}

func TestABadOverrideEntryIsLeftOutAndReportedAndTheRestApply(t *testing.T) {
	for value, tc := range map[string]struct {
		problems int
		says     string
		styled   Status
	}{
		"":                                    {0, "", pending},
		" , ,":                                {0, "", pending},
		"styled_underlines=on":                {0, "", detected},
		"styled_underlines":                   {1, "not feature=on or feature=off", pending},
		"styled_underlines=yes":               {1, "must be on or off", pending},
		"styled_underlines=":                  {1, "must be on or off", pending},
		"=on":                                 {1, "cannot be forced", pending},
		"curly=on":                            {1, "cannot be forced", pending},
		"kitty_keyboard=off":                  {1, "cannot be forced", pending},
		"focus_reporting=on":                  {1, "cannot be forced", pending},
		"hyperlinks=on":                       {1, "cannot be forced", pending},
		"curly=on,styled_underlines=on,bogus": {2, "cannot be forced", detected},
		"styled_underlines=on,styled_underlines=x":  {1, "must be on or off", detected},
		"STYLED_UNDERLINES=on":                      {1, "cannot be forced", pending},
		"styled_underlines=on;underline_color=off":  {1, "must be on or off", pending},
		"styled_underlines = off , true_color = on": {0, "", fallback},
	} {
		t.Run(value, func(t *testing.T) {
			caps, problems := NewCapabilities().WithOverrides(value)
			if len(problems) != tc.problems {
				t.Fatalf("problems = %v, want %d", problems, tc.problems)
			}
			if tc.says != "" && !strings.Contains(strings.Join(problems, "; "), tc.says) {
				t.Fatalf("problems = %v, want one that says %q", problems, tc.says)
			}
			if caps.Status(generated.TerminalFeatureStyledUnderlines) != tc.styled {
				t.Fatalf("styled underlines = %d, want %d", caps.Status(generated.TerminalFeatureStyledUnderlines), tc.styled)
			}
		})
	}
}

func TestOnlyFeaturesTheFrontendDecidesCanBeForced(t *testing.T) {
	want := map[string]Feature{
		"true_color":        generated.TerminalFeatureTrueColor,
		"styled_underlines": generated.TerminalFeatureStyledUnderlines,
		"underline_color":   generated.TerminalFeatureUnderlineColor,
	}
	if len(forceable) != len(want) {
		t.Fatalf("forceable = %v: the BEAM's list in MingaEditor.Frontend.TerminalOverrides must name the same features", forceable)
	}
	for name, feature := range want {
		if forceable[name] != feature {
			t.Fatalf("%s is not forceable", name)
		}
	}
}
