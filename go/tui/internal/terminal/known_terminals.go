package terminal

import (
	"strconv"

	"github.com/jsmestad/minga/go/tui/internal/generated"
)

// KnownTerminal is a terminal that is taken to have features no query reports.
//
// Styled underlines (SGR 4:3 curly, 4:4 dotted) and the underline colour (SGR 58) have no query every terminal
// answers. iTerm and the VTE terminals, for example, draw them and answer no terminfo query. So the terminals that
// are known to draw them are named in this one table, which docs/design/tui.md mirrors. A table goes stale: the
// terminal's own answer always wins over it (Capabilities.ObserveTermcap), and it is never used inside a multiplexer.
type KnownTerminal struct {
	// Name is what the terminal is called in the documentation and in `:checkhealth terminal`.
	Name string
	// Since is the first version that has the features, where it is known and the environment lets it be checked.
	Since string
	// Basis says what the entry rests on.
	Basis string
	// Features are the features the terminal is taken to have.
	Features []Feature
	// matches recognises the terminal from the variables it sets.
	matches func(getenv func(string) string) bool
}

var styledUnderlineFeatures = []Feature{generated.TerminalFeatureStyledUnderlines, generated.TerminalFeatureUnderlineColor}

// KnownTerminals is the table, in the order it is matched.
var KnownTerminals = []KnownTerminal{
	{
		Name:     "Kitty",
		Basis:    "Kitty defined the styled and coloured underline sequences",
		Features: styledUnderlineFeatures,
		matches: func(getenv func(string) string) bool {
			return getenv("TERM") == "xterm-kitty" || getenv("KITTY_WINDOW_ID") != ""
		},
	},
	{
		Name:     "Ghostty",
		Basis:    "sets TERM_PROGRAM=ghostty or TERM=xterm-ghostty; implements Kitty's underline sequences",
		Features: styledUnderlineFeatures,
		matches: func(getenv func(string) string) bool {
			return getenv("TERM_PROGRAM") == "ghostty" || getenv("TERM") == "xterm-ghostty"
		},
	},
	{
		Name:     "WezTerm",
		Basis:    "sets TERM_PROGRAM=WezTerm or TERM=wezterm; implements Kitty's underline sequences",
		Features: styledUnderlineFeatures,
		matches: func(getenv func(string) string) bool {
			return getenv("TERM_PROGRAM") == "WezTerm" || getenv("TERM") == "wezterm"
		},
	},
	{
		Name:     "iTerm",
		Basis:    "sets TERM_PROGRAM=iTerm.app; draws the sequences and answers no terminfo query",
		Features: styledUnderlineFeatures,
		matches:  func(getenv func(string) string) bool { return getenv("TERM_PROGRAM") == "iTerm.app" },
	},
	{
		Name:     "foot",
		Basis:    "sets TERM=foot or foot-extra; implements Kitty's underline sequences",
		Features: styledUnderlineFeatures,
		matches: func(getenv func(string) string) bool {
			return getenv("TERM") == "foot" || getenv("TERM") == "foot-extra"
		},
	},
	{
		Name:     "Alacritty",
		Basis:    "sets TERM=alacritty; implements Kitty's underline sequences",
		Features: styledUnderlineFeatures,
		matches:  func(getenv func(string) string) bool { return getenv("TERM") == "alacritty" },
	},
	{
		Name:     "VTE terminals (GNOME Terminal and others)",
		Since:    "VTE 0.52",
		Basis:    "VTE_VERSION is major*10000 + minor*100 + micro; the sequences arrived in 0.52",
		Features: styledUnderlineFeatures,
		matches: func(getenv func(string) string) bool {
			version, err := strconv.Atoi(getenv("VTE_VERSION"))
			return err == nil && version >= 5200
		},
	},
}

// knownTerminal returns the table's entry for the terminal the environment describes.
//
// Inside a multiplexer (tmux, screen) the variables describe the outer terminal and the multiplexer decides what
// passes, so nothing is recognised there: the terminal's own answer, or the timeout, decides.
func knownTerminal(getenv func(string) string) (KnownTerminal, bool) {
	if getenv("TMUX") != "" || getenv("STY") != "" {
		return KnownTerminal{}, false
	}
	for _, terminal := range KnownTerminals {
		if terminal.matches(getenv) {
			return terminal, true
		}
	}
	return KnownTerminal{}, false
}
