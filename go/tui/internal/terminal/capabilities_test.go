package terminal

import (
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

const (
	pending  = generated.TerminalFeatureStatusPending
	detected = generated.TerminalFeatureStatusDetected
	missing  = generated.TerminalFeatureStatusMissing
	fallback = generated.TerminalFeatureStatusFallback
	unknown  = generated.TerminalFeatureStatusUnknown
)

func TestEveryDetectedFeatureStartsPendingAndTheOthersAreUnknown(t *testing.T) {
	caps := NewCapabilities()
	for _, entry := range caps.Entries() {
		if entry.Status != pending {
			t.Fatalf("feature %d starts as %d, want pending", entry.Feature, entry.Status)
		}
		if caps.Supports(entry.Feature) {
			t.Fatalf("feature %d is used before the terminal answered", entry.Feature)
		}
	}
	for _, feature := range []Feature{generated.TerminalFeatureHyperlinks, generated.TerminalFeatureUnknown, 200} {
		if got := caps.Status(feature); got != unknown {
			t.Fatalf("feature %d that this frontend does not detect = %d, want unknown", feature, got)
		}
	}
}

func TestAnAnswerSettlesAFeatureAsDetectedItsFallbackOrMissing(t *testing.T) {
	for _, tc := range []struct {
		name    string
		feature Feature
		present bool
		want    Status
	}{
		{"true colour seen", generated.TerminalFeatureTrueColor, true, detected},
		{"no true colour: the 256 or 16 colour profile replaces it", generated.TerminalFeatureTrueColor, false, fallback},
		{"styled underlines seen", generated.TerminalFeatureStyledUnderlines, true, detected},
		{"no styled underlines: a plain underline replaces them", generated.TerminalFeatureStyledUnderlines, false, fallback},
		{"underline colour seen", generated.TerminalFeatureUnderlineColor, true, detected},
		{"no underline colour: the text colour replaces it", generated.TerminalFeatureUnderlineColor, false, fallback},
		{"kitty keyboard seen", generated.TerminalFeatureKittyKeyboard, true, detected},
		{"no kitty keyboard: keys keep their legacy meaning", generated.TerminalFeatureKittyKeyboard, false, fallback},
		{"synchronized output seen", generated.TerminalFeatureSynchronizedOutput, true, detected},
		{"no synchronized output: nothing replaces it", generated.TerminalFeatureSynchronizedOutput, false, missing},
		{"focus reporting seen", generated.TerminalFeatureFocusReporting, true, detected},
		{"no focus reporting: nothing replaces it", generated.TerminalFeatureFocusReporting, false, missing},
	} {
		t.Run(tc.name, func(t *testing.T) {
			caps := NewCapabilities()
			if !caps.Resolve(tc.feature, tc.present) {
				t.Fatal("the first answer must change what is known")
			}
			if got := caps.Status(tc.feature); got != tc.want {
				t.Fatalf("status = %d, want %d", got, tc.want)
			}
			if caps.Supports(tc.feature) != (tc.want == detected) {
				t.Fatalf("Supports = %v for status %d", caps.Supports(tc.feature), tc.want)
			}
			if caps.Resolve(tc.feature, tc.present) {
				t.Fatal("the same answer again changes nothing")
			}
		})
	}
}

func TestALateAnswerCorrectsAnEarlierOne(t *testing.T) {
	caps := NewCapabilities()
	caps.Expire()
	if got := caps.Status(generated.TerminalFeatureFocusReporting); got != missing {
		t.Fatalf("after the timeout = %d, want missing", got)
	}
	// The terminal reports a focus change after the timeout: it has the feature after all.
	if !caps.Resolve(generated.TerminalFeatureFocusReporting, true) || !caps.Supports(generated.TerminalFeatureFocusReporting) {
		t.Fatal("a later answer must replace the timeout's verdict")
	}
}

func TestTheTimeoutLeavesNothingPending(t *testing.T) {
	caps := NewCapabilities()
	caps.Resolve(generated.TerminalFeatureTrueColor, true)

	if !caps.Expire() {
		t.Fatal("the timeout must settle the features the terminal did not answer for")
	}
	want := map[Feature]Status{
		generated.TerminalFeatureTrueColor:          detected,
		generated.TerminalFeatureStyledUnderlines:   fallback,
		generated.TerminalFeatureUnderlineColor:     fallback,
		generated.TerminalFeatureKittyKeyboard:      fallback,
		generated.TerminalFeatureSynchronizedOutput: missing,
		generated.TerminalFeatureFocusReporting:     missing,
	}
	entries := caps.Entries()
	if len(entries) != len(want) {
		t.Fatalf("entries = %d, want %d", len(entries), len(want))
	}
	for _, entry := range entries {
		if entry.Status != want[entry.Feature] {
			t.Fatalf("feature %d = %d, want %d", entry.Feature, entry.Status, want[entry.Feature])
		}
	}
	if caps.Expire() {
		t.Fatal("a second timeout has nothing left to settle")
	}
}

func TestAnAnswerForAFeatureThisFrontendDoesNotDetectIsIgnored(t *testing.T) {
	caps := NewCapabilities()
	if caps.Resolve(generated.TerminalFeatureHyperlinks, true) || caps.Status(generated.TerminalFeatureHyperlinks) != unknown {
		t.Fatal("an undetected feature must stay unknown")
	}
}

func TestCapabilitiesAreAValue(t *testing.T) {
	first := NewCapabilities()
	second := first
	second.Resolve(generated.TerminalFeatureTrueColor, true)
	if first.Status(generated.TerminalFeatureTrueColor) != pending {
		t.Fatal("resolving a copy must not change the original")
	}
}

func env(vars map[string]string) func(string) string {
	return func(name string) string { return vars[name] }
}

func TestStyledUnderlinesAreKnownFromTheTerminalsThatDocumentThem(t *testing.T) {
	for _, tc := range []struct {
		name string
		vars map[string]string
		want Status
	}{
		{"Ghostty", map[string]string{"TERM_PROGRAM": "ghostty", "TERM": "xterm-ghostty"}, detected},
		{"Kitty by TERM", map[string]string{"TERM": "xterm-kitty"}, detected},
		{"Kitty by its window id", map[string]string{"TERM": "xterm-256color", "KITTY_WINDOW_ID": "1"}, detected},
		{"WezTerm", map[string]string{"TERM_PROGRAM": "WezTerm", "TERM": "xterm-256color"}, detected},
		{"iTerm", map[string]string{"TERM_PROGRAM": "iTerm.app", "TERM": "xterm-256color"}, detected},
		{"foot", map[string]string{"TERM": "foot"}, detected},
		{"Alacritty", map[string]string{"TERM": "alacritty"}, detected},
		{"a VTE terminal from 0.52", map[string]string{"TERM": "xterm-256color", "VTE_VERSION": "7600"}, detected},
		{"an older VTE terminal waits for the terminal's answer", map[string]string{"TERM": "xterm-256color", "VTE_VERSION": "5002"}, pending},
		{"Apple's Terminal waits for the timeout", map[string]string{"TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-256color"}, pending},
		{"an unknown terminal waits for the terminal's answer", map[string]string{"TERM": "xterm-256color"}, pending},
		{"inside tmux the outer terminal's variables say nothing", map[string]string{"TERM_PROGRAM": "ghostty", "TERM": "tmux-256color", "TMUX": "/tmp/tmux-501/default,1,0"}, pending},
		{"inside screen too", map[string]string{"TERM_PROGRAM": "iTerm.app", "TERM": "screen-256color", "STY": "123.pts-0"}, pending},
	} {
		t.Run(tc.name, func(t *testing.T) {
			caps := NewCapabilities().WithEnvironment(env(tc.vars))
			for _, feature := range []Feature{generated.TerminalFeatureStyledUnderlines, generated.TerminalFeatureUnderlineColor} {
				if got := caps.Status(feature); got != tc.want {
					t.Fatalf("feature %d = %d, want %d", feature, got, tc.want)
				}
			}
			// The environment says nothing about the features the terminal is asked for.
			if caps.Status(generated.TerminalFeatureKittyKeyboard) != pending {
				t.Fatal("the environment must not settle a feature the terminal answers for")
			}
		})
	}
}

func TestATerminfoAnswerSettlesTheFeatureEitherWay(t *testing.T) {
	for _, tc := range []struct {
		content string
		styled  Status
		colour  Status
	}{
		{"Smulx=\x1b[4:%p1%dm", detected, pending},
		{"Setulc=\x1b[58:2::%p1%dm", pending, detected},
		{"Smulx=\x1b[4:%p1%dm;Setulc=\x1b[58:2::%p1%dm", detected, detected},
		// A capability named without a value: the terminal says it does not have it.
		{"Smulx", fallback, pending},
		{"Smulx=", fallback, pending},
		{"Setulc", pending, fallback},
		// Answers for other capabilities, and noise, say nothing about these two.
		{"RGB=8", pending, pending},
		{"Smulxx=1", pending, pending},
		{"", pending, pending},
	} {
		caps := NewCapabilities()
		changed := caps.ObserveTermcap(tc.content)
		if caps.Status(generated.TerminalFeatureStyledUnderlines) != tc.styled || caps.Status(generated.TerminalFeatureUnderlineColor) != tc.colour {
			t.Fatalf("%q: styled %d, colour %d", tc.content, caps.Status(generated.TerminalFeatureStyledUnderlines), caps.Status(generated.TerminalFeatureUnderlineColor))
		}
		if changed != (tc.styled != pending || tc.colour != pending) {
			t.Fatalf("%q: changed = %v", tc.content, changed)
		}
	}
}

func TestTheTerminalsOwnAnswerWinsOverTheTable(t *testing.T) {
	ghostty := env(map[string]string{"TERM_PROGRAM": "ghostty"})
	styled := generated.TerminalFeatureStyledUnderlines

	listed := NewCapabilities().WithEnvironment(ghostty)
	if listed.Status(styled) != detected || listed.Source(styled) != SourceKnownTerminal {
		t.Fatalf("a listed terminal: status %d, source %d", listed.Status(styled), listed.Source(styled))
	}

	// The terminal says no although the table said yes: a table goes stale, the terminal does not.
	denied := listed
	if !denied.ObserveTermcap("Smulx") || denied.Status(styled) != fallback || denied.Source(styled) != SourceAnswered {
		t.Fatalf("an answer of no must replace the table: status %d, source %d", denied.Status(styled), denied.Source(styled))
	}

	// The terminal confirms the table: the status stays, and the report can say the terminal answered.
	confirmed := listed
	if confirmed.ObserveTermcap("Smulx=\x1b[4:%p1%dm") {
		t.Fatal("a confirming answer does not change the status")
	}
	if confirmed.Status(styled) != detected || confirmed.Source(styled) != SourceAnswered {
		t.Fatalf("a confirming answer: status %d, source %d", confirmed.Status(styled), confirmed.Source(styled))
	}

	// An unlisted terminal that answers yes gets the feature from its answer alone.
	unlisted := NewCapabilities().WithEnvironment(env(map[string]string{"TERM": "xterm-256color"}))
	unlisted.ObserveTermcap("Smulx=\x1b[4:%p1%dm")
	if unlisted.Status(styled) != detected || unlisted.Source(styled) != SourceAnswered {
		t.Fatalf("an unlisted terminal that answers: status %d, source %d", unlisted.Status(styled), unlisted.Source(styled))
	}
}

func TestEveryVerdictSaysHowItWasSettled(t *testing.T) {
	caps := NewCapabilities().WithEnvironment(env(map[string]string{"TERM_PROGRAM": "iTerm.app"}))
	caps.Resolve(generated.TerminalFeatureTrueColor, true)
	caps.Expire()

	want := map[Feature]Source{
		generated.TerminalFeatureTrueColor:          SourceAnswered,
		generated.TerminalFeatureStyledUnderlines:   SourceKnownTerminal,
		generated.TerminalFeatureUnderlineColor:     SourceKnownTerminal,
		generated.TerminalFeatureKittyKeyboard:      SourceTimeout,
		generated.TerminalFeatureSynchronizedOutput: SourceTimeout,
		generated.TerminalFeatureFocusReporting:     SourceTimeout,
	}
	for _, entry := range caps.Entries() {
		if entry.Source != want[entry.Feature] {
			t.Fatalf("feature %d: source %d, want %d", entry.Feature, entry.Source, want[entry.Feature])
		}
	}
	if NewCapabilities().Source(generated.TerminalFeatureTrueColor) != SourceUnsettled {
		t.Fatal("a pending feature is not settled by anything yet")
	}
}

func TestEveryKnownTerminalSaysWhatItRestsOn(t *testing.T) {
	for _, terminal := range KnownTerminals {
		if terminal.Name == "" || terminal.Basis == "" || len(terminal.Features) == 0 {
			t.Fatalf("the table entry %+v must name the terminal, its basis and its features", terminal.Name)
		}
	}
}

func TestTerminfoIsAskedOnlyWhereTheQueryIsSafe(t *testing.T) {
	for _, tc := range []struct {
		name  string
		vars  map[string]string
		asked bool
	}{
		{"Ghostty", map[string]string{"TERM_PROGRAM": "ghostty"}, true},
		{"an unknown local terminal", map[string]string{"TERM": "xterm-256color"}, true},
		{"Apple's Terminal prints the query into the screen", map[string]string{"TERM_PROGRAM": "Apple_Terminal"}, false},
		{"over SSH the terminal at the other end is unknown, and may be Apple's", map[string]string{"TERM": "xterm-256color", "SSH_TTY": "/dev/ttys004"}, false},
		{"over SSH a forwarded TERM_PROGRAM does not make it safe", map[string]string{"TERM_PROGRAM": "ghostty", "SSH_TTY": "/dev/pts/1"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := TermcapQueries(env(tc.vars))
			if (len(got) == 2) != tc.asked || (!tc.asked && got != nil) {
				t.Fatalf("queries = %v, asked = %v", got, tc.asked)
			}
		})
	}
}
