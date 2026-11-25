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
