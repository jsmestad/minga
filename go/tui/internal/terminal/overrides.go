package terminal

import (
	"fmt"
	"strings"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// OverridesVariable is the environment variable that forces terminal features on or off, as a comma-separated list of
// `feature=on` and `feature=off`. The BEAM sets it from the `:terminal_features` option when it starts the frontend.
// A user can set it by hand where something else starts the frontend.
//
// It exists because detection can be wrong in ways the frontend cannot see: the table of known terminals goes stale,
// a terminal's refusal of a query never arrives, and a remote shell loses the variables that describe the terminal.
const OverridesVariable = "MINGA_TERMINAL_FEATURES"

// forceable names the features a user can force, by their schema names: the ones whose use the frontend decides
// through Capabilities.Supports, or sets up before the program starts (the colour profile). The Kitty keyboard
// protocol, synchronized output and focus reporting are asked of the terminal and answered reliably, and the input
// library turns them on by itself, so forcing them would only make the report disagree with what happens.
var forceable = map[string]Feature{
	"true_color":        generated.TerminalFeatureTrueColor,
	"styled_underlines": generated.TerminalFeatureStyledUnderlines,
	"underline_color":   generated.TerminalFeatureUnderlineColor,
}

// WithOverrides applies what the user forced and returns one message for every entry it could not use.
//
// An entry that is malformed, names a feature that cannot be forced, or gives a value other than on or off is left
// out and reported; the entries around it still apply. A forced feature keeps its status whatever the terminal
// answers later: forced on is detected, and forced off is the feature's fallback, or missing when nothing replaces it.
func (c Capabilities) WithOverrides(value string) (Capabilities, []string) {
	var problems []string
	for _, entry := range strings.Split(value, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		name, setting, ok := strings.Cut(entry, "=")
		feature, known := forceable[strings.TrimSpace(name)]
		setting = strings.TrimSpace(setting)
		switch {
		case !ok:
			problems = append(problems, fmt.Sprintf("%q is not feature=on or feature=off", entry))
		case !known:
			problems = append(problems, fmt.Sprintf("%q cannot be forced", strings.TrimSpace(name)))
		case setting == "on":
			c.settle(feature, generated.TerminalFeatureStatusDetected, SourceUser)
		case setting == "off":
			c.settle(feature, absent(feature), SourceUser)
		default:
			problems = append(problems, fmt.Sprintf("%q must be on or off, not %q", strings.TrimSpace(name), setting))
		}
	}
	return c, problems
}

// Forced reports whether the user forced a feature, and whether it was forced on.
func (c Capabilities) Forced(feature Feature) (forced bool, on bool) {
	if c.Source(feature) != SourceUser {
		return false, false
	}
	return true, c.Supports(feature)
}
