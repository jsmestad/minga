package terminal

import (
	"strconv"
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
}

// featureCount is one past the last feature of the schema.
const featureCount = int(generated.TerminalFeatureClipboardOsc52) + 1

// Entry is one line of the report: a feature and what is known about it.
type Entry struct {
	Feature Feature
	Status  Status
}

// NewCapabilities starts detection: every reported feature is pending until the terminal answers or the timeout settles it.
func NewCapabilities() Capabilities {
	var capabilities Capabilities
	for _, feature := range reported {
		capabilities.status[feature] = generated.TerminalFeatureStatusPending
	}
	return capabilities
}

// WithEnvironment settles the features a terminal is known to have from the variables it sets, before it answers anything.
//
// Styled underlines and the underline colour have no query every terminal answers, so the terminals that document
// them are named here. Inside a multiplexer (tmux, screen) the variables describe the outer terminal and the
// multiplexer decides what passes, so nothing is taken from them there: the terminal's own answer, or the timeout, decides.
func (c Capabilities) WithEnvironment(getenv func(string) string) Capabilities {
	if getenv("TMUX") != "" || getenv("STY") != "" || !drawsStyledUnderlines(getenv) {
		return c
	}
	c.Resolve(generated.TerminalFeatureStyledUnderlines, true)
	c.Resolve(generated.TerminalFeatureUnderlineColor, true)
	return c
}

// drawsStyledUnderlines names the terminals that document SGR 4:3 (curly), 4:4 (dotted) and SGR 58 (underline colour).
func drawsStyledUnderlines(getenv func(string) string) bool {
	switch getenv("TERM_PROGRAM") {
	case "ghostty", "WezTerm", "iTerm.app":
		return true
	}
	switch getenv("TERM") {
	case "xterm-kitty", "xterm-ghostty", "wezterm", "foot", "foot-extra", "alacritty":
		return true
	}
	if getenv("KITTY_WINDOW_ID") != "" {
		return true
	}
	// VTE terminals (GNOME Terminal and others) draw them from 0.52: VTE_VERSION is major*10000 + minor*100 + micro.
	if version, err := strconv.Atoi(getenv("VTE_VERSION")); err == nil && version >= 5200 {
		return true
	}
	return false
}

// ObserveTermcap records the terminal's answer to a terminfo query (XTGETTCAP) and reports whether it changed what is known.
// `Smulx` is the styled underline capability and `Setulc` the underline colour. Only an answer that carries the
// capability's value counts: a terminal that names a capability it does not have sends no value.
func (c *Capabilities) ObserveTermcap(content string) bool {
	changed := false
	for _, capability := range strings.Split(content, ";") {
		switch {
		case strings.HasPrefix(capability, "Smulx="):
			changed = c.Resolve(generated.TerminalFeatureStyledUnderlines, true) || changed
		case strings.HasPrefix(capability, "Setulc="):
			changed = c.Resolve(generated.TerminalFeatureUnderlineColor, true) || changed
		}
	}
	return changed
}

// TermcapQueries returns the terminfo capabilities the frontend asks this terminal for at startup.
// Apple's Terminal does not know the query and prints its text into the screen, so it is not asked.
func TermcapQueries(getenv func(string) string) []string {
	if getenv("TERM_PROGRAM") == "Apple_Terminal" {
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

// Resolve records the terminal's answer for a feature and reports whether that changed what is known.
// A feature the terminal lacks ends as its fallback when Minga has one, and as missing otherwise.
// An answer for a feature this frontend does not report is ignored.
func (c *Capabilities) Resolve(feature Feature, present bool) bool {
	current := c.Status(feature)
	if current == generated.TerminalFeatureStatusUnknown {
		return false
	}
	next := absent(feature)
	if present {
		next = generated.TerminalFeatureStatusDetected
	}
	if next == current {
		return false
	}
	c.status[feature] = next
	return true
}

// Expire settles every feature the terminal has not answered for and reports whether any was still pending.
func (c *Capabilities) Expire() bool {
	changed := false
	for _, feature := range reported {
		if c.status[feature] == generated.TerminalFeatureStatusPending {
			c.status[feature] = absent(feature)
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
		entries = append(entries, Entry{Feature: feature, Status: c.Status(feature)})
	}
	return entries
}

func absent(feature Feature) Status {
	if hasFallback(feature) {
		return generated.TerminalFeatureStatusFallback
	}
	return generated.TerminalFeatureStatusMissing
}
