package protocol

import (
	"bytes"
	"testing"

	"github.com/jsmestad/minga/go/tui/internal/generated"
	"github.com/jsmestad/minga/go/tui/internal/terminal"
)

func TestEncodeFrontendForeground(t *testing.T) {
	if got := EncodeFrontendForeground(true); !bytes.Equal(got, []byte{0x13, 1}) {
		t.Fatalf("foreground = % x", got)
	}
	if got := EncodeFrontendForeground(false); !bytes.Equal(got, []byte{0x13, 0}) {
		t.Fatalf("background = % x", got)
	}
}

// decodeReport reads a terminal_report the way the BEAM does: opcode, body length, count, then feature and status pairs.
func decodeReport(t *testing.T, packet []byte) map[terminal.Feature]terminal.Status {
	t.Helper()
	if len(packet) < 4 || packet[0] != generated.OPTerminalReport {
		t.Fatalf("not a terminal_report: % x", packet)
	}
	bodyLen := int(packet[1])<<8 | int(packet[2])
	body := packet[3:]
	if len(body) != bodyLen || len(body) != 1+2*int(body[0]) {
		t.Fatalf("lengths disagree: body_len %d, body %d, count %d", bodyLen, len(body), body[0])
	}
	out := map[terminal.Feature]terminal.Status{}
	for i := 1; i < len(body); i += 2 {
		out[terminal.Feature(body[i])] = terminal.Status(body[i+1])
	}
	return out
}

func TestTheReportIsExactlyTheCapabilitiesValue(t *testing.T) {
	caps := terminal.NewCapabilities()
	steps := []func(*terminal.Capabilities){
		func(*terminal.Capabilities) {},
		func(c *terminal.Capabilities) { c.Resolve(generated.TerminalFeatureTrueColor, true) },
		func(c *terminal.Capabilities) { c.Resolve(generated.TerminalFeatureKittyKeyboard, false) },
		func(c *terminal.Capabilities) { c.Resolve(generated.TerminalFeatureFocusReporting, true) },
		func(c *terminal.Capabilities) { c.Expire() },
	}
	for step, change := range steps {
		change(&caps)
		report := decodeReport(t, EncodeTerminalReport(caps))

		// Every entry of the value is in the report with its status, and the report holds nothing else:
		// what the BEAM lists is what the frontend's own choices read.
		entries := caps.Entries()
		if len(report) != len(entries) {
			t.Fatalf("step %d: the report has %d entries, the capabilities %d", step, len(report), len(entries))
		}
		for _, entry := range entries {
			if got, ok := report[entry.Feature]; !ok || got != entry.Status || got != caps.Status(entry.Feature) {
				t.Fatalf("step %d: feature %d reported as %d, the frontend acts on %d", step, entry.Feature, got, caps.Status(entry.Feature))
			}
		}
	}
}

func TestEqualCapabilitiesEncodeToEqualReports(t *testing.T) {
	first, second := terminal.NewCapabilities(), terminal.NewCapabilities()
	first.Resolve(generated.TerminalFeatureTrueColor, true)
	second.Resolve(generated.TerminalFeatureTrueColor, true)
	if !bytes.Equal(EncodeTerminalReport(first), EncodeTerminalReport(second)) {
		t.Fatal("the report must depend on the capabilities value alone")
	}
	// true_color (1) detected (2), then styled_underlines (2), underline_color (3), kitty_keyboard (5),
	// synchronized_output (10) and focus_reporting (11), all pending (1).
	want := []byte{0x62, 0, 13, 6, 1, 2, 2, 1, 3, 1, 5, 1, 10, 1, 11, 1}
	if got := EncodeTerminalReport(first); !bytes.Equal(got, want) {
		t.Fatalf("report = % x, want % x", got, want)
	}
}
