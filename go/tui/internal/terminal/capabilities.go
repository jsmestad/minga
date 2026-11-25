package terminal

import (
	"strings"
	"time"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// DetectionTimeout is how long the frontend waits for the terminal to answer a capability query.
// A feature still pending after it is settled as missing, or as its fallback: a terminal that never answers must not stay "pending".
const DetectionTimeout = 2 * time.Second

// Feature is a terminal feature the frontend detects, as named in the protocol schema.
type Feature = generated.TerminalFeature

// Status is what the frontend knows about one feature, as named in the protocol schema.
type Status = generated.TerminalFeatureStatus

// reported lists the features this frontend detects, in report order.
// A feature that is not listed is not reported, and the BEAM shows it as unknown, until the code that uses it also detects it.
var reported = []Feature{
	generated.TerminalFeatureTrueColor,
	generated.TerminalFeatureStyledUnderlines,
	generated.TerminalFeatureUnderlineColor,
	generated.TerminalFeatureKittyKeyboard,
	generated.TerminalFeatureSynchronizedOutput,
	generated.TerminalFeatureFocusReporting,
}

// hasFallback says whether Minga replaces a feature the terminal lacks (docs/design/tui.md, "Terminal capabilities").
// Without true colour it uses the 256 or 16 colour profile, without styled underlines a plain underline, without an
// underline colour the text colour, and without the Kitty keyboard protocol keys keep their legacy meaning.
// Nothing replaces synchronized output or focus reporting.
func hasFallback(feature Feature) bool {
	switch feature {
	case generated.TerminalFeatureTrueColor, generated.TerminalFeatureStyledUnderlines,
		generated.TerminalFeatureUnderlineColor, generated.TerminalFeatureKittyKeyboard:
		return true
	default:
		return false
	}
}

// Capabilities is what this frontend knows about the features of its host terminal.
//
// It is the one value behind both the frontend's own choices (Supports) and the report sent to the BEAM (Entries),
// so what `:checkhealth terminal` lists is what the frontend does.
type Capabilities struct {
	// status is indexed by feature. A feature this frontend does not report stays unknown.
	status [featureCount]Status
	// source says how each status was settled.
	source [featureCount]Source
}

// Source says how a feature's status was settled, so a user can see why a terminal is treated as it is.
type Source uint8

const (
	// SourceUnsettled: nothing decided yet (the feature is pending), or the frontend does not detect the feature.
	SourceUnsettled Source = iota
	// SourceAnswered: the terminal answered a query, or showed the feature by using it.
	SourceAnswered
	// SourceKnownTerminal: the terminal is in the table of known terminals.
	SourceKnownTerminal
	// SourceTimeout: the terminal did not answer in time.
	SourceTimeout
)

// featureCount is one past the last feature of the schema.
const featureCount = int(generated.TerminalFeatureClipboardOsc52) + 1

// Entry is one line of the report: a feature, what is known about it, and how that was settled.
type Entry struct {
	Feature Feature
	Status  Status
	Source  Source
}

// NewCapabilities starts detection: every reported feature is pending until the terminal answers or the timeout settles it.
func NewCapabilities() Capabilities {
	var capabilities Capabilities
	for _, feature := range reported {
		capabilities.status[feature] = generated.TerminalFeatureStatusPending
	}
	return capabilities
}

// WithEnvironment settles the features the terminal is taken to have because it is in the table of known terminals.
// A later answer from the terminal itself replaces that verdict.
func (c Capabilities) WithEnvironment(getenv func(string) string) Capabilities {
	terminal, ok := knownTerminal(getenv)
	if !ok {
		return c
	}
	for _, feature := range terminal.Features {
		c.settle(feature, generated.TerminalFeatureStatusDetected, SourceKnownTerminal)
	}
	return c
}

// ObserveTermcap records the terminal's answer to a terminfo query (XTGETTCAP) and reports whether it changed what is known.
//
// `Smulx` is the styled underline capability and `Setulc` the underline colour. An answer that carries the
// capability's value says the terminal has it. An answer that names the capability without a value says it does not.
// Either way it is the terminal speaking, so it replaces what the table of known terminals said.
func (c *Capabilities) ObserveTermcap(content string) bool {
	changed := false
	for _, capability := range strings.Split(content, ";") {
		name, value, hasValue := strings.Cut(capability, "=")
		var feature Feature
		switch name {
		case "Smulx":
			feature = generated.TerminalFeatureStyledUnderlines
		case "Setulc":
			feature = generated.TerminalFeatureUnderlineColor
		default:
			continue
		}
		changed = c.Resolve(feature, hasValue && value != "") || changed
	}
	return changed
}

// TermcapQueries returns the terminfo capabilities the frontend asks this terminal for at startup.
//
// Two places are not asked, as Bubble Tea does not ask them for its own queries: Apple's Terminal does not know the
// query and prints its text into the screen, and over SSH the terminal at the other end is not the one the variables
// describe, so it may be one that prints the query too.
func TermcapQueries(getenv func(string) string) []string {
	if strings.Contains(getenv("TERM_PROGRAM"), "Apple") || getenv("SSH_TTY") != "" {
		return nil
	}
	return []string{"Smulx", "Setulc"}
}

// Status returns what is known about a feature. A feature this frontend does not detect is unknown.
func (c Capabilities) Status(feature Feature) Status {
	if int(feature) >= featureCount {
		return generated.TerminalFeatureStatusUnknown
	}
	return c.status[feature]
}

// Supports reports whether the frontend may use a feature: only one the terminal was seen to have.
func (c Capabilities) Supports(feature Feature) bool {
	return c.Status(feature) == generated.TerminalFeatureStatusDetected
}

// Resolve records the terminal's own answer for a feature and reports whether that changed what is known.
// A feature the terminal lacks ends as its fallback when Minga has one, and as missing otherwise.
// The terminal's answer replaces any earlier verdict, also one from the table of known terminals.
// An answer for a feature this frontend does not report is ignored.
func (c *Capabilities) Resolve(feature Feature, present bool) bool {
	next := absent(feature)
	if present {
		next = generated.TerminalFeatureStatusDetected
	}
	return c.settle(feature, next, SourceAnswered)
}

// settle records a verdict and where it came from, and reports whether the status changed.
func (c *Capabilities) settle(feature Feature, status Status, source Source) bool {
	current := c.Status(feature)
	if current == generated.TerminalFeatureStatusUnknown {
		return false
	}
	c.source[feature] = source
	if status == current {
		return false
	}
	c.status[feature] = status
	return true
}

// Source returns how a feature's status was settled.
func (c Capabilities) Source(feature Feature) Source {
	if int(feature) >= featureCount {
		return SourceUnsettled
	}
	return c.source[feature]
}

// Expire settles every feature the terminal has not answered for and reports whether any was still pending.
func (c *Capabilities) Expire() bool {
	changed := false
	for _, feature := range reported {
		if c.status[feature] == generated.TerminalFeatureStatusPending {
			c.settle(feature, absent(feature), SourceTimeout)
			changed = true
		}
	}
	return changed
}

// Pending reports whether the terminal still owes an answer for some feature.
func (c Capabilities) Pending() bool {
	for _, feature := range reported {
		if c.status[feature] == generated.TerminalFeatureStatusPending {
			return true
		}
	}
	return false
}

// Entries returns the complete report in a stable order.
func (c Capabilities) Entries() []Entry {
	entries := make([]Entry, 0, len(reported))
	for _, feature := range reported {
		entries = append(entries, Entry{Feature: feature, Status: c.Status(feature), Source: c.Source(feature)})
	}
	return entries
}

func absent(feature Feature) Status {
	if hasFallback(feature) {
		return generated.TerminalFeatureStatusFallback
	}
	return generated.TerminalFeatureStatusMissing
}
